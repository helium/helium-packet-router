-module(hpr_protocol_router_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    basic_test/1,
    connection_refused_test/1,
    downlink_test/1,
    server_crash_test/1,
    gateway_disconnect_test/1
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
        basic_test,
        connection_refused_test,
        downlink_test,
        server_crash_test,
        gateway_disconnect_test
    ].

-define(SERVER_PORT, 8080).
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

basic_test(_Config) ->
    %% Startup Router server
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_test_packet_router_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),

    %% Interceptor
    Self = self(),
    application:set_env(
        hpr,
        packet_service_route_fun,
        fun(Env, StreamState) ->
            {packet, Packet} = hpr_envelope_up:data(Env),
            Self ! {packet_up, Packet},
            StreamState
        end
    ),

    {Route, EUIPairs, DevAddrRanges} = test_route(),
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

    ok = gen_server:stop(GatewayPid),
    ok = gen_server:stop(ServerPid),

    ok.

connection_refused_test(_Config) ->
    PacketUp = test_utils:uplink_packet_up(#{}),
    {Route, _EUIPairs, _DevAddrRanges} = test_route(),

    ?assertEqual(
        {error, {shutdown, econnrefused}},
        hpr_protocol_router:send(PacketUp, Route)
    ),

    ok.

downlink_test(_Config) ->
    %% Startup Router server
    {ok, RouterServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_test_packet_router_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),

    {Route, EUIPairs, DevAddrRanges} = test_route(),
    {ok, GatewayPid} = hpr_test_gateway:start(#{
        forward => self(), route => Route, eui_pairs => EUIPairs, devaddr_ranges => DevAddrRanges
    }),

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
        packet_service_route_fun,
        fun(_Env, StreamState) ->
            {ok, EnvDown, StreamState}
        end
    ),

    %% Send packet and route directly through interface
    ok = hpr_test_gateway:send_packet(GatewayPid, #{}),

    case hpr_test_gateway:receive_env_down(GatewayPid) of
        {ok, GotEnvDown} ->
            ?assertEqual(EnvDown, GotEnvDown);
        {error, timeout} ->
            ct:fail(receive_env_down)
    end,
    ok = gen_server:stop(RouterServerPid),
    ok = gen_server:stop(GatewayPid),

    ok.

server_crash_test(_Config) ->
    %% Startup Router server
    ListenOpts = #{port => 8082, ip => {0, 0, 0, 0}},
    {ok, _RouterServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_test_packet_router_service}
        },
        listen_opts => ListenOpts
    }),

    %% Interceptor
    Self = self(),
    application:set_env(
        hpr,
        packet_service_route_fun,
        fun(Env, StreamState) ->
            {packet, Packet} = hpr_envelope_up:data(Env),
            Self ! {packet_up, Packet},
            StreamState
        end
    ),

    {Route, EUIPairs, DevAddrRanges} = test_route(),
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

    receive
        {packet_up, RvcPacketUp} -> ?assertEqual(RvcPacketUp, PacketUp)
    after timer:seconds(2) -> ct:fail(no_msg_rcvd)
    end,

    %% ===================================================================
    %% We're stopping the test server to make sure we don't try to deliver
    %% multiple times for a connection we cannot make or has gone down.
    %% Also, resetting the mock to make sure route is called once.
    ok = grpcbox_services_simple_sup:terminate_child(ListenOpts),

    %% Send another packet
    ok = hpr_test_gateway:send_packet(GatewayPid, #{fcnt => 2}),

    receive
        {packet_up, Something} -> ct:fail(Something)
    after timer:seconds(2) -> ok
    end,

    %% Make sure the stream is gone, and we can't get another.
    ok = test_utils:wait_until(
        fun() ->
            {error, {shutdown, econnrefused}} ==
                hpr_protocol_router:get_stream(
                    hpr_test_gateway:pubkey_bin(GatewayPid),
                    hpr_route:lns(Route),
                    hpr_route:server(Route)
                )
        end
    ),
    ?assertEqual(0, erlang:length(hpr_protocol_router:all_streams())),
    ok.

gateway_disconnect_test(_Config) ->
    %% Startup Router server
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_test_packet_router_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),

    %% Interceptor
    Self = self(),
    application:set_env(
        hpr,
        packet_service_route_fun,
        fun(Env, StreamState) ->
            {packet, Packet} = hpr_envelope_up:data(Env),
            Self ! {packet_up, Packet},
            StreamState
        end
    ),

    {Route, EUIPairs, DevAddrRanges} = test_route(),
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

    Gateway = hpr_test_gateway:pubkey_bin(GatewayPid),
    LNS = hpr_route:lns(Route),
    [{_, #{channel := ChannelPid, stream_pid := StreamPid}}] = ets:lookup(
        hpr_protocol_router_ets, {Gateway, LNS}
    ),

    ok = gen_server:stop(GatewayPid),
    ok =
        receive
            {hpr_test_gateway, GatewayPid,
                {terminate, #{channel := GatewayChannelPid, stream_pid := GatewayStreamPid}}} ->
                ok = test_utils:wait_until(
                    fun() ->
                        true == erlang:is_process_alive(GatewayChannelPid) andalso
                            false == erlang:is_process_alive(GatewayStreamPid) andalso
                            false == erlang:is_process_alive(GatewayPid)
                    end
                )
        after timer:seconds(3) -> ct:fail(no_terminate_rcvd)
        end,

    ?assertEqual([], ets:lookup(hpr_protocol_router_ets, {Gateway, LNS})),
    ?assertNot(erlang:is_process_alive(ChannelPid)),
    ?assertNot(erlang:is_process_alive(StreamPid)),

    ok = gen_server:stop(ServerPid),
    ok.

%% ===================================================================
%% Helpers
%% ===================================================================

test_route() ->
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
    {Route, EUIPairs, DevAddrRanges}.
