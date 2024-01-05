%%--------------------------------------------------------------------
%% Copyright (c) 2023-2024 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% @doc CRUD interface for the persistent session
%%
%% This module encapsulates the data related to the state of the
%% inflight messages for the persistent session based on DS.
%%
%% It is responsible for saving, caching, and restoring session state.
%% It is completely devoid of business logic. Not even the default
%% values should be set in this module.
-module(emqx_persistent_session_ds_state).

-export([create_tables/0]).

-export([open/1, create_new/1, delete/1, commit/1, format/1, print_session/1, list_sessions/0]).
-export([get_created_at/1, set_created_at/2]).
-export([get_last_alive_at/1, set_last_alive_at/2]).
-export([get_conninfo/1, set_conninfo/2]).
-export([new_subid/1]).
-export([get_stream/2, put_stream/3, del_stream/2, fold_streams/3]).
-export([get_seqno/2, put_seqno/3]).
-export([get_rank/2, put_rank/3, del_rank/2, fold_ranks/3]).
-export([get_subscriptions/1, put_subscription/4, del_subscription/3]).

%% internal exports:
-export([]).

-export_type([t/0, subscriptions/0, seqno_type/0, stream_key/0, rank_key/0]).

-include("emqx_mqtt.hrl").
-include("emqx_persistent_session_ds.hrl").

%%================================================================================
%% Type declarations
%%================================================================================

-type subscriptions() :: emqx_topic_gbt:t(_SubId, emqx_persistent_session_ds:subscription()).

%% Generic key-value wrapper that is used for exporting arbitrary
%% terms to mnesia:
-record(kv, {k, v}).

