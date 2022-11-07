-module(hpr_protocol_router_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    grpc_test/1,
    grpc_connection_refused_test/1,
    grpc_full_flow_send_test/1,
    grpc_full_flow_connection_refused_test/1,
    grpc_full_flow_downlink_test/1
]).

-include_lib("eunit/include/eunit.hrl").

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
        grpc_test,
        grpc_connection_refused_test,
        grpc_full_flow_send_test,
        grpc_full_flow_downlink_test,
        grpc_full_flow_connection_refused_test
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
    meck:unload(),
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

grpc_test(_Config) ->
    PacketUp = test_packet(),
    Route = test_route(),

    %% Startup a test server
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => test_hpr_packet_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),

    %% Interceptor
    Self = self(),
    application:set_env(
        hpr,
        packet_service_route_fun,
        fun(Packet, Socket) ->
            Self ! {test_route, Packet},
            Socket
        end
    ),

    %% Send packet and route directly through interface
    _ = hpr_protocol_router:send(PacketUp, self(), Route),

    ok =
        receive
            {test_route, _Packet} -> ?assertEqual(_Packet, PacketUp)
        after timer:seconds(2) -> ct:fail(no_msg_rcvd)
        end,

    ok = gen_server:stop(ServerPid),

    ok.

grpc_connection_refused_test(_Config) ->
    PacketUp = test_packet(),
    Route = test_route(),

    ?assertEqual(
        {error, econnrefused},
        hpr_protocol_router:send(PacketUp, self(), Route)
    ),

    ok.

grpc_full_flow_downlink_test(_Config) ->
    %% Startup our server
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_packet_service}
        },
        listen_opts => #{port => 8080, ip => {0, 0, 0, 0}}
    }),
    %% Startup test server for receiving
    {ok, TestServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => test_hpr_packet_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),
    ok = hpr_config:insert_route(test_route()),

    %% Queue up a downlink from the testing server
    Payload = base64:encode(<<"H3P3N2i9qc4yt7rK7ldqoeCVJGBybzPY5h1Dd7P7p8v">>),
    Timestamp = erlang:system_time(millisecond) band 16#FFFF_FFFF,
    DataRate = 'SF11BW125',
    Frequency = 904_100_000,
    Down = hpr_packet_down:to_record(#{
        payload => Payload,
        rx1 => #{
            timestamp => Timestamp,
            frequency => Frequency,
            datarate => DataRate
        }
    }),
    application:set_env(
        hpr,
        packet_service_route_fun,
        fun(_PacketUp, Socket) -> {ok, Down, Socket} end
    ),

    %% Connect to our server
    {ok, Connection} = grpc_client:connect(tcp, "127.0.0.1", 8080),
    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.packet_router.packet',
        route,
        client_packet_router_pb
    ),
    %% Send a packet that expects a downlink
    ok = grpc_client:send(Stream, hpr_packet_up:to_map(test_packet())),

    %% Throw away the headers
    ?assertMatch({headers, _}, grpc_client:rcv(Stream, 500)),

    {data, Response} = grpc_client:rcv(Stream, 500),
    ?assert(
        test_utils:match_map(
            #{
                payload => Payload,
                rx1 => #{
                    timestamp => Timestamp,
                    frequency => Frequency,
                    datarate => DataRate
                }
            },
            Response
        )
    ),

    ok = gen_server:stop(ServerPid),
    ok = gen_server:stop(TestServerPid),

    ok.

