%%%-------------------------------------------------------------------
%% @doc
%% hpr_test_dataset's route shapes arriving the way production config does:
%% over the iot-config route stream, one message per route, range and session
%% key filter.
%%
%% Large volumes go straight into hpr_route_stream_worker as the messages its
%% gRPC client delivers (see hpr_test_dataset:push/1). Resuming after a
%% restart goes through the mock iot-config service, hpr_test_ics_route_service,
%% because what it tests is the `since' HPR sends there.
%% @end
%%%-------------------------------------------------------------------
-module(hpr_route_stream_load_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    stream_huge_route_test/1,
    stream_named_routes_test/1,
    stream_updates_under_lookup_test/1,
    resume_after_restart_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

all() ->
    [
        stream_huge_route_test,
        stream_named_routes_test,
        stream_updates_under_lookup_test,
        resume_after_restart_test
    ].

init_per_testcase(TestCase, Config) ->
    Config1 = test_utils:init_per_testcase(TestCase, Config),
    ok = hpr_test_dataset:quiet_logs(),
    Config1.

end_per_testcase(TestCase, Config) ->
    ok = hpr_test_ics_route_service:clear_queue(),
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%% 137,216 SKFs for one route, streamed: all of them land, and route.
stream_huge_route_test(_Config) ->
    Dataset = hpr_test_dataset:build(only(["route-huge"])),
    Total = hpr_test_dataset:total_skfs(Dataset),
    {Us, ok} = timer:tc(fun() ->
        ok = hpr_test_dataset:stream(Dataset, 100),
        hpr_test_dataset:wait_counts(Dataset)
    end),
    ct:pal("streamed ~w SKFs in ~wms (~w/s)", [Total, Us div 1000, Total * 1000000 div Us]),
    ?assertMatch(
        #{route := 1, devaddr_range := 1, skf := Total}, hpr_route_stream_worker:test_counts()
    ),
    _ = [
        check(Packet, Expected)
     || {Packet, Expected} <- hpr_test_dataset:sample(Dataset, 200, 0.9)
    ],
    ok.

%% Every named shape, streamed: the shared block's active and inactive routes
%% both arrive and resolve the way they do when loaded directly.
stream_named_routes_test(_Config) ->
    Dataset = hpr_test_dataset:build(named),
    {Us, ok} = timer:tc(fun() ->
        ok = hpr_test_dataset:stream(Dataset, 100),
        hpr_test_dataset:wait_counts(Dataset)
    end),
    ct:pal("streamed ~w routes, ~w SKFs in ~wms", [
        length(hpr_test_dataset:routes(Dataset)),
        hpr_test_dataset:total_skfs(Dataset),
        Us div 1000
    ]),
    #{id := InactiveID} = hpr_test_dataset:route(Dataset, "route-gwmp-inactive"),
    ?assertMatch({ok, [_, _]}, check(Dataset, "route-gwmp", 2, 10)),
    ?assertEqual({ok, [{InactiveID, 0}]}, check(Dataset, "route-gwmp", 2, random)),
    _ = [
        check(Packet, Expected)
     || {Packet, Expected} <- hpr_test_dataset:sample(Dataset, 500, 0.9)
    ],
    ok.

%% Keys added and removed over the stream while packets are being routed on
%% the same DevAddrs: lookups for keys left alone never miss, and the table
%% ends up with exactly the added keys and without the removed ones.
stream_updates_under_lookup_test(_Config) ->
    #{seed := Seed} = Dataset = hpr_test_dataset:build(only(["route-huge"])),
    ok = hpr_test_dataset:insert(Dataset),
    #{id := ID, keys := Keys} = Spec = hpr_test_dataset:route(Dataset, "route-huge"),
    DevAddrs = length(Keys),

    %% Keys 0-999 are left alone and looked up; 1000-1071 are removed; 40 new
    %% ones per DevAddr are added from index 5000.
    Removed = hpr_test_dataset:skfs(Seed, Spec#{
        keys := lists:duplicate(DevAddrs, 72), first_key => 1000
    }),
    Added = hpr_test_dataset:skfs(Seed, Spec#{
        keys := lists:duplicate(DevAddrs, 40), first_key => 5000
    }),
    Samples = [
        {
            hpr_test_dataset:uplink(Dataset, "route-huge", D, K),
            hpr_test_dataset:expected(Dataset, {"route-huge", D}, K)
        }
     || D <- lists:seq(0, DevAddrs - 1, 4), K <- [0, 999]
    ],

    Stop = erlang:make_ref(),
    Self = self(),
    Workers = [
        erlang:spawn_link(fun() -> Self ! {self(), lookups(Samples, Stop, 0, [])} end)
     || _ <- lists:seq(1, 8)
    ],
    ok = hpr_test_dataset:push([
        hpr_route_stream_res:test_new(#{action => Action, data => {skf, SKF}, timestamp => 100})
     || {Action, SKF} <- [{add, S} || S <- Added] ++ [{remove, S} || S <- Removed]
    ]),
    Expected = hpr_test_dataset:total_skfs(Spec) + length(Added) - length(Removed),
    ok = test_utils:wait_until(
        fun() ->
            case hpr_skf_storage:count_route(ID) of
                Expected -> true;
                Other -> {false, {count, Other, expected, Expected}}
            end
        end,
        300,
        200
    ),
    [Pid ! Stop || Pid <- Workers],
    Results = [
        receive
            {Pid, R} -> R
        after timer:seconds(60) -> ct:fail(worker_timeout)
        end
     || Pid <- Workers
    ],
    ct:pal("~w lookups while streaming ~w adds and ~w removes", [
        lists:sum([N || {N, _} <- Results]), length(Added), length(Removed)
    ]),
    ?assertEqual([], lists:sublist(lists:append([M || {_, M} <- Results]), 5)),

    ?assertEqual({error, invalid_mic}, find(Dataset, 0, 1050)),
    _ = check(Dataset, "route-huge", 0, 5010),
    ok.

%% HPR resumes the stream from its last checkpoint after a restart: config
%% changed while it was down arrives, config it already had is not sent
%% again. If `since' went out in milliseconds, iot-config (and this mock) would
%% read it as a time far in the future and send nothing.
resume_after_restart_test(_Config) ->
    %% Small enough for the mock service to stream in full.
    #{seed := Seed} = Dataset = hpr_test_dataset:build(only(["route-high-devaddr"])),
    #{id := ID, route := Route, keys := Keys} =
        Spec = hpr_test_dataset:route(Dataset, "route-high-devaddr"),
    Resp = fun(Data, Timestamp) ->
        hpr_route_stream_res:test_new(#{action => add, data => Data, timestamp => Timestamp})
    end,

    Sent = hpr_test_dataset:responses(Dataset, 100),
    [ok = hpr_test_ics_route_service:stream_resp(R) || R <- Sent],
    ok = hpr_test_dataset:wait_counts(Dataset),
    %% Timestamps are inclusive; a later message moves the resume point past
    %% everything above.
    ok = hpr_test_ics_route_service:stream_resp(Resp({route, Route}, 150)),
    ok = test_utils:wait_until(fun() -> hpr_route_stream_worker:last_timestamp() =:= 150000 end),
    ok = hpr_route_stream_worker:checkpoint(),
    ok = application:stop(hpr),

    %% What iot-config holds by the time HPR is back: everything it already
    %% sent, and 250 new keys written while HPR was down.
    New = lists:sublist(
        hpr_test_dataset:skfs(Seed, Spec#{
            keys := lists:duplicate(length(Keys), 63), first_key => 1000
        }),
        250
    ),
    ok = hpr_test_ics_route_service:queue_resp(
        Sent ++ [Resp({route, Route}, 150)] ++ [Resp({skf, SKF}, 200) || SKF <- New]
    ),

    {ok, _} = application:ensure_all_started(hpr),
    Total = hpr_test_dataset:total_skfs(Spec) + length(New),
    ok = test_utils:wait_until(
        fun() ->
            case hpr_skf_storage:count_route(ID) of
                Total -> true;
                Other -> {false, {count, Other, expected, Total}}
            end
        end,
        100,
        200
    ),
    %% Only the resume point itself (inclusive) and the new keys came back.
    ?assertMatch(
        #{route := 1, devaddr_range := 0, eui_pair := 0, skf := 250},
        hpr_route_stream_worker:test_counts()
    ),
    _ = check(Dataset, "route-high-devaddr", 0, 1000),
    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

