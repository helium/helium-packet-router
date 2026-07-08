%%%-------------------------------------------------------------------
%% @doc
%% == HPR Gateway Liveness Storage ==
%% @end
%%%-------------------------------------------------------------------
-module(hpr_gateway_liveness_storage).

-export([
    init_ets/0,
    checkpoint/0,

    record_connect/1,
    lookup/1,
    foldl/2,
    all/0,
    expire/1,

    delete_all/0
]).

-ifdef(TEST).
-export([test_delete_ets/0, test_size/0]).
-endif.

-define(ETS, hpr_gateway_liveness_ets).
-define(DETS, hpr_gateway_liveness_dets).
-define(DETS_FILE, "hpr_gateway_liveness.dets").

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [
        public,
        named_table,
        set,
        {keypos, 1},
        {write_concurrency, true}
    ]),
    with_open_dets(fun() ->
        [] = dets:traverse(
            ?DETS,
            fun(Entry) ->
                true = ets:insert(?ETS, Entry),
                continue
            end
        )
    end),
    ok.

-spec checkpoint() -> ok.
checkpoint() ->
    with_open_dets(fun() ->
        ok = dets:from_ets(?DETS, ?ETS)
    end).

-spec record_connect(PubKeyBin :: libp2p_crypto:pubkey_bin()) -> ok.
record_connect(PubKeyBin) ->
    true = ets:insert(?ETS, {PubKeyBin, erlang:system_time(millisecond)}),
    ok.

-spec lookup(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    {ok, non_neg_integer()} | {error, not_found}.
lookup(PubKeyBin) ->
    case ets:lookup(?ETS, PubKeyBin) of
        [{PubKeyBin, LastSeen}] -> {ok, LastSeen};
        [] -> {error, not_found}
    end.

-spec foldl(Fun :: function(), Acc :: any()) -> any().
foldl(Fun, Acc) ->
    ets:foldl(Fun, Acc, ?ETS).

-spec all() -> list({libp2p_crypto:pubkey_bin(), non_neg_integer()}).
all() ->
    ets:tab2list(?ETS).

%% @doc Deletes entries whose last-seen timestamp is older than `Now - ThresholdMillis'.
-spec expire(ThresholdMillis :: non_neg_integer()) -> non_neg_integer().
expire(ThresholdMillis) ->
    CutOff = erlang:system_time(millisecond) - ThresholdMillis,
    Deleted = ets:select_delete(?ETS, [{{'_', '$1'}, [{'<', '$1', CutOff}], [true]}]),
    lager:info("expired ~w stale gateway liveness entries", [Deleted]),
    Deleted.

-spec delete_all() -> ok.
delete_all() ->
    ets:delete_all_objects(?ETS),
    ok.

-ifdef(TEST).

-spec test_delete_ets() -> ok.
test_delete_ets() ->
    ets:delete(?ETS),
    ok.

-spec test_size() -> non_neg_integer().
test_size() ->
    ets:info(?ETS, size).

-endif.

%% ------------------------------------------------------------------
%% Internal Functions
%% ------------------------------------------------------------------

with_open_dets(FN) ->
    DataDir = hpr_utils:base_data_dir(),
    DETSFile = filename:join([DataDir, ?DETS_FILE]),
    ok = filelib:ensure_dir(DETSFile),

    case dets:open_file(?DETS, [{file, DETSFile}, {type, set}, {keypos, 1}]) of
        {ok, _Dets} ->
            lager:info("~s opened by ~p", [DETSFile, self()]),
            FN(),
            dets:close(?DETS);
        {error, Reason} ->
            Deleted = file:delete(DETSFile),
            lager:warning("failed to open dets file ~p: ~p, deleted: ~p", [?MODULE, Reason, Deleted]),
            with_open_dets(FN)
    end.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_DIR, "test_data").

setup() ->
    application:set_env(hpr, data_dir, ?TEST_DIR),
    ok = init_ets().

teardown(_) ->
    ok = test_delete_ets(),
    dets:close(?DETS),
    os:cmd("rm -rf " ++ ?TEST_DIR).

hpr_gateway_liveness_storage_test_() ->
    {setup, fun setup/0, fun teardown/1, [
        {inorder, [
            fun test_record_and_lookup/0,
            fun test_checkpoint_writes_dets_file/0,
            fun test_expire/0
        ]}
    ]}.

test_record_and_lookup() ->
    ?assertEqual({error, not_found}, lookup(<<"gw1">>)),
    ok = record_connect(<<"gw1">>),
    {ok, LastSeen} = lookup(<<"gw1">>),
    ?assert(is_integer(LastSeen)),
    ?assertEqual(1, test_size()).

test_checkpoint_writes_dets_file() ->
    ok = delete_all(),
    ok = record_connect(<<"gw2">>),
    ok = record_connect(<<"gw3">>),
    ok = checkpoint(),

    DETSFile = filename:join([hpr_utils:base_data_dir(), ?DETS_FILE]),
    ?assert(filelib:is_file(DETSFile)).

test_expire() ->
    ok = delete_all(),
    true = ets:insert(?ETS, {<<"stale">>, erlang:system_time(millisecond) - 10_000}),
    true = ets:insert(?ETS, {<<"fresh">>, erlang:system_time(millisecond)}),

    Deleted = expire(5_000),

    ?assertEqual(1, Deleted),
    ?assertEqual({error, not_found}, lookup(<<"stale">>)),
    ?assertMatch({ok, _}, lookup(<<"fresh">>)).

-endif.
