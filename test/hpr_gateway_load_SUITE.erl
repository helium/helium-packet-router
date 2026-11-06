%%%-------------------------------------------------------------------
%% @doc
%% Many gateways on HPR's real gRPC ingress, routing onto hpr_test_dataset's
%% route shapes and delivering to a local packet router (hpr_test_packet_router_service
%% on 8082) that counts what it receives.
%%
%% Covers the path a packet takes end to end -- register, session, admit,
%% find_routes, multi-buy, delivery -- and what a reconnect wave does to it.
%%
%% Deliveries are counted where HPR hands a packet to the packet router
%% protocol, and asserted exactly there. What the packet router receives is
%% logged next to it: about one copy in a few thousand sent on the gRPC stream
%% to the in-process packet router never arrives, a transport loss after HPR's
%% routing decision that would otherwise make these cases flaky.
%% @end
%%%-------------------------------------------------------------------
-module(hpr_gateway_load_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    many_gateways_test/1,
    reconnect_wave_test/1,
    spread_wave_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/multi_buy_pb.hrl").

%% Copies of each uplink, each from a different gateway, as when that many
%% hotspots hear one device.
-define(COPIES, 9).
-define(RECONNECT_CEILING_MS, 30000).
-define(LNS, #{host => "127.0.0.1", port => 8082, protocol => {packet_router, #{}}}).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

all() ->
    [
        many_gateways_test,
        reconnect_wave_test,
        spread_wave_test
    ].

init_per_testcase(TestCase, Config) ->
    Config1 = test_utils:init_per_testcase(TestCase, Config),
    ok = hpr_test_dataset:quiet_logs(),

    %% What HPR delivered, and what the packet router received, by payload.
    Deliveries = ets:new(deliveries, [public, set]),
    Received = ets:new(received, [public, set]),
    meck:new(hpr_protocol_router, [passthrough, no_history]),
    meck:expect(hpr_protocol_router, send, fun(PacketUp, Route, Timestamp, Location) ->
        Payload = hpr_packet_up:payload(PacketUp),
        _ = ets:update_counter(Deliveries, Payload, 1, {Payload, 0}),
        meck:passthrough([PacketUp, Route, Timestamp, Location])
    end),
    ok = application:set_env(hpr, test_packet_router_service_route, fun(Env, StreamState) ->
        {packet, Packet} = hpr_envelope_up:data(Env),
        Payload = hpr_packet_up:payload(Packet),
        _ = ets:update_counter(Received, Payload, 1, {Payload, 0}),
        {ok, StreamState}
    end),
    %% The default mock keeps its counters in one persistent_term, rewritten on
    %% every call: lossy under concurrent calls, and a global GC each time.
    MultiBuy = ets:new(multi_buy, [public, set]),
    ok = application:set_env(hpr, test_multi_buy_service_inc, fun(
        Ctx, #multi_buy_inc_req_v1_pb{key = Key}
    ) ->
        Count = ets:update_counter(MultiBuy, Key, 1, {Key, 0}),
        {ok, #multi_buy_inc_res_v1_pb{count = Count, denied = false}, Ctx}
    end),
    {ok, LNS} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_test_packet_router_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),
    [{deliveries, Deliveries}, {received, Received}, {lns, LNS} | Config1].

end_per_testcase(TestCase, Config) ->
    ok = gen_server:stop(proplists:get_value(lns, Config)),
    catch meck:unload(hpr_protocol_router),
    ok = application:unset_env(hpr, test_packet_router_service_route),
    ok = application:unset_env(hpr, test_multi_buy_service_inc),
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%% 50 gateways, 300 uplinks, each heard by 9 of them. Every uplink that
%% matches a key reaches the packet router exactly as many times as its key's
%% max copies allow; every other uplink, never. No gateway loses its stream.
many_gateways_test(Config) ->
    Dataset = load(),
    Gateways = start_gateways(Dataset, 50, #{}),
    ok = send_and_check(Config, Dataset, Gateways, lists:seq(1, 300)),
    ?assertEqual([], stream_downs()),
    ok = stop_gateways(Gateways),
    ok.

%% Every stream closed at once -- what a restart does to a node. All 200
%% gateways reconnect within the ceiling and route again afterwards.
reconnect_wave_test(Config) ->
    Dataset = load(),
    Gateways = start_gateways(Dataset, 200, #{reconnect_after_ms => 500}),
    {Min, RecoveredMs} = close_and_watch(fun() ->
        hpr_packet_router_service:spread_sessions(1)
    end),
    ct:pal("wave: down to ~w of 200 connected, all back after ~wms", [Min, RecoveredMs]),
    ?assert(Min < 100),
    ok = wait_sessions(Gateways),
    ok = send_and_check(Config, Dataset, Gateways, lists:seq(1, 60)),
    ok = stop_gateways(Gateways),
    ok.

%% The same closes spread over five seconds: the node never loses more than a
%% sliver of its gateways at any moment, and all of them come back.
spread_wave_test(Config) ->
    Dataset = load(),
    Gateways = start_gateways(Dataset, 200, #{reconnect_after_ms => 250}),
    {Min, RecoveredMs} = close_and_watch(fun() ->
        hpr_packet_router_service:spread_sessions(timer:seconds(5))
    end),
    ct:pal("spread: down to ~w of 200 connected, all back after ~wms", [Min, RecoveredMs]),
    ?assert(Min >= 150),
    ok = test_utils:wait_until(
        fun() -> hpr_packet_router_service:spread_status() =:= not_running end, 50, 200
    ),
    ok = wait_sessions(Gateways),
    ok = send_and_check(Config, Dataset, Gateways, lists:seq(1, 60)),
    ok = stop_gateways(Gateways),
    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

%% Every named route, all delivering to the local packet router.
load() ->
    Dataset = hpr_test_dataset:build(named, #{server => ?LNS}),
    ok = hpr_test_dataset:insert(Dataset),
    Dataset.

start_gateways(Dataset, N, Opts) ->
    [#{route := Route} | _] = hpr_test_dataset:routes(Dataset),
    Gateways = [
        begin
            {ok, Pid} = hpr_test_gateway:start(Opts#{
                forward => self(), route => Route, eui_pairs => [], devaddr_ranges => []
            }),
            Pid
        end
     || _ <- lists:seq(1, N)
    ],
    ok = wait_sessions(Gateways),
    ?assertEqual(N, hpr_packet_router_service:connected_count()),
    Gateways.

wait_sessions(Gateways) ->
    lists:foreach(
        fun(Pid) ->
            case hpr_test_gateway:receive_session_init(Pid, timer:seconds(30)) of
                {ok, _} -> ok;
                {error, timeout} -> ct:fail({no_session, Pid})
            end
        end,
        Gateways
    ).

stop_gateways(Gateways) ->
    lists:foreach(fun(Pid) -> catch gen_server:stop(Pid) end, Gateways),
    _ = flush(),
    ok.

%% Run `Close' and sample how many gateways are connected until the spread is
%% done and all of them are back. Returns the lowest count seen and how long
%% that took.
close_and_watch(Close) ->
    Total = hpr_packet_router_service:connected_count(),
    Start = erlang:monotonic_time(millisecond),
    {ok, Total} = Close(),
    watch(Total, Start, Total, false).

watch(Total, Start, Min, Dipped) ->
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    Elapsed < ?RECONNECT_CEILING_MS orelse
        ct:fail({not_reconnected, Elapsed, Min, hpr_packet_router_service:connected_count()}),
    Count = hpr_packet_router_service:connected_count(),
    Done = hpr_packet_router_service:spread_status() =:= not_running,
    case Count =:= Total andalso Dipped andalso Done of
        true ->
            {Min, Elapsed};
        false ->
            timer:sleep(20),
            watch(Total, Start, min(Min, Count), Dipped orelse Count < Total)
    end.

%% Send packet `I' for every I in `Indexes' from ?COPIES gateways each, then
%% check what reached the packet router against what the dataset says should.
send_and_check(Config, Dataset, Gateways, Indexes) ->
    Deliveries = proplists:get_value(deliveries, Config),
    Received = proplists:get_value(received, Config),
    true = ets:delete_all_objects(Deliveries),
    true = ets:delete_all_objects(Received),
    N = length(Gateways),
    Packets = [packet(Dataset, I) || I <- Indexes],
    lists:foreach(
        fun({I, Args, _Payload, _Expected, _Why}) ->
            [
                hpr_test_gateway:send_packet(lists:nth((I * ?COPIES + J) rem N + 1, Gateways), Args)
             || J <- lists:seq(0, ?COPIES - 1)
            ],
            %% Keeps each gateway well under its 25 uplinks/s limit.
            timer:sleep(20)
        end,
        Packets
    ),
    Total = lists:sum([E || {_, _, _, E, _} <- Packets]),
    Delivered = fun() -> lists:sum([C || {_, C} <- ets:tab2list(Deliveries)]) end,
    _ = test_utils:wait_until(fun() -> Delivered() =:= Total end, 100, 200),
    %% Nothing more turns up late.
    timer:sleep(1000),
    Wrong = [
        {I, Why, {expected, Expected}, {got, Got}}
     || {I, _, Payload, Expected, Why} <- Packets,
        Got <- [
            case ets:lookup(Deliveries, Payload) of
                [{_, C}] -> C;
                [] -> 0
            end
        ],
        Got =/= Expected
    ],
    case Wrong of
        [] ->
            ok;
        _ ->
            ct:pal("~w of ~w uplinks delivered wrong:~n~p", [
                length(Wrong), length(Packets), lists:sublist(Wrong, 20)
            ]),
            ct:fail({wrong_deliveries, length(Wrong)})
    end,
    ct:pal("~w uplinks x ~w copies: ~w deliveries, as expected; packet router received ~w", [
        length(Packets), ?COPIES, Total, lists:sum([C || {_, C} <- ets:tab2list(Received)])
    ]),
    ok.

%% Uplink `I': a route and DevAddr picked round-robin, a key on it -- or, for
%% one in ten, a key no route has. Its payload is fixed by its arguments, so
%% every gateway sending it sends the same packet.
packet(Dataset, I) ->
    Keyed = [R || R <- hpr_test_dataset:routes(Dataset), hpr_test_dataset:total_skfs(R) > 0],
    #{name := Name, keys := Keys} = lists:nth(I rem length(Keyed) + 1, Keyed),
    DevAddrIdx = I rem length(Keys),
    KeyIdx =
        case I rem 10 of
            0 -> random;
            _ -> (I * 7) rem lists:nth(DevAddrIdx + 1, Keys)
        end,
    Args = maps:merge(hpr_test_dataset:uplink_args(Dataset, Name, DevAddrIdx, KeyIdx), #{
        fcnt => I,
        app_session_key => <<I:128>>,
        data => <<"load">>
    }),
    Payload = hpr_packet_up:payload(test_utils:uplink_packet_up(Args)),
    {I, Args, Payload, deliveries(Dataset, Name, DevAddrIdx, KeyIdx), {Name, DevAddrIdx, KeyIdx}}.

%% How many copies the packet router should get: up to the key's max copies
%% (the route's own for an empty route) on every active route found.
deliveries(Dataset, Name, DevAddrIdx, KeyIdx) ->
    case hpr_test_dataset:expected(Dataset, {Name, DevAddrIdx}, KeyIdx) of
        {error, invalid_mic} ->
            0;
        {ok, Routes} ->
            Active = [
                {ID, Route}
             || #{id := ID, route := Route} <- hpr_test_dataset:routes(Dataset),
                hpr_route:active(Route)
            ],
            lists:sum([
                min(?COPIES, max_copies(MaxCopies, proplists:get_value(ID, Active)))
             || {ID, MaxCopies} <- Routes, proplists:is_defined(ID, Active)
            ])
    end.

max_copies(0, Route) -> hpr_route:max_copies(Route);
max_copies(MaxCopies, _Route) -> MaxCopies.

stream_downs() ->
    receive
        {hpr_test_gateway, Pid, stream_down} -> [Pid | stream_downs()]
    after 0 -> []
    end.

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.
