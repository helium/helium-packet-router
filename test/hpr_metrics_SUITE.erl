-module(hpr_metrics_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    elli_started_test/1,
    main_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("hpr_metrics.hrl").

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        elli_started_test,
        main_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

elli_started_test(_Config) ->
    ?assertMatch({ok, _}, httpc:request(get, {"http://127.0.0.1:3000/metrics", []}, [], [])),
    ok.

main_test(_Config) ->
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_test_packet_router_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),

    %% Interceptor
    Self = self(),
    %% Queue up a downlink from the testing server
    EnvDown = hpr_envelope_down:new(
        hpr_packet_down:new_downlink(
            base64:encode(<<"H3P3N2i9qc4yt7rK7ldqoeCVJGBybzPY5h1Dd7P7p8v">>),
            erlang:system_time(millisecond) band 16#FFFF_FFFF,
            904_100_000,
            'SF11BW125'
        )
    ),
    application:set_env(
        hpr,
        test_packet_router_service_route,
        fun(Env, StreamState) ->
            {packet, Packet} = hpr_envelope_up:data(Env),
            Self ! {packet_up, Packet},
            {ok, EnvDown, StreamState}
        end
    ),

    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 0,
        oui => 4020,
        server => #{
            host => "127.0.0.1",
            port => 8082,
            protocol => {packet_router, #{}}
        },
        max_copies => 2
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 802041902051071031, dev_eui => 8942655256770396549
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#00000010
        })
    ],
    {ok, GatewayPid} = hpr_test_gateway:start(#{
        forward => self(), route => Route, eui_pairs => EUIPairs, devaddr_ranges => DevAddrRanges
    }),

    %% Send packet and route directly through interface
    ok = hpr_test_gateway:send_packet(GatewayPid, #{}),

    PacketUp =
        case hpr_test_gateway:receive_send_packet(GatewayPid) of
            {ok, EnvUp} ->
                {packet, PUp} = hpr_envelope_up:data(EnvUp),
                PUp;
            {error, timeout} ->
                ct:fail(receive_send_packet)
        end,

    ok =
        receive
            {packet_up, RvcPacketUp} -> ?assertEqual(RvcPacketUp, PacketUp)
        after timer:seconds(2) -> ct:fail(no_msg_rcvd)
        end,

    case hpr_test_gateway:receive_env_down(GatewayPid) of
        {ok, GotEnvDown} ->
            ?assertEqual(EnvDown, GotEnvDown);
        {error, timeout} ->
            ct:fail(receive_env_down)
    end,

    timer:sleep(timer:seconds(2)),

    ?assertEqual(
        1,
        prometheus_gauge:value(?METRICS_GRPC_CONNECTION_GAUGE)
    ),

    ?assertNotEqual(
        undefined,
        prometheus_histogram:value(?METRICS_PACKET_UP_HISTOGRAM, [uplink, ok, 1])
    ),

    ?assertEqual(
        1,
        prometheus_counter:value(?METRICS_PACKET_UP_PER_OUI_COUNTER, [uplink, hpr_route:oui(Route)])
    ),

    ?assertEqual(
        1,
        prometheus_counter:value(?METRICS_PACKET_DOWN_COUNTER, [ok])
    ),

    ?assertEqual(
        1,
        prometheus_gauge:value(?METRICS_ROUTES_GAUGE)
    ),

    ?assertEqual(
        1,
        prometheus_gauge:value(?METRICS_EUI_PAIRS_GAUGE)
    ),

    ?assertEqual(
        0,
        prometheus_gauge:value(?METRICS_SKFS_GAUGE)
    ),

    ?assertNotEqual(
        undefined,
        prometheus_histogram:value(?METRICS_MULTI_BUY_GET_HISTOGRAM, [ok])
    ),

    ok = gen_server:stop(ServerPid),
    ok = gen_server:stop(GatewayPid),

    ok = test_utils:wait_until(
        fun() ->
            undefined =/=
                prometheus_histogram:value(?METRICS_GRPC_CONNECTION_HISTOGRAM, [
                    hpr_packet_router_service
                ])
        end
    ),

    ok.
