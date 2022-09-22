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
    grpc_full_flow_downlink_test/1,
    relay_test/1
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
        grpc_full_flow_connection_refused_test,
        grpc_full_flow_downlink_test,
        relay_test
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
            services => #{'helium.packet_router.gateway' => test_hpr_gateway_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),

    %% Interceptor
    Self = self(),
    application:set_env(
        hpr,
        gateway_service_send_packet_fun,
        fun(Packet, Socket) ->
            Self ! {test_send_packet, Packet},
            Socket
        end
    ),

    %% Send packet and route directly through interface
    _ = hpr_protocol_router:send(PacketUp, self(), Route),

    ok =
        receive
            {test_send_packet, _Packet} -> ?assertEqual(_Packet, PacketUp)
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
            services => #{'helium.packet_router.gateway' => hpr_gateway_service}
        },
        listen_opts => #{port => 8080, ip => {0, 0, 0, 0}}
    }),
    %% Startup test server for receiving
    {ok, TestServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.gateway' => test_hpr_gateway_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),
    ok = hpr_routing_config_worker:insert(test_route()),

    %% Queue up a downlink from the testing server
    Payload = base64:encode(<<"H3P3N2i9qc4yt7rK7ldqoeCVJGBybzPY5h1Dd7P7p8v">>),
    Timestamp = erlang:system_time(millisecond) band 16#FFFF_FFFF,
    DataRate = 'SF11BW125',
    Down = hpr_packet_down:to_record(#{
        payload => Payload,
        rx1 => #{
            timestamp => Timestamp,
            frequency => 904.1,
            datarate => DataRate
        }
    }),
    application:set_env(
        hpr,
        gateway_service_send_packet_fun,
        fun(_PacketUp, Socket) -> {ok, Down, Socket} end
    ),

    %% Connect to our server
    {ok, Connection} = grpc_client:connect(tcp, "127.0.0.1", 8080),
    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.packet_router.gateway',
        send_packet,
        client_packet_router_pb
    ),
    %% Send a packet that expects a downlink
    ok = grpc_client:send(Stream, hpr_packet_up:to_map(test_packet())),

    %% Throw away the headers
    ?assertMatch({headers, _}, grpc_client:rcv(Stream, 500)),

    %% Make sure the downlink received is relatively the same.
    %% floats will be floats.
    %% NOTE: future change to proto will be changing frequency from mhz -> hz
    {data, Response} = grpc_client:rcv(Stream, 500),
    ?assert(
        test_utils:match_map(
            #{
                payload => Payload,
                rx1 => #{
                    timestamp => Timestamp,
                    frequency => fun erlang:is_float/1,
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
            services => #{'helium.packet_router.gateway' => hpr_gateway_service}
        },
        listen_opts => #{port => 8080, ip => {0, 0, 0, 0}}
    }),

    %% Startup test server for receiving
    {ok, TestServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.gateway' => test_hpr_gateway_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),

    %% Forward messages to ourselves
    Self = self(),
    application:set_env(
        hpr,
        gateway_service_send_packet_fun,
        fun(PacketUp, Socket) ->
            Self ! {test_send_packet, PacketUp},
            Socket
        end
    ),

    %% Insert the matching route for the test packet
    ok = hpr_routing_config_worker:insert(test_route()),
    meck:new(hpr_gateway_service, [passthrough]),

    {ok, Connection} = grpc_client:connect(tcp, "127.0.0.1", 8080),
    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.packet_router.gateway',
        send_packet,
        client_packet_router_pb
    ),
    ok = grpc_client:send(Stream, PacketMap),

    ok =
        receive
            {test_send_packet, P} -> ?assertEqual(P, Packet)
        after 250 -> ct:fail(no_packet_delivered)
        end,

    ?assertEqual(
        1,
        meck:num_calls(hpr_gateway_service, send_packet, '_'),
        "we should only attempt to send a packet 1 time"
    ),

    %% ===================================================================
    %% We're stopping the test server to make sure we don't try to deliver
    %% multiple times for a connection we cannot make or has gone down.
    %% Also, resetting the mock to make sure send_packet is called once.
    ok = gen_server:stop(TestServerPid),
    ok = meck:reset(hpr_gateway_service),

    ok = grpc_client:send(Stream, PacketMap),
    ok =
        receive
            {test_send_packet, _} -> ct:fail(expected_no_packet)
        after 250 -> ok
        end,

    ?assertEqual(
        1,
        meck:num_calls(hpr_gateway_service, send_packet, '_'),
        "we should only attempt to senda packet 1 time, even if it failed"
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
            services => #{'helium.packet_router.gateway' => hpr_gateway_service}
        },
        listen_opts => #{port => 8080, ip => {0, 0, 0, 0}}
    }),

    %% Insert the matching route for the test packet
    ok = hpr_routing_config_worker:insert(test_route()),

    {ok, Connection} = grpc_client:connect(tcp, "127.0.0.1", 8080),
    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.packet_router.gateway',
        send_packet,
        client_packet_router_pb
    ),
    ok = grpc_client:send(Stream, PacketMap),

    %% ===================================================================
    %% The test server is not started in this test. I'm not sure this test is
    %% accurate yet. But it is here for when we understand more about why
    %% grpcbox recalls its service handler when something fails.

    meck:new(hpr_gateway_service, [passthrough]),
    ok = grpc_client:send(Stream, PacketMap),
    ok =
        receive
            {test_send_packet, _} -> ct:fail(expected_no_packet)
        after 250 -> ok
        end,

    ?assertEqual(1, meck:num_calls(hpr_gateway_service, send_packet, '_')),

    ok = gen_server:stop(ServerPid),

    ok.

