-module(hpr_metrics_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    elli_started_test/1,
    main_test/1,
    record_routes_test/1
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
        main_test,
        record_routes_test
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
        prometheus_histogram:value(?METRICS_MULTI_BUY_GET_HISTOGRAM, ["default", ok])
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

    ok = test_utils:wait_until(
        fun() ->
            undefined =/=
                prometheus_histogram:value(?METRICS_ICS_GATEWAY_LOCATION_HISTOGRAM, [
                    not_found
                ])
        end
    ),

    ok.

record_routes_test(_Config) ->
    %% Setup Route 1: Normal route with DevAddr range and SKFs
    RouteID1 = "RouteID1",
    OUI1 = 1001,
    Route1 = hpr_route:test_new(#{
        id => RouteID1,
        net_id => 0,
        oui => OUI1,
        server => #{
            host => "127.0.0.1",
            port => 8080,
            protocol => {packet_router, #{}}
        },
        max_copies => 1
    }),

    %% Setup Route 2: Broken route with SKFs but no DevAddr range (active, not locked)
    RouteID2 = "RouteID2",
    OUI2 = 2002,
    Route2 = hpr_route:test_new(#{
        id => RouteID2,
        net_id => 0,
        oui => OUI2,
        server => #{
            host => "127.0.0.1",
            port => 8081,
            protocol => {packet_router, #{}}
        },
        max_copies => 1
    }),

    %% Setup Route 3: Route with DevAddr range but no SKFs
    RouteID3 = "RouteID3",
    OUI3 = 3003,
    Route3 = hpr_route:test_new(#{
        id => RouteID3,
        net_id => 0,
        oui => OUI3,
        server => #{
            host => "127.0.0.1",
            port => 8082,
            protocol => {packet_router, #{}}
        },
        max_copies => 1
    }),

    %% Setup Route 4: Has SKFs but no DevAddr, but is NOT active (should not be broken)
    RouteID4 = "RouteID4",
    OUI4 = 4004,
    Route4 = hpr_route:test_new(#{
        id => RouteID4,
        net_id => 0,
        oui => OUI4,
        server => #{
            host => "127.0.0.1",
            port => 8083,
            protocol => {packet_router, #{}}
        },
        max_copies => 1,
        active => false
    }),

    %% Setup Route 5: Has SKFs but no DevAddr, but IS locked (should not be broken)
    RouteID5 = "RouteID5",
    OUI5 = 5005,
    Route5 = hpr_route:test_new(#{
        id => RouteID5,
        net_id => 0,
        oui => OUI5,
        server => #{
            host => "127.0.0.1",
            port => 8084,
            protocol => {packet_router, #{}}
        },
        max_copies => 1,
        locked => true
    }),

    %% Add routes to storage
    ok = hpr_route_storage:insert(Route1),
    ok = hpr_route_storage:insert(Route2),
    ok = hpr_route_storage:insert(Route3),
    ok = hpr_route_storage:insert(Route4),
    ok = hpr_route_storage:insert(Route5),

    %% Wait for all routes to be inserted
    ok = test_utils:wait_until(fun() ->
        5 =:= ets:info(hpr_routes_ets, size)
    end),

    %% Add DevAddr ranges for Route 1 and Route 3
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1,
        start_addr => 16#00000000,
        end_addr => 16#000000FF
    }),
    DevAddrRange3 = hpr_devaddr_range:test_new(#{
        route_id => RouteID3,
        start_addr => 16#00000100,
        end_addr => 16#000001FF
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange1),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange3),

    %% Add SKFs to Route 1 and Route 2
    %% Route 1 will have 2 SKFs and has DevAddr range (not broken)
    SKF1_1 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => 16#00000001,
        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
        max_copies => 1
    }),
    SKF1_2 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => 16#00000002,
        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
        max_copies => 1
    }),
    ok = hpr_skf_storage:insert(SKF1_1),
    ok = hpr_skf_storage:insert(SKF1_2),

    %% Route 2 will have 3 SKFs but no DevAddr range (broken because active and not locked)
    SKF2_1 = hpr_skf:new(#{
        route_id => RouteID2,
        devaddr => 16#00000010,
        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
        max_copies => 1
    }),
    SKF2_2 = hpr_skf:new(#{
        route_id => RouteID2,
        devaddr => 16#00000011,
        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
        max_copies => 1
    }),
    SKF2_3 = hpr_skf:new(#{
        route_id => RouteID2,
        devaddr => 16#00000012,
        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
        max_copies => 1
    }),
    ok = hpr_skf_storage:insert(SKF2_1),
    ok = hpr_skf_storage:insert(SKF2_2),
    ok = hpr_skf_storage:insert(SKF2_3),

    %% Route 4 will have 2 SKFs but no DevAddr range (NOT broken because inactive)
    SKF4_1 = hpr_skf:new(#{
        route_id => RouteID4,
        devaddr => 16#00000020,
        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
        max_copies => 1
    }),
    SKF4_2 = hpr_skf:new(#{
        route_id => RouteID4,
        devaddr => 16#00000021,
        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
        max_copies => 1
    }),
    ok = hpr_skf_storage:insert(SKF4_1),
    ok = hpr_skf_storage:insert(SKF4_2),

    %% Route 5 will have 1 SKF but no DevAddr range (NOT broken because locked)
    SKF5_1 = hpr_skf:new(#{
        route_id => RouteID5,
        devaddr => 16#00000030,
        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
        max_copies => 1
    }),
    ok = hpr_skf_storage:insert(SKF5_1),

    %% Call record_routes
    ok = hpr_metrics:record_routes(),

    %% Verify metrics
    %% Should have 5 routes total
    ?assertEqual(
        5,
        prometheus_gauge:value(?METRICS_ROUTES_GAUGE)
    ),

    %% Should have 8 SKFs total (2 from Route1 + 3 from Route2 + 0 from Route3 + 2 from Route4 + 1 from Route5)
    ?assertEqual(
        8,
        prometheus_gauge:value(?METRICS_SKFS_GAUGE)
    ),

    %% Should have 1 broken route (Route2) for OUI2
    %% Route2 is broken because it has SKFs, no DevAddr range, is active, and is not locked
    ?assertEqual(
        1,
        prometheus_gauge:value(?METRICS_BROKEN_ROUTES_GAUGE, [OUI2])
    ),

    %% OUI1 and OUI3 should not have broken routes (they have DevAddr ranges)
    ?assertEqual(
        undefined,
        prometheus_gauge:value(?METRICS_BROKEN_ROUTES_GAUGE, [OUI1])
    ),
    ?assertEqual(
        undefined,
        prometheus_gauge:value(?METRICS_BROKEN_ROUTES_GAUGE, [OUI3])
    ),

    %% OUI4 should not have broken routes (route is inactive)
    ?assertEqual(
        undefined,
        prometheus_gauge:value(?METRICS_BROKEN_ROUTES_GAUGE, [OUI4])
    ),

    %% OUI5 should not have broken routes (route is locked)
    ?assertEqual(
        undefined,
        prometheus_gauge:value(?METRICS_BROKEN_ROUTES_GAUGE, [OUI5])
    ),

    ok.