grpc_full_flow_send_test(_Config) ->
    Packet = test_packet(),
    PacketMap = hpr_packet_up:to_map(Packet),
    %% Startup our server
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_packet_service}
        },
        listen_opts => #{port => 8080, ip => {0, 0, 0, 0}}
    }),

    %% Startup test server for receiving
    {ok, TestServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => test_hpr_packet_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),

    %% Forward messages to ourselves
    Self = self(),
    application:set_env(
        hpr,
        packet_service_route_fun,
        fun(PacketUp, Socket) ->
            Self ! {test_route, PacketUp},
            Socket
        end
    ),

    %% Insert the matching route for the test packet
    ok = hpr_config:insert_route(test_route()),
    meck:new(hpr_packet_service, [passthrough]),

    {ok, Connection} = grpc_client:connect(tcp, "127.0.0.1", 8080),
    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.packet_router.packet',
        route,
        client_packet_router_pb
    ),
    ok = grpc_client:send(Stream, PacketMap),

    ok =
        receive
            {test_route, P} -> ?assertEqual(P, Packet)
        after 250 -> ct:fail(no_packet_delivered)
        end,

    ?assertEqual(
        1,
        meck:num_calls(hpr_packet_service, route, '_'),
        "we should only attempt to send a packet 1 time"
    ),

    %% ===================================================================
    %% We're stopping the test server to make sure we don't try to deliver
    %% multiple times for a connection we cannot make or has gone down.
    %% Also, resetting the mock to make sure route is called once.
    ok = gen_server:stop(TestServerPid),
    ok = meck:reset(hpr_packet_service),

    ok = grpc_client:send(Stream, PacketMap),
    ok =
        receive
            {test_route, _} -> ct:fail(expected_no_packet)
        after 250 -> ok
        end,

    ?assertEqual(
        1,
        meck:num_calls(hpr_packet_service, route, '_'),
        "we should only attempt to send a packet 1 time, even if it failed"
    ),

    ok = gen_server:stop(ServerPid),

    ok.

grpc_full_flow_connection_refused_test(_Config) ->
    Packet = test_packet(),
    PacketMap = hpr_packet_up:to_map(Packet),
    %% Startup our server
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_packet_service}
        },
        listen_opts => #{port => 8080, ip => {0, 0, 0, 0}}
    }),

    %% Insert the matching route for the test packet
    ok = hpr_config:insert_route(test_route()),

    {ok, Connection} = grpc_client:connect(tcp, "127.0.0.1", 8080),
    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.packet_router.packet',
        route,
        client_packet_router_pb
    ),
    ok = grpc_client:send(Stream, PacketMap),

    %% ===================================================================
    %% The test server is not started in this test. I'm not sure this test is
    %% accurate yet. But it is here for when we understand more about why
    %% grpcbox recalls its service handler when something fails.

    meck:new(hpr_packet_service, [passthrough]),
    ok = grpc_client:send(Stream, PacketMap),
    ok =
        receive
            {test_route, _} -> ct:fail(expected_no_packet)
        after 250 -> ok
        end,

    ?assertEqual(1, meck:num_calls(hpr_packet_service, route, '_')),

    ok = gen_server:stop(ServerPid),

    ok.

%% ===================================================================
%% Helpers
%% ===================================================================

test_packet() ->
    {
        packet_router_packet_up_v1_pb,
        <<0, 55, 148, 187, 74, 220, 108, 33, 11, 133, 65, 148, 104, 147, 177, 26, 124, 43, 169, 155,
            182, 228, 95>>,
        1664302882470,
        0,
        904700012,
        'SF10BW125',
        5.5,
        'US915',
        0,
        <<0, 106, 152, 166, 157, 156, 48, 101, 22, 212, 221, 120, 200, 146, 186, 112, 220, 64, 11,
            194, 219, 213, 8, 12, 240, 111, 23, 167, 28, 57, 242, 244, 222>>,
        <<48, 70, 2, 33, 0, 138, 89, 109, 110, 139, 188, 36, 99, 176, 239, 254, 141, 73, 13, 204,
            110, 139, 248, 200, 250, 209, 218, 168, 183, 92, 190, 212, 202, 17, 78, 250, 95, 2, 33,
            0, 142, 149, 198, 0, 113, 83, 115, 99, 67, 245, 98, 243, 147, 71, 12, 112, 78, 181, 25,
            153, 65, 66, 240, 124, 85, 151, 38, 207, 172, 107, 9, 218>>
    }.

test_route() ->
    hpr_route:new(#{
        id => <<"7d502f32-4d58-4746-965e-8c7dfdcfc624">>,
        net_id => 12582995,
        devaddr_ranges => [#{start_addr => 0, end_addr => 4294967295}],
        euis => [#{app_eui => 802041902051071031, dev_eui => 8942655256770396549}],
        oui => 4020,
        server => #{
            host => <<"127.0.0.1">>,
            port => 8082,
            protocol => {packet_router, #{}}
        },
        max_copies => 1,
        nonce => 1
    }).