relay_test(_Config) ->
    GatewayStream = fake_gateway_stream(self()),
    RouterStream = fake_router_stream(),
    FakeData = <<"fake data">>,

    meck:expect(
        grpc_client,
        rcv,
        [RouterStream],
        {meck_seq, [{data, FakeData}, eof]}
    ),

    {ok, RelayPid} = hpr_router_relay:start(GatewayStream, RouterStream),

    Data = receive_next(),
    ?assertEqual({router_reply, FakeData}, Data),
    timer:sleep(50),
    ?assertNot(erlang:is_process_alive(RelayPid)),
    ?assertNot(erlang:is_process_alive(GatewayStream)),
    ?assertNot(erlang:is_process_alive(RouterStream)).

%% ===================================================================
%% Helpers
%% ===================================================================

test_packet() ->
    {packet_router_packet_up_v1_pb,
        <<0, 55, 148, 187, 74, 220, 108, 33, 11, 133, 65, 148, 104, 147, 177, 26, 124, 43, 169, 155,
            182, 228, 95>>,
        552140, 0, 904.7000122070312, 'SF10BW125', 5.5, 'US915', 0,
        <<1, 131, 45, 83, 233, 204, 91, 71, 221, 213, 157, 129, 213, 219, 31, 62, 233, 186, 49, 28,
            183, 141, 0, 52, 52, 175, 168, 41, 37, 8, 230, 89, 83>>,
        <<192, 249, 98, 190, 86, 74, 255, 124, 33, 190, 95, 141, 9, 173, 111, 180, 97, 42, 203, 136,
            11, 36, 144, 4, 128, 6, 190, 253, 153, 99, 3, 180, 161, 76, 88, 90, 106, 200, 160, 115,
            22, 81, 211, 37, 134, 14, 8, 99, 226, 1, 172, 157, 67, 170, 203, 246, 21, 250, 191, 236,
            93, 230, 221, 9>>}.

test_route() ->
    {packet_router_route_v1_pb, 12582995,
        [{packet_router_route_devaddr_range_v1_pb, 0, 4294967295}],
        [{packet_router_route_eui_v1_pb, 802041902051071031, 8942655256770396549}],
        <<"127.0.0.1:8082">>, router, 4020}.

fake_router_stream() ->
    spawn(fun() -> wait_for_stop() end).

fake_gateway_stream(Receiver) ->
    spawn(
        fun() ->
            Receiver ! receive_next(),
            wait_for_stop()
        end
    ).

receive_next() ->
    receive
        Msg ->
            Msg
    after 50 ->
        no_data
    end.

wait_for_stop() ->
    receive
        stop ->
            ok
    end.