only(Names) ->
    [S || #{name := N} = S <- hpr_test_dataset:shapes(named), lists:member(N, Names)].

check(Dataset, Name, DevAddrIdx, KeyIdx) ->
    check(
        hpr_test_dataset:uplink(Dataset, Name, DevAddrIdx, KeyIdx),
        hpr_test_dataset:expected(Dataset, {Name, DevAddrIdx}, KeyIdx)
    ).

check(Packet, Expected) ->
    Got = hpr_test_dataset:find_routes(Packet),
    ?assertEqual(Expected, Got),
    Got.

find(Dataset, DevAddrIdx, KeyIdx) ->
    hpr_test_dataset:find_routes(
        hpr_test_dataset:uplink(Dataset, "route-huge", DevAddrIdx, KeyIdx)
    ).

%% Route the samples over and over until told to stop.
lookups(Samples, Stop, N, Mismatches) ->
    receive
        Stop -> {N, Mismatches}
    after 0 ->
        Mismatches1 = lists:foldl(
            fun({Packet, Expected}, Acc) ->
                case hpr_test_dataset:find_routes(Packet) of
                    Expected -> Acc;
                    Got -> [{Expected, Got} | Acc]
                end
            end,
            Mismatches,
            Samples
        ),
        lookups(Samples, Stop, N + length(Samples), Mismatches1)
    end.