%% Persistent map.
%%
%% Pmap accumulates the updates in a term stored in the heap of a
%% process, so they can be committed all at once in a single
%% transaction.
%%
%% It should be possible to make frequent changes to the pmap without
%% stressing Mria.
%%
%% It's implemented as three maps: `clean', `dirty' and `tombstones'.
%% Updates are made to the `dirty' area. `pmap_commit' function saves
%% the updated entries to Mnesia and moves them to the `clean' area.
-record(pmap, {table, clean, dirty, tombstones}).

-type pmap(K, V) ::
    #pmap{
        table :: atom(),
        clean :: #{K => V},
        dirty :: #{K => V},
        tombstones :: #{K => _}
    }.

%% Session metadata:
-define(created_at, created_at).
-define(last_alive_at, last_alive_at).
-define(conninfo, conninfo).
-define(last_subid, last_subid).

-type metadata() ::
    #{
        ?created_at => emqx_persistent_session_ds:timestamp(),
        ?last_alive_at => emqx_persistent_session_ds:timestamp(),
        ?conninfo => emqx_types:conninfo(),
        ?last_subid => integer()
    }.

-type seqno_type() ::
    ?next(?QOS_1)
    | ?dup(?QOS_1)
    | ?committed(?QOS_1)
    | ?next(?QOS_2)
    | ?dup(?QOS_2)
    | ?committed(?QOS_2).

-opaque t() :: #{
    id := emqx_persistent_session_ds:id(),
    dirty := boolean(),
    metadata := metadata(),
    subscriptions := subscriptions(),
    seqnos := pmap(seqno_type(), emqx_persistent_session_ds:seqno()),
    streams := pmap(emqx_ds:stream(), emqx_persistent_session_ds:stream_state()),
    ranks := pmap(term(), integer())
}.

-define(session_tab, emqx_ds_session_tab).
-define(subscription_tab, emqx_ds_session_subscriptions).
-define(stream_tab, emqx_ds_session_streams).
-define(seqno_tab, emqx_ds_session_seqnos).
-define(rank_tab, emqx_ds_session_ranks).
-define(bag_tables, [?stream_tab, ?seqno_tab, ?rank_tab, ?subscription_tab]).

%%================================================================================
%% API funcions
%%================================================================================

-spec create_tables() -> ok.
create_tables() ->
    ok = mria:create_table(
        ?session_tab,
        [
            {rlog_shard, ?DS_MRIA_SHARD},
            {type, set},
            {storage, rocksdb_copies},
            {record_name, kv},
            {attributes, record_info(fields, kv)}
        ]
    ),
    [create_kv_bag_table(Table) || Table <- ?bag_tables],
    mria:wait_for_tables([?session_tab | ?bag_tables]).

-spec open(emqx_persistent_session_ds:id()) -> {ok, t()} | undefined.
open(SessionId) ->
    ro_transaction(fun() ->
        case kv_restore(?session_tab, SessionId) of
            [Metadata] ->
                Rec = #{
                    id => SessionId,
                    metadata => Metadata,
                    subscriptions => read_subscriptions(SessionId),
                    streams => pmap_open(?stream_tab, SessionId),
                    seqnos => pmap_open(?seqno_tab, SessionId),
                    ranks => pmap_open(?rank_tab, SessionId),
                    dirty => false
                },
                {ok, Rec};
            [] ->
                undefined
        end
    end).

-spec print_session(emqx_persistent_session_ds:id()) -> map() | undefined.
print_session(SessionId) ->
    case open(SessionId) of
        undefined ->
            undefined;
        {ok, Session} ->
            format(Session)
    end.

-spec format(t()) -> map().
format(#{
    metadata := Metadata,
    subscriptions := SubsGBT,
    streams := Streams,
    seqnos := Seqnos,
    ranks := Ranks
}) ->
    Subs = emqx_topic_gbt:fold(
        fun(Key, Sub, Acc) -> maps:put(Key, Sub, Acc) end,
        #{},
        SubsGBT
    ),
    #{
        metadata => Metadata,
        subscriptions => Subs,
        streams => pmap_format(Streams),
        seqnos => pmap_format(Seqnos),
        ranks => pmap_format(Ranks)
    }.

-spec list_sessions() -> [emqx_persistent_session_ds:id()].
list_sessions() ->
    mnesia:dirty_all_keys(?session_tab).

-spec delete(emqx_persistent_session_ds:id()) -> ok.
delete(Id) ->
    transaction(
        fun() ->
            [kv_delete(Table, Id) || Table <- ?bag_tables],
            mnesia:delete(?session_tab, Id, write)
        end
    ).

-spec commit(t()) -> t().
commit(Rec = #{dirty := false}) ->
    Rec;
commit(
    Rec = #{
        id := SessionId,
        metadata := Metadata,
        streams := Streams,
        seqnos := SeqNos,
        ranks := Ranks
    }
) ->
    transaction(fun() ->
        kv_persist(?session_tab, SessionId, Metadata),
        Rec#{
            streams => pmap_commit(SessionId, Streams),
            seqnos => pmap_commit(SessionId, SeqNos),
            ranks => pmap_commit(SessionId, Ranks),
            dirty => false
        }
    end).

-spec create_new(emqx_persistent_session_ds:id()) -> t().
create_new(SessionId) ->
    transaction(fun() ->
        delete(SessionId),
        #{
            id => SessionId,
            metadata => #{},
            subscriptions => emqx_topic_gbt:new(),
            streams => pmap_open(?stream_tab, SessionId),
            seqnos => pmap_open(?seqno_tab, SessionId),
            ranks => pmap_open(?rank_tab, SessionId),
            dirty => true
        }
    end).

%%

-spec get_created_at(t()) -> emqx_persistent_session_ds:timestamp() | undefined.
get_created_at(Rec) ->
    get_meta(?created_at, Rec).

-spec set_created_at(emqx_persistent_session_ds:timestamp(), t()) -> t().
set_created_at(Val, Rec) ->
    set_meta(?created_at, Val, Rec).

-spec get_last_alive_at(t()) -> emqx_persistent_session_ds:timestamp() | undefined.
get_last_alive_at(Rec) ->
    get_meta(?last_alive_at, Rec).

-spec set_last_alive_at(emqx_persistent_session_ds:timestamp(), t()) -> t().
set_last_alive_at(Val, Rec) ->
    set_meta(?last_alive_at, Val, Rec).

-spec get_conninfo(t()) -> emqx_types:conninfo() | undefined.
get_conninfo(Rec) ->
    get_meta(?conninfo, Rec).

-spec set_conninfo(emqx_types:conninfo(), t()) -> t().
set_conninfo(Val, Rec) ->
    set_meta(?conninfo, Val, Rec).

-spec new_subid(t()) -> {emqx_persistent_session_ds:subscription_id(), t()}.
new_subid(Rec) ->
    LastSubId =
        case get_meta(?last_subid, Rec) of
            undefined -> 0;
            N when is_integer(N) -> N
        end,
    {LastSubId, set_meta(?last_subid, LastSubId + 1, Rec)}.

%%

-spec get_subscriptions(t()) -> subscriptions().
get_subscriptions(#{subscriptions := Subs}) ->
    Subs.

-spec put_subscription(
    emqx_persistent_session_ds:topic_filter(),
    _SubId,
    emqx_persistent_session_ds:subscription(),
    t()
) -> t().
put_subscription(TopicFilter, SubId, Subscription, Rec = #{id := Id, subscriptions := Subs0}) ->
    %% Note: currently changes to the subscriptions are persisted immediately.
    Key = {TopicFilter, SubId},
    transaction(fun() -> kv_bag_persist(?subscription_tab, Id, Key, Subscription) end),
    Subs = emqx_topic_gbt:insert(TopicFilter, SubId, Subscription, Subs0),
    Rec#{subscriptions => Subs}.

-spec del_subscription(emqx_persistent_session_ds:topic_filter(), _SubId, t()) -> t().
del_subscription(TopicFilter, SubId, Rec = #{id := Id, subscriptions := Subs0}) ->
    %% Note: currently the subscriptions are persisted immediately.
    Key = {TopicFilter, SubId},
    transaction(fun() -> kv_bag_delete(?subscription_tab, Id, Key) end),
    Subs = emqx_topic_gbt:delete(TopicFilter, SubId, Subs0),
    Rec#{subscriptions => Subs}.

%%

-type stream_key() :: {emqx_persistent_session_ds:subscription_id(), emqx_ds:stream()}.

-spec get_stream(stream_key(), t()) ->
    emqx_persistent_session_ds:stream_state() | undefined.
get_stream(Key, Rec) ->
    gen_get(streams, Key, Rec).

-spec put_stream(stream_key(), emqx_persistent_session_ds:stream_state(), t()) -> t().
put_stream(Key, Val, Rec) ->
    gen_put(streams, Key, Val, Rec).

-spec del_stream(stream_key(), t()) -> t().
del_stream(Key, Rec) ->
    gen_del(streams, Key, Rec).

-spec fold_streams(fun(), Acc, t()) -> Acc.
fold_streams(Fun, Acc, Rec) ->
    gen_fold(streams, Fun, Acc, Rec).

%%

-spec get_seqno(seqno_type(), t()) -> emqx_persistent_session_ds:seqno() | undefined.
get_seqno(Key, Rec) ->
    gen_get(seqnos, Key, Rec).

-spec put_seqno(seqno_type(), emqx_persistent_session_ds:seqno(), t()) -> t().
put_seqno(Key, Val, Rec) ->
    gen_put(seqnos, Key, Val, Rec).

%%

-type rank_key() :: {emqx_persistent_session_ds:subscription_id(), emqx_ds:rank_x()}.

-spec get_rank(rank_key(), t()) -> integer() | undefined.
get_rank(Key, Rec) ->
    gen_get(ranks, Key, Rec).

-spec put_rank(rank_key(), integer(), t()) -> t().
put_rank(Key, Val, Rec) ->
    gen_put(ranks, Key, Val, Rec).

-spec del_rank(rank_key(), t()) -> t().
del_rank(Key, Rec) ->
    gen_del(ranks, Key, Rec).

-spec fold_ranks(fun(), Acc, t()) -> Acc.
fold_ranks(Fun, Acc, Rec) ->
    gen_fold(ranks, Fun, Acc, Rec).

%%================================================================================
%% Internal functions
%%================================================================================

%% All mnesia reads and writes are passed through this function.
%% Backward compatiblity issues can be handled here.
encoder(encode, _Table, Term) ->
    Term;
encoder(decode, _Table, Term) ->
    Term.

%%

get_meta(K, #{metadata := Meta}) ->
    maps:get(K, Meta, undefined).

set_meta(K, V, Rec = #{metadata := Meta}) ->
    Rec#{metadata => maps:put(K, V, Meta), dirty => true}.

%%

gen_get(Field, Key, Rec) ->
    pmap_get(Key, maps:get(Field, Rec)).

gen_fold(Field, Fun, Acc, Rec) ->
    pmap_fold(Fun, Acc, maps:get(Field, Rec)).

gen_put(Field, Key, Val, Rec) ->
    maps:update_with(
        Field,
        fun(PMap) -> pmap_put(Key, Val, PMap) end,
        Rec#{dirty => true}
    ).

gen_del(Field, Key, Rec) ->
    maps:update_with(
        Field,
        fun(PMap) -> pmap_del(Key, PMap) end,
        Rec#{dirty => true}
    ).

%%

read_subscriptions(SessionId) ->
    Records = kv_bag_restore(?subscription_tab, SessionId),
    lists:foldl(
        fun({{TopicFilter, SubId}, Subscription}, Acc) ->
            emqx_topic_gbt:insert(TopicFilter, SubId, Subscription, Acc)
        end,
        emqx_topic_gbt:new(),
        Records
    ).

%%

%% @doc Open a PMAP and fill the clean area with the data from DB.
%% This functtion should be ran in a transaction.
-spec pmap_open(atom(), emqx_persistent_session_ds:id()) -> pmap(_K, _V).
pmap_open(Table, SessionId) ->
    Clean = maps:from_list(kv_bag_restore(Table, SessionId)),
    #pmap{
        table = Table,
        clean = Clean,
        dirty = #{},
        tombstones = #{}
    }.

-spec pmap_get(K, pmap(K, V)) -> V | undefined.
pmap_get(K, #pmap{dirty = Dirty, clean = Clean}) ->
    case Dirty of
        #{K := V} ->
            V;
        _ ->
            case Clean of
                #{K := V} -> V;
                _ -> undefined
            end
    end.

-spec pmap_put(K, V, pmap(K, V)) -> pmap(K, V).
pmap_put(K, V, Pmap = #pmap{dirty = Dirty, clean = Clean, tombstones = Tombstones}) ->
    Pmap#pmap{
        dirty = maps:put(K, V, Dirty),
        clean = maps:remove(K, Clean),
        tombstones = maps:remove(K, Tombstones)
    }.

-spec pmap_del(K, pmap(K, V)) -> pmap(K, V).
pmap_del(
    Key,
    Pmap = #pmap{dirty = Dirty, clean = Clean, tombstones = Tombstones}
) ->
    %% Update the caches:
    Pmap#pmap{
        dirty = maps:remove(Key, Dirty),
        clean = maps:remove(Key, Clean),
        tombstones = Tombstones#{Key => del}
    }.

-spec pmap_fold(fun((K, V, A) -> A), A, pmap(K, V)) -> A.
pmap_fold(Fun, Acc0, #pmap{clean = Clean, dirty = Dirty}) ->
    Acc1 = maps:fold(Fun, Acc0, Dirty),
    maps:fold(Fun, Acc1, Clean).

-spec pmap_commit(emqx_persistent_session_ds:id(), pmap(K, V)) -> pmap(K, V).
pmap_commit(
    SessionId, Pmap = #pmap{table = Tab, dirty = Dirty, clean = Clean, tombstones = Tombstones}
) ->
    %% Commit deletions:
    maps:foreach(fun(K, _) -> kv_bag_delete(Tab, SessionId, K) end, Tombstones),
    %% Replace all records in the bag with the entries from the dirty area:
    maps:foreach(
        fun(K, V) ->
            kv_bag_persist(Tab, SessionId, K, V)
        end,
        Dirty
    ),
    Pmap#pmap{
        dirty = #{},
        tombstones = #{},
        clean = maps:merge(Clean, Dirty)
    }.

-spec pmap_format(pmap(_K, _V)) -> map().
pmap_format(#pmap{clean = Clean, dirty = Dirty}) ->
    maps:merge(Clean, Dirty).

%% Functions dealing with set tables:

kv_persist(Tab, SessionId, Val0) ->
    Val = encoder(encode, Tab, Val0),
    mnesia:write(Tab, #kv{k = SessionId, v = Val}, write).

kv_delete(Table, Namespace) ->
    mnesia:delete({Table, Namespace}).

kv_restore(Tab, SessionId) ->
    [encoder(decode, Tab, V) || #kv{v = V} <- mnesia:read(Tab, SessionId)].

%% Functions dealing with bags:

%% @doc Create a mnesia table for the PMAP:
-spec create_kv_bag_table(atom()) -> ok.
create_kv_bag_table(Table) ->
    mria:create_table(Table, [
        {type, bag},
        {rlog_shard, ?DS_MRIA_SHARD},
        {storage, rocksdb_copies},
        {record_name, kv},
        {attributes, record_info(fields, kv)}
    ]).

kv_bag_persist(Tab, SessionId, Key, Val0) ->
    %% Remove the previous entry corresponding to the key:
    kv_bag_delete(Tab, SessionId, Key),
    %% Write data to mnesia:
    Val = encoder(encode, Tab, Val0),
    mnesia:write(Tab, #kv{k = SessionId, v = {Key, Val}}, write).

kv_bag_restore(Tab, SessionId) ->
    [{K, encoder(decode, Tab, V)} || #kv{v = {K, V}} <- mnesia:read(Tab, SessionId)].

kv_bag_delete(Table, SessionId, Key) ->
    %% Note: this match spec uses a fixed primary key, so it doesn't
    %% require a table scan, and the transaction doesn't grab the
    %% whole table lock:
    MS = [{#kv{k = SessionId, v = {Key, '_'}}, [], ['$_']}],
    Objs = mnesia:select(Table, MS, write),
    lists:foreach(
        fun(Obj) ->
            mnesia:delete_object(Table, Obj, write)
        end,
        Objs
    ).

%%

transaction(Fun) ->
    case mnesia:is_transaction() of
        true ->
            Fun();
        false ->
            {atomic, Res} = mria:transaction(?DS_MRIA_SHARD, Fun),
            Res
    end.

ro_transaction(Fun) ->
    {atomic, Res} = mria:ro_transaction(?DS_MRIA_SHARD, Fun),
    Res.
