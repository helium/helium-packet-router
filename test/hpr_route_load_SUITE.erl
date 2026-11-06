%%%-------------------------------------------------------------------
%% @doc
%% Route storage and per-packet route lookup at production scale, with
%% hpr_test_dataset's route shapes loaded straight into storage (no stream).
%%
%% Correctness is always asserted: the right routes, the right max copies,
%% nothing leaking between DevAddrs. Timings are logged as percentiles and
%% asserted only against a generous ceiling, which a regression to scanning a
%% route's whole SKF table per packet would blow through and ordinary CI noise
%% will not.
%% @end
%%%-------------------------------------------------------------------
-module(hpr_route_load_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    huge_route_match_test/1,
    devaddr_isolation_test/1,
    high_devaddr_test/1,
    shared_range_test/1,
    full_dataset_test/1,
    concurrent_lookup_test/1,
    checkpoint_rehydrate_test/1,
    v2_migration_test/1,
    route_remove_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("hpr_metrics.hrl").

%% Ceilings are about ten times what an idle container measures, so they fail
%% on a regression rather than on a busy CI runner.
%%
%% A match on route-huge (1,072 keys on the DevAddr) measured p50 2.7ms: about
%% half the keys tried against the first frame-counter candidate. Scanning the
%% whole SKF table per packet, as the v2 layout did, cost 23ms on its own, so
%% the p50 ceiling sits below that.
-define(MATCH_P50_CEILING_US, 15000).
%% A miss tries all eight frame-counter candidates against every key: p99
%% measured 50ms on route-huge, and about the same over the full dataset.
-define(P99_CEILING_US, 500000).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

all() ->
    [
        huge_route_match_test,
        devaddr_isolation_test,
        high_devaddr_test,
        shared_range_test,
        full_dataset_test,
        concurrent_lookup_test,
        checkpoint_rehydrate_test,
        v2_migration_test,
        route_remove_test
    ].

init_per_testcase(TestCase, Config) ->
    %% The periodic checkpoint would write thousands of routes in the middle of
    %% a timing, and clear dirty flags a test is counting. Tests checkpoint
    %% when they mean to.
    ok = application:set_env(hpr, ics_stream_worker_checkpoint_secs, 3600, [{persistent, true}]),
    Config1 = test_utils:init_per_testcase(TestCase, Config),
    ok = hpr_test_dataset:quiet_logs(),
    Config1.

end_per_testcase(TestCase, Config) ->
    catch meck:unload(),
    Config1 = test_utils:end_per_testcase(TestCase, Config),
    ok = application:unset_env(hpr, ics_stream_worker_checkpoint_secs, [{persistent, true}]),
    Config1.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%% Every DevAddr of the largest route finds its first, middle and last key,
%% misses a random one, and finds a key whose frame counter has rolled past
%% 16 bits.
huge_route_match_test(_Config) ->
    Dataset = load(only(["route-huge"])),
    #{keys := [Keys | _] = PerDevAddr} = hpr_test_dataset:route(Dataset, "route-huge"),
    Last = Keys - 1,
    DevAddrs = lists:seq(0, length(PerDevAddr) - 1),
    Match = [
        timed_check(Dataset, "route-huge", D, K, #{})
     || D <- DevAddrs, K <- [0, Last div 2, Last]
    ],
    Miss = [timed_check(Dataset, "route-huge", D, random, #{}) || D <- DevAddrs],
    Rolled = [
        timed_check(Dataset, "route-huge", D, Last, #{fcnt => (3 bsl 16) + 5})
     || D <- lists:sublist(DevAddrs, 16)
    ],
    ok = within("route-huge match", Match, p50, ?MATCH_P50_CEILING_US),
    ok = within("route-huge match", Match, p99, ?P99_CEILING_US),
    ok = within("route-huge rolled fcnt", Rolled, p99, ?P99_CEILING_US),
    ok = within("route-huge miss", Miss, p99, ?P99_CEILING_US),
    ok.

%% A DevAddr's lookup returns exactly its own keys: none from the DevAddr next
%% to it, and nothing at all just outside a route's block.
devaddr_isolation_test(_Config) ->
    Dataset = load(named),
    lists:foreach(
        fun(Name) ->
            #{id := ID, range := {Start, End}, keys := Keys} =
                hpr_test_dataset:route(Dataset, Name),
            {ok, RouteETS} = hpr_route_storage:lookup(ID),
            SKFETS = hpr_route_ets:skf_ets(RouteETS),
            lists:foreach(
                fun({Offset, N}) ->
                    ?assertEqual(
                        N, length(hpr_skf_storage:lookup(SKFETS, Start + Offset)), {Name, Offset}
                    )
                end,
                lists:zip(lists:seq(0, length(Keys) - 1), Keys)
            ),
            lists:foreach(
                fun(Outside) ->
                    ?assertEqual([], hpr_skf_storage:lookup(SKFETS, Outside)),
                    ?assertEqual([], hpr_devaddr_range_storage:lookup(Outside)),
                    ?assertEqual(
                        {ok, []},
                        hpr_test_dataset:find_routes(
                            test_utils:uplink_packet_up(#{devaddr => Outside})
                        )
                    )
                end,
                [Start - 1, End + 1]
            )
        end,
        ["route-huge", "route-big", "route-mid"]
    ),
    ok.

%% DevAddrs above 2^31 route, and survive a checkpoint and restart.
high_devaddr_test(_Config) ->
    Dataset = load(only(["route-high-devaddr"])),
    #{range := {Start, _}, keys := Keys} = hpr_test_dataset:route(Dataset, "route-high-devaddr"),
    ?assert(Start >= 1 bsl 31),
    Check = fun() ->
        [
            check(Dataset, "route-high-devaddr", D, K)
         || D <- lists:seq(0, length(Keys) - 1), K <- [0, 59, random]
        ]
    end,
    _ = Check(),
    ok = hpr_route_stream_worker:checkpoint(),
    ok = test_utils:restart_hpr(),
    ok = hpr_test_dataset:wait_counts(Dataset, 20, 100),
    _ = Check(),
    ok.

%% route-gwmp and route-gwmp-inactive share a block. A packet signed with a
%% route-gwmp key finds both (the inactive one as an empty route) but is only
%% delivered to route-gwmp; a packet with an unknown key is delivered nowhere.
shared_range_test(_Config) ->
    Dataset = load(only(["route-gwmp", "route-gwmp-inactive"])),
    #{id := GwmpID} = hpr_test_dataset:route(Dataset, "route-gwmp"),
    #{id := InactiveID} = hpr_test_dataset:route(Dataset, "route-gwmp-inactive"),

    ?assertMatch(
        {ok, [_, _]}, check(Dataset, "route-gwmp", 0, 7)
    ),
    ?assertEqual({ok, [{InactiveID, 0}]}, check(Dataset, "route-gwmp", 0, random)),

    meck:new(hpr_protocol_gwmp, [passthrough]),
    meck:expect(hpr_protocol_gwmp, send, fun(_, _, _, _) -> ok end),
    Delivered = fun() ->
        [
            hpr_route:id(Route)
         || {_, {_, send, [_, Route, _, _]}, _} <- meck:history(hpr_protocol_gwmp)
        ]
    end,

    {Gateway1, SigFun1} = gateway(),
    Matching = hpr_test_dataset:uplink(Dataset, "route-gwmp", 3, 100, #{
        gateway => Gateway1, sig_fun => SigFun1
    }),
    ok = hpr_routing:handle_packet(Matching, #{gateway => Gateway1}),
    ok = test_utils:wait_until(fun() -> Delivered() =:= [GwmpID] end),

    {Gateway2, SigFun2} = gateway(),
    Unknown = hpr_test_dataset:uplink(Dataset, "route-gwmp", 3, random, #{
        gateway => Gateway2, sig_fun => SigFun2
    }),
    _ = hpr_routing:handle_packet(Unknown, #{gateway => Gateway2}),
    timer:sleep(500),
    ?assertEqual([GwmpID], Delivered()),
    ok.

%% About 5,283 routes and 521k keys: storage holds exactly what was loaded,
%% the route gauges add up, and a traffic-weighted sample of uplinks each
%% find what they should.
full_dataset_test(_Config) ->
    {LoadUs, Dataset} = timer:tc(fun() -> load(full) end),
    Routes = hpr_test_dataset:routes(Dataset),
    Total = hpr_test_dataset:total_skfs(Dataset),
    ct:pal("loaded ~w routes, ~w SKFs in ~wms", [length(Routes), Total, LoadUs div 1000]),

    ok = hpr_metrics:record_routes(),
    ?assertEqual(length(Routes), prometheus_gauge:value(?METRICS_ROUTES_GAUGE)),
    ?assertEqual(Total, prometheus_gauge:value(?METRICS_SKFS_GAUGE)),

    Times = [
        timed(Packet, Expected)
     || {Packet, Expected} <- hpr_test_dataset:sample(Dataset, 2000, 0.95)
    ],
    ok = within("full dataset sample", Times, p99, ?P99_CEILING_US),
    ok.

%% 32 processes route packets while another adds and removes keys on the
%% same DevAddrs. Every lookup still finds what it should, and the table ends
%% where it started.
concurrent_lookup_test(_Config) ->
    Dataset = load(full),
    #{id := HugeID} = hpr_test_dataset:route(Dataset, "route-huge"),
    Samples =
        hpr_test_dataset:sample(Dataset, 400, 0.9) ++
            [
                {
                    hpr_test_dataset:uplink(Dataset, "route-huge", D, K),
                    hpr_test_dataset:expected(Dataset, {"route-huge", D}, K)
                }
             || D <- lists:seq(0, 7), K <- [0, 500, 1071]
            ],
    Deadline = erlang:monotonic_time(millisecond) + timer:seconds(10),

    Self = self(),
    Churn = erlang:spawn_link(fun() -> Self ! {churn, churn(Dataset, Deadline, 0)} end),
    Workers = [
        erlang:spawn_monitor(fun() -> exit({done, lookups(Samples, Deadline, 0, [])}) end)
     || _ <- lists:seq(1, 32)
    ],
    Results = [
        receive
            {'DOWN', Ref, process, Pid, {done, Result}} -> Result;
            {'DOWN', Ref, process, Pid, Other} -> ct:fail({worker_crashed, Other})
        after timer:seconds(60) -> ct:fail(worker_timeout)
        end
     || {Pid, Ref} <- Workers
    ],
    Rounds =
        receive
            {churn, R} -> R
        after timer:seconds(60) -> ct:fail({churn_timeout, Churn})
        end,

    Lookups = lists:sum([N || {N, _} <- Results]),
    Mismatches = lists:append([M || {_, M} <- Results]),
    ct:pal("~w lookups (~w/s) across 32 workers, ~w churn rounds", [
        Lookups, Lookups div 10, Rounds
    ]),
    ?assertEqual([], lists:sublist(Mismatches, 5)),
    ?assert(Rounds > 0),
    ?assertEqual(
        hpr_test_dataset:total_skfs(hpr_test_dataset:route(Dataset, "route-huge")),
        hpr_skf_storage:count_route(HugeID)
    ),
    ok.

%% A checkpoint writes a v3 file per route; with nothing changed the next one
%% writes nothing, and one changed key writes one route. A restart rebuilds
%% every route from those files.
checkpoint_rehydrate_test(_Config) ->
    Dataset = load(full),
    {CheckpointUs, ok} = timer:tc(fun checkpoint/0),
    Missing = [
        ID
     || #{id := ID} <- hpr_test_dataset:routes(Dataset),
        not filelib:is_regular(hpr_skf_storage:dets_filename(ID))
    ],
    ?assertEqual([], lists:sublist(Missing, 5)),
    ?assertEqual(0, hpr_skf_storage:checkpoint()),

    #{id := BigID, range := {BigStart, _}} = hpr_test_dataset:route(Dataset, "route-big"),
    Extra = hpr_skf:new(#{
        route_id => BigID,
        devaddr => BigStart,
        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
        max_copies => 1
    }),
    ok = hpr_skf_storage:insert(Extra),
    ?assertEqual(1, hpr_skf_storage:checkpoint()),
    ok = hpr_skf_storage:delete(Extra),
    ?assertEqual(1, hpr_skf_storage:checkpoint()),

    {RestartUs, ok} = timer:tc(fun() ->
        ok = test_utils:restart_hpr(),
        hpr_test_dataset:wait_counts(Dataset, 120, 500)
    end),
    ct:pal("checkpoint ~wms, restart and rehydrate ~wms", [
        CheckpointUs div 1000, RestartUs div 1000
    ]),
    _ = [
        check(Packet, Expected)
     || {Packet, Expected} <- hpr_test_dataset:sample(Dataset, 500, 0.95)
    ],
    ok.

%% A node upgraded from the v2 file layout loads every key from it on first
%% boot, and leaves the v2 file for a rollback.
v2_migration_test(_Config) ->
    #{seed := Seed} = Dataset = hpr_test_dataset:build(only(["route-huge"])),
    #{id := ID, route := Route, range := {Start, End}} =
        Spec = hpr_test_dataset:route(Dataset, "route-huge"),
    ok = hpr_route_storage:insert(Route),
    ok = hpr_devaddr_range_storage:insert(
        hpr_devaddr_range:test_new(#{route_id => ID, start_addr => Start, end_addr => End})
    ),
    ok = hpr_route_stream_worker:checkpoint(),
    ok = application:stop(hpr),

    V3 = hpr_skf_storage:dets_filename(ID),
    V2 = filename:join(filename:dirname(V3), "hpr_skf_" ++ ID ++ "_v2.dets"),
    ok = file:delete(V3),
    {ok, Tab} = dets:open_file(v2_migration_test, [{file, V2}, {type, set}]),
    V2Rows = [
        {
            {hpr_utils:hex_to_bin(hpr_skf:session_key(SKF)), hpr_skf:devaddr(SKF)},
            hpr_skf:max_copies(SKF)
        }
     || SKF <- hpr_test_dataset:skfs(Seed, Spec)
    ],
    ok = dets:insert(Tab, V2Rows),
    ok = dets:close(Tab),

    {ok, _} = application:ensure_all_started(hpr),
    ok = hpr_test_dataset:wait_counts(Dataset, 120, 500),
    ?assertEqual(length(V2Rows), hpr_skf_storage:count_route(ID)),
    _ = [
        check(Dataset, "route-huge", D, K)
     || D <- lists:seq(0, End - Start), K <- [0, 1071]
    ],
    ?assert(filelib:is_regular(V2)),
    ok.

%% Removing the largest route takes its keys, ranges and file with it and
%% leaves every other route alone; replacing a route's keys leaves exactly
%% the new set.
route_remove_test(_Config) ->
    Dataset = load(named),
    #{id := HugeID, route := Huge, range := {HugeStart, _}} =
        hpr_test_dataset:route(Dataset, "route-huge"),
    Others = [R || #{name := N} = R <- hpr_test_dataset:routes(Dataset), N =/= "route-huge"],
    ?assert(filelib:is_regular(hpr_skf_storage:dets_filename(HugeID))),

    ok = hpr_route_storage:delete(Huge),
    ?assertEqual({error, not_found}, hpr_route_storage:lookup(HugeID)),
    ?assertNot(filelib:is_regular(hpr_skf_storage:dets_filename(HugeID))),
    ?assertEqual([], hpr_devaddr_range_storage:lookup(HugeStart)),
    ok = hpr_test_dataset:wait_counts(Dataset#{routes => Others}, 1, 1),

    %% Keep the first half of route-big's keys on every DevAddr, swap the rest
    %% for new ones.
    #{seed := Seed} = Dataset,
    #{id := BigID, keys := BigKeys} = Big = hpr_test_dataset:route(Dataset, "route-big"),
    Half = hd(BigKeys) div 2,
    Halves = Big#{keys := [Half || _ <- BigKeys]},
    New =
        hpr_test_dataset:skfs(Seed, Halves) ++
            hpr_test_dataset:skfs(Seed, Halves#{first_key => 10000}),
    {ok, _} = hpr_skf_storage:replace_route(BigID, New),
    ?assertEqual(length(New), hpr_skf_storage:count_route(BigID)),
    ?assertEqual({error, invalid_mic}, check_find(Dataset, "route-big", 0, Half + 1)),
    _ = check(Dataset, "route-big", 0, 0),
    _ = check(Dataset, "route-big", 0, 10005),
    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

only(Names) ->
    [S || #{name := N} = S <- hpr_test_dataset:shapes(named), lists:member(N, Names)].

load(Shapes) ->
    Dataset = hpr_test_dataset:build(Shapes),
    ok = hpr_test_dataset:insert(Dataset),
    Dataset.

%% hpr_route_stream_worker:checkpoint/0 with no call timeout: the first
%% checkpoint after loading the full dataset writes every route's file, which
%% takes longer than the default 5s.
checkpoint() ->
    gen_server:call(hpr_route_stream_worker, checkpoint, infinity).

gateway() ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    {libp2p_crypto:pubkey_to_bin(PubKey), libp2p_crypto:mk_sig_fun(PrivKey)}.

%% Assert find_routes gives what the dataset says it should; return it.
check(Dataset, Name, DevAddrIdx, KeyIdx) ->
    check(
        hpr_test_dataset:uplink(Dataset, Name, DevAddrIdx, KeyIdx),
        hpr_test_dataset:expected(Dataset, {Name, DevAddrIdx}, KeyIdx)
    ).

check(Packet, Expected) ->
    Got = hpr_test_dataset:find_routes(Packet),
    ?assertEqual(Expected, Got),
    Got.

check_find(Dataset, Name, DevAddrIdx, KeyIdx) ->
    hpr_test_dataset:find_routes(hpr_test_dataset:uplink(Dataset, Name, DevAddrIdx, KeyIdx)).

timed_check(Dataset, Name, DevAddrIdx, KeyIdx, Opts) ->
    timed(
        hpr_test_dataset:uplink(Dataset, Name, DevAddrIdx, KeyIdx, Opts),
        hpr_test_dataset:expected(Dataset, {Name, DevAddrIdx}, KeyIdx)
    ).

timed(Packet, Expected) ->
    {Us, Got} = timer:tc(hpr_test_dataset, find_routes, [Packet]),
    ?assertEqual(Expected, Got),
    Us.

%% Log a timing distribution next to its ceiling, and fail only past it.
within(Label, Us, Percentile, CeilingUs) ->
    P = hpr_test_dataset:percentiles(Us),
    ct:pal("~s find_routes us: ~p (~s ceiling ~w)", [Label, P, Percentile, CeilingUs]),
    ?assert(maps:get(Percentile, P) < CeilingUs, {Label, P}),
    ok.

%% Cycle through the samples until the deadline, checking it after every
%% lookup: a pass over all of them can take seconds on a busy runner.
lookups(Samples, Deadline, N, Mismatches) ->
    lookups(Samples, Samples, Deadline, N, Mismatches).

lookups([], Samples, Deadline, N, Mismatches) ->
    lookups(Samples, Samples, Deadline, N, Mismatches);
lookups([{Packet, Expected} | Rest], Samples, Deadline, N, Mismatches) ->
    Mismatches1 =
        case hpr_test_dataset:find_routes(Packet) of
            Expected -> Mismatches;
            Got -> [{Expected, Got} | Mismatches]
        end,
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> {N + 1, Mismatches1};
        false -> lookups(Rest, Samples, Deadline, N + 1, Mismatches1)
    end.

%% Add 12 keys to each of the first eight DevAddrs of route-huge, then take
%% them out again, until the deadline.
churn(#{seed := Seed} = Dataset, Deadline, Rounds) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Rounds;
        false ->
            Spec = hpr_test_dataset:route(Dataset, "route-huge"),
            Extra = hpr_test_dataset:skfs(
                Seed, Spec#{keys := lists:duplicate(8, 12), first_key => 5000}
            ),
            lists:foreach(fun hpr_skf_storage:insert/1, Extra),
            lists:foreach(fun hpr_skf_storage:delete/1, Extra),
            churn(Dataset, Deadline, Rounds + 1)
    end.
