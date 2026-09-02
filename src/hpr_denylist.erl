%% @doc Gateway denylist.
%%
%% Gateways (identified by their libp2p `pubkey_bin') on this list have their
%% uplinks dropped by hpr_routing during packet validation.
%%
%% The list survives a restart. `init/0' creates the table and hydrates it from
%% dets before any packet is served, which is the whole point: a denylist that
%% came back empty after a deploy would silently start accepting the traffic it
%% exists to drop, and nothing would say so.
%%
%% Changes are written through to dets immediately rather than checkpointed on a
%% timer like the config tables. Those checkpoint because they take millions of
%% stream updates; this list is small and only changes by operator action, and a
%% periodic checkpoint would leave open exactly the window this is meant to
%% close -- an entry added and then lost to a restart minutes later.
-module(hpr_denylist).

-export([
    init/0,

    is_denied/1,
    add/1,
    remove/1,
    reset/0,
    list/0,
    count/0
]).

-ifdef(TEST).
-export([test_delete_ets/0]).
-endif.

-define(DENYLIST, hpr_gateway_denylist_ets).
-define(DETS, hpr_gateway_denylist_dets).
-define(DETS_FILE, "hpr_denylist.dets").

-spec init() -> ok.
init() ->
    ?DENYLIST = ets:new(?DENYLIST, [
        public,
        named_table,
        set,
        {read_concurrency, true}
    ]),
    ok = with_open_dets(fun() ->
        [] = dets:traverse(?DETS, fun(Entry) ->
            true = ets:insert(?DENYLIST, Entry),
            continue
        end)
    end),
    lager:info("denylist hydrated with ~w gateways", [?MODULE:count()]),
    ok.

%% @doc Whether this gateway's uplinks should be dropped.
%%
%% Called for every uplink, and deliberately tolerant of a missing table so the
%% packet path cannot be taken down by a denylist that was never initialised.
-spec is_denied(Gateway :: binary()) -> boolean().
is_denied(Gateway) ->
    case ets:whereis(?DENYLIST) of
        undefined -> false;
        _ -> ets:member(?DENYLIST, Gateway)
    end.

-spec add(Gateway :: binary()) -> ok.
add(Gateway) ->
    true = ets:insert(?DENYLIST, {Gateway}),
    ok = with_open_dets(fun() -> ok = dets:insert(?DETS, {Gateway}) end),
    ok.

-spec remove(Gateway :: binary()) -> ok.
remove(Gateway) ->
    true = ets:delete(?DENYLIST, Gateway),
    ok = with_open_dets(fun() -> ok = dets:delete(?DETS, Gateway) end),
    ok.

%% @doc Empty the denylist, on disk as well as in memory.
%%
%% Empties the table rather than deleting it: the table is created once by
%% `init/0' at startup, so dropping it here would leave every later add/remove
%% raising until the next restart.
-spec reset() -> ok.
reset() ->
    true = ets:delete_all_objects(?DENYLIST),
    ok = with_open_dets(fun() -> ok = dets:delete_all_objects(?DETS) end),
    ok.

-spec list() -> [binary()].
list() ->
    case ets:whereis(?DENYLIST) of
        undefined -> [];
        _ -> [Gateway || {Gateway} <- ets:tab2list(?DENYLIST)]
    end.

-spec count() -> non_neg_integer().
count() ->
    case ets:info(?DENYLIST, size) of
        undefined -> 0;
        Size -> Size
    end.

%% ------------------------------------------------------------------
%% Internal Functions
%% ------------------------------------------------------------------

-spec with_open_dets(FN :: fun()) -> ok.
with_open_dets(FN) ->
    DataDir = hpr_utils:base_data_dir(),
    DETSFile = filename:join([DataDir, ?DETS_FILE]),
    ok = filelib:ensure_dir(DETSFile),

    case dets:open_file(?DETS, [{file, DETSFile}, {type, set}, {keypos, 1}]) of
        {ok, _Dets} ->
            FN(),
            dets:close(?DETS);
        {error, Reason} ->
            Deleted = file:delete(DETSFile),
            lager:warning("failed to open dets file ~p: ~p, deleted: ~p", [?MODULE, Reason, Deleted]),
            with_open_dets(FN)
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-spec test_delete_ets() -> ok.
test_delete_ets() ->
    _ = catch ets:delete(?DENYLIST),
    ok.

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        ?_test(test_empty_after_init()),
        ?_test(test_add_remove()),
        ?_test(test_reset()),
        ?_test(test_survives_restart()),
        ?_test(test_reset_survives_restart())
    ]}.

foreach_setup() ->
    %% Unique per test AND per run: unique_integer/1 restarts with the VM, so a
    %% timestamp is needed too or a later run hydrates an earlier run's dets file.
    RunDir = filename:join([
        ?MODULE,
        erlang:integer_to_list(erlang:system_time(nanosecond)) ++
            "-" ++ erlang:integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = application:set_env(hpr, data_dir, filename:join([RunDir, "data"])),
    ok = ?MODULE:init(),
    RunDir.

foreach_cleanup(RunDir) ->
    ok = ?MODULE:test_delete_ets(),
    _ = file:del_dir_r(RunDir),
    ok.

%% Standing in for a boot with no dets file: the table exists and reads are safe.
test_empty_after_init() ->
    ?assertNotEqual(undefined, ets:whereis(?DENYLIST)),
    ?assertEqual(false, ?MODULE:is_denied(<<"gw1">>)),
    ?assertEqual([], ?MODULE:list()),
    ?assertEqual(0, ?MODULE:count()),
    ok.

test_add_remove() ->
    Gateway1 = <<"gw1">>,
    Gateway2 = <<"gw2">>,

    ?assertEqual(ok, ?MODULE:add(Gateway1)),
    ?assert(?MODULE:is_denied(Gateway1)),
    ?assertEqual(false, ?MODULE:is_denied(Gateway2)),
    ?assertEqual(1, ?MODULE:count()),

    ?assertEqual(ok, ?MODULE:add(Gateway2)),
    ?assertEqual(2, ?MODULE:count()),
    ?assertEqual(lists:sort([Gateway1, Gateway2]), lists:sort(?MODULE:list())),

    %% adding the same gateway again is idempotent
    ?assertEqual(ok, ?MODULE:add(Gateway1)),
    ?assertEqual(2, ?MODULE:count()),

    ?assertEqual(ok, ?MODULE:remove(Gateway1)),
    ?assertEqual(false, ?MODULE:is_denied(Gateway1)),
    ?assert(?MODULE:is_denied(Gateway2)),
    ?assertEqual(1, ?MODULE:count()),
    ok.

test_reset() ->
    Gateway = <<"gw1">>,
    ?assertEqual(ok, ?MODULE:add(Gateway)),
    ?assert(?MODULE:is_denied(Gateway)),

    ?assertEqual(ok, ?MODULE:reset()),
    ?assertEqual(0, ?MODULE:count()),
    ?assertEqual(false, ?MODULE:is_denied(Gateway)),

    %% the table is emptied, not dropped, so it stays usable
    ?assertNotEqual(undefined, ets:whereis(?DENYLIST)),
    ?assertEqual(ok, ?MODULE:add(Gateway)),
    ?assert(?MODULE:is_denied(Gateway)),
    ok.

%% The point of the whole module: entries come back after a restart.
test_survives_restart() ->
    Gateway1 = <<"gw1">>,
    Gateway2 = <<"gw2">>,
    ok = ?MODULE:add(Gateway1),
    ok = ?MODULE:add(Gateway2),
    ok = ?MODULE:remove(Gateway2),

    ok = restart(),

    ?assert(?MODULE:is_denied(Gateway1)),
    ?assertEqual(false, ?MODULE:is_denied(Gateway2), "a removed gateway stays removed"),
    ?assertEqual(1, ?MODULE:count()),
    ok.

test_reset_survives_restart() ->
    ok = ?MODULE:add(<<"gw1">>),
    ok = ?MODULE:reset(),

    ok = restart(),

    ?assertEqual(0, ?MODULE:count()),
    ok.

%% Drops the table and re-inits against the same data_dir, as a node restart does.
restart() ->
    ok = ?MODULE:test_delete_ets(),
    ok = ?MODULE:init().

-endif.
