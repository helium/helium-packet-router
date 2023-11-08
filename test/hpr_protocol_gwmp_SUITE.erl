-module(hpr_protocol_gwmp_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    full_test/1,
    single_lns_test/1,
    multi_lns_test/1,
    single_lns_downlink_test/1,
    single_lns_class_c_downlink_test/1,
    multi_lns_downlink_test/1,
    multi_gw_single_lns_test/1,
    pull_data_test/1,
    pull_ack_test/1,
    pull_ack_hostname_test/1,
    region_port_redirect_test/1,
    gateway_disconnect_test/1
]).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/packet_router_pb.hrl").

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
        full_test,
        single_lns_test,
        multi_lns_test,
        single_lns_downlink_test,
        single_lns_class_c_downlink_test,
        multi_lns_downlink_test,
        multi_gw_single_lns_test,
        pull_data_test,
        pull_ack_test,
        pull_ack_hostname_test,
        region_port_redirect_test,
        gateway_disconnect_test
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

full_test(_Config) ->
    {ok, RcvSocket} = gen_udp:open(1777, [binary, {active, true}]),

    {Route, EUIPairs, DevAddrRanges} = test_route(1777),
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

    %% Initial PULL_DATA
    {ok, _Token, _MAC} = expect_pull_data(RcvSocket, route_pull_data),
    %% PUSH_DATA
    {ok, Data} = expect_push_data(RcvSocket, router_push_data),
    ok = verify_push_data(PacketUp, Data),

    ok = gen_udp:close(RcvSocket),
    ok = gen_server:stop(GatewayPid),

    ok.

single_lns_test(_Config) ->
    PacketUp = fake_join_up_packet(),

    {Route, _, _} = test_route(1777),

    {ok, RcvSocket} = gen_udp:open(1777, [binary, {active, true}]),

    hpr_protocol_gwmp:send(PacketUp, Route),
    %% Initial PULL_DATA
    {ok, _Token, _MAC} = expect_pull_data(RcvSocket, route_pull_data),
    %% PUSH_DATA
    {ok, Data} = expect_push_data(RcvSocket, router_push_data),
    ok = verify_push_data(PacketUp, Data),

    ok = gen_udp:close(RcvSocket),

    ok.

multi_lns_test(_Config) ->
    PacketUp = fake_join_up_packet(),

    {Route1, _, _} = test_route(1777),
    {Route2, _, _} = test_route(1778),

    {ok, RcvSocket1} = gen_udp:open(1777, [binary, {active, true}]),
    {ok, RcvSocket2} = gen_udp:open(1778, [binary, {active, true}]),

    %% Send packet to route 1
    hpr_protocol_gwmp:send(PacketUp, Route1),
    {ok, _Token, _MAC} = expect_pull_data(RcvSocket1, route1_pull_data),
    {ok, _} = expect_push_data(RcvSocket1, route1_push_data),

    %% Same packet to route 2
    hpr_protocol_gwmp:send(PacketUp, Route2),
    {ok, _Token2, _MAC2} = expect_pull_data(RcvSocket2, route2_pull_data),
    {ok, _} = expect_push_data(RcvSocket2, route2_push_data),

    %% Another packet to route 1
    hpr_protocol_gwmp:send(PacketUp, Route1),
    {ok, _} = expect_push_data(RcvSocket1, route1_push_data_repeat),
    ok = no_more_messages(),

    ok = gen_udp:close(RcvSocket1),
    ok = gen_udp:close(RcvSocket2),

    ok.

single_lns_downlink_test(_Config) ->
    PacketUp = fake_join_up_packet(),

    %% Sending a packet up, to get a packet down.
    {Route1, _, _} = test_route(1777),
    {ok, LnsSocket} = gen_udp:open(1777, [binary, {active, true}]),

    %% Send packet
    _ = hpr_protocol_gwmp:send(PacketUp, Route1),

    %% Eat the pull_data
    {ok, _Token, _MAC} = expect_pull_data(LnsSocket, downlink_test_initiate_connection),
    %% Receive the uplink (mostly to get the return address)
    {ok, ReturnSocketDest} =
        receive
            {udp, LnsSocket, Address, Port, Data1} ->
                ?assertEqual(push_data, semtech_id_atom(Data1)),
                {ok, {Address, Port}}
        after timer:seconds(2) -> ct:fail(no_push_data)
        end,

    %% Send a downlink to the worker
    #{
        token := DownToken,
        pull_resp := DownPullResp,
        %% save these fake values to compare with what is received
        data := #{
            data := Data,
            freq := Freq,
            datr := Datr
        }
    } = fake_down_packet(),
    ok = gen_udp:send(LnsSocket, ReturnSocketDest, DownPullResp),

    %% receive the PacketRouterPacketDownV1 sent to grcp_stream
    receive
        {packet_down, #packet_router_packet_down_v1_pb{
            payload = Payload,
            rx1 = #window_v1_pb{
                timestamp = Timestamp,
                frequency = Frequency,
                datarate = Datarate,
                immediate = Immediate
            }
        }} ->
            ?assertNot(Immediate, "immediate defaults to false for non class-c"),
            ?assert(erlang:is_integer(Timestamp)),
            ?assertEqual(Data, base64:encode(Payload)),
            ?assertEqual(erlang:round(Freq * 1_000_000), Frequency),
            ?assertEqual(erlang:binary_to_existing_atom(Datr), Datarate),
            ok;
        {packet_down, Other} ->
            ct:fail({rcvd_bad_packet_down, Other})
    after timer:seconds(2) -> ct:fail(no_packet_down)
    end,

    %% expect the ack for our downlink
    receive
        {udp, LnsSocket, _Address, _Port, Data2} ->
            ?assertEqual(tx_ack, semtech_id_atom(Data2)),
            ?assertEqual(DownToken, semtech_udp:token(Data2))
    after timer:seconds(2) -> ct:fail(no_tx_ack_for_downlink)
    end,

    ok.

single_lns_class_c_downlink_test(_Config) ->
    PacketUp = fake_join_up_packet(),

    %% Sending a packet up, to get a packet down.
    {Route1, _, _} = test_route(1777),
    {ok, LnsSocket} = gen_udp:open(1777, [binary, {active, true}]),

    %% Send packet
    _ = hpr_protocol_gwmp:send(PacketUp, Route1),

    %% Eat the pull_data
    {ok, _Token, _MAC} = expect_pull_data(LnsSocket, downlink_test_initiate_connection),
    %% Receive the uplink (mostly to get the return address)
    {ok, ReturnSocketDest} =
        receive
            {udp, LnsSocket, Address, Port, Data1} ->
                ?assertEqual(push_data, semtech_id_atom(Data1)),
                {ok, {Address, Port}}
        after timer:seconds(2) -> ct:fail(no_push_data)
        end,

    %% Send a downlink to the worker
    #{
        token := DownToken,
        pull_resp := DownPullResp,
        %% save these fake values to compare with what is received
        data := #{
            data := Data,
            freq := Freq,
            datr := Datr
        }
    } = fake_class_c_down_packet(),
    ok = gen_udp:send(LnsSocket, ReturnSocketDest, DownPullResp),

    %% receive the PacketRouterPacketDownV1 sent to grcp_stream
    receive
        {packet_down, #packet_router_packet_down_v1_pb{
            payload = Payload,
            rx1 = #window_v1_pb{
                timestamp = Timestamp,
                frequency = Frequency,
                datarate = Datarate,
                immediate = Immediate
            }
        }} ->
            ?assert(Immediate),
            ?assertEqual(0, Timestamp, "0ms means immediate"),
            ?assertEqual(Data, base64:encode(Payload)),
            ?assertEqual(erlang:round(Freq * 1_000_000), Frequency),
            ?assertEqual(erlang:binary_to_existing_atom(Datr), Datarate),
            ok;
        {packet_down, Other} ->
            ct:fail({rcvd_bad_packet_down, Other})
    after timer:seconds(2) -> ct:fail(no_packet_down)
    end,

    %% expect the ack for our downlink
    receive
        {udp, LnsSocket, _Address, _Port, Data2} ->
            ?assertEqual(tx_ack, semtech_id_atom(Data2)),
            ?assertEqual(DownToken, semtech_udp:token(Data2))
    after timer:seconds(2) -> ct:fail(no_tx_ack_for_downlink)
    end,

    ok.

multi_lns_downlink_test(_Config) ->
    %% When communicating with multiple LNS, the udp worker needs to be able to
    %% ack pull_resp to the proper LNS.
    PacketUp = fake_join_up_packet(),

    %% Sending a packet up, to get a packet down.
    {Route1, _, _} = test_route(1777),
    {Route2, _, _} = test_route(1778),

    {ok, LNSSocket1} = gen_udp:open(1777, [binary, {active, true}]),
    {ok, LNSSocket2} = gen_udp:open(1778, [binary, {active, true}]),

    %% Send packet to LNS 1
    _ = hpr_protocol_gwmp:send(PacketUp, Route1),
    {ok, _Token, _Data} = expect_pull_data(LNSSocket1, downlink_test_initiate_connection_lns1),
    %% Receive the uplink from LNS 1 (mostly to get the return address)
    {ok, UDPWorkerAddress} =
        receive
            {udp, LNSSocket1, Address, Port, Data1} ->
                ?assertEqual(push_data, semtech_id_atom(Data1)),
                {ok, {Address, Port}}
        after timer:seconds(2) -> ct:fail(no_push_data)
        end,

    %% Send packet to LNS 2
    _ = hpr_protocol_gwmp:send(PacketUp, Route2),
    {ok, _Token2, _Data2} = expect_pull_data(LNSSocket2, downlink_test_initiate_connection_lns2),
    {ok, _} = expect_push_data(LNSSocket2, route2_push_data),

    %% LNS 2 is now the most recent communicator with the UDP worker.
    %% Regardless, sending a PULL_RESP, the UDP worker should ack the sender,
    %% not the most recent.

    %% Send a downlink to the worker from LNS 1
    %% we don't care about the contents
    #{token := DownToken, pull_resp := DownPullResp} = fake_down_packet(),
    ok = gen_udp:send(LNSSocket1, UDPWorkerAddress, DownPullResp),

    %% expect the ack for our downlink
    receive
        {udp, LNSSocket1, _Address, _Port, Data2} ->
            ?assertEqual(tx_ack, semtech_id_atom(Data2)),
            ?assertEqual(DownToken, semtech_udp:token(Data2));
        {udp, LNSSocket2, _Address, _Port, Data2} ->
            ?assertEqual(tx_ack, semtech_id_atom(Data2)),
            ct:fail({tx_ack_for_wrong_socket, [{expected, 1}, {got, 2}]})
    after timer:seconds(2) -> ct:fail(no_tx_ack_for_downlink)
    end,

    ok.

multi_gw_single_lns_test(_Config) ->
    %% Ensure gws start up uniquely
    PacketUp1 = fake_join_up_packet(),
    #{public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    ok = hpr_packet_router_service:register(PubKeyBin),
    PacketUp2 = PacketUp1#packet_router_packet_up_v1_pb{gateway = PubKeyBin},

    {Route, _, _} = test_route(1777),

    {ok, RcvSocket} = gen_udp:open(1777, [binary, {active, true}]),

    %% Send the packet from the first hotspot
    hpr_protocol_gwmp:send(PacketUp1, Route),
    {ok, _Token, _Data} = expect_pull_data(RcvSocket, first_gw_pull_data),
    {ok, _} = expect_push_data(RcvSocket, first_gw_push_data),

    %% Send the same packet from the second hotspot
    hpr_protocol_gwmp:send(PacketUp2, Route),
    {ok, _Token2, _Data2} = expect_pull_data(RcvSocket, second_gw_pull_data),
    {ok, _} = expect_push_data(RcvSocket, second_gw_push_data),

    ok = gen_udp:close(RcvSocket),

    ok.

pull_data_test(_Config) ->
    %% send push_data to start sending of pull_data
    PacketUp = fake_join_up_packet(),
    PubKeyBin = hpr_packet_up:gateway(PacketUp),

    {Route, _, _} = test_route(1777),

    {ok, RcvSocket} = gen_udp:open(1777, [binary, {active, true}]),

    hpr_protocol_gwmp:send(PacketUp, Route),

    %% Initial PULL_DATA
    {ok, Token, MAC} = expect_pull_data(RcvSocket, route_pull_data),
    ?assert(erlang:is_binary(Token)),
    ?assertEqual(MAC, hpr_utils:pubkeybin_to_mac(PubKeyBin)),

    ok.

pull_ack_test(_Config) ->
    PacketUp = fake_join_up_packet(),
    PubKeyBin = hpr_packet_up:gateway(PacketUp),

    {Route, _, _} = test_route(1777),

    {ok, RcvSocket} = gen_udp:open(1777, [binary, {active, true}]),

    hpr_protocol_gwmp:send(PacketUp, Route),

    %% Initial PULL_DATA, grab the address and port for responding
    {ok, Token, Address, Port} =
        receive
            {udp, RcvSocket, A, P, Data} ->
                ?assertEqual(pull_data, semtech_id_atom(Data)),
                T = semtech_udp:token(Data),
                {ok, T, A, P}
        after timer:seconds(2) -> ct:fail({no_pull_data})
        end,
    ?assert(erlang:is_binary(Token)),

    %% There is an outstanding pull_data
    {ok, WorkerPid} = hpr_gwmp_sup:lookup_worker(PubKeyBin),
    ?assertEqual(
        1,
        maps:size(element(5, sys:get_state(WorkerPid))),
        "1 outstanding pull_data"
    ),

    %% send pull ack from server
    PullAck = semtech_udp:pull_ack(Token),
    ok = gen_udp:send(RcvSocket, Address, Port, PullAck),

    %% pull_data has been acked
    ok = test_utils:wait_until(fun() ->
        [acknowledged] == maps:values(element(5, sys:get_state(WorkerPid)))
    end),

    %% ===================================================================
    %% Send another packet, there should not be another pull_data.
    %% There's already a session started, and we'll send the pull_data on a cadence.

    %% Sending the same packet again shouldn't matter here, we only want to
    %% trigger the push_data/pull_data logic.
    hpr_protocol_gwmp:send(PacketUp, Route),

    ?assertEqual(
        #{{{127, 0, 0, 1}, 1777} => acknowledged},
        element(5, sys:get_state(WorkerPid)),
        "0 outstanding pull_data"
    ),

    ok.

pull_ack_hostname_test(_Config) ->
    %% Mostly a copy of `pull_ack_test', but with some assertions around the
    %% inet module to make sure we're attempting to resolve hostnames.
    PacketUp = fake_join_up_packet(),
    PubKeyBin = hpr_packet_up:gateway(PacketUp),

    TestURL = "test_url.for.resolving",

    meck:new(inet, [unstick, passthrough]),
    %% Resovle to localhost so we can communicate
    meck:expect(
        inet,
        gethostbyname,
        1,
        {ok, {hostent, TestURL, [], inet, 4, [{127, 0, 0, 1}]}}
    ),

    {Route, _, _} = test_route(TestURL, 1777),

    {ok, RcvSocket} = gen_udp:open(1777, [binary, {active, true}]),
    hpr_protocol_gwmp:send(PacketUp, Route),

    %% Initial PULL_DATA, grab the address and port for responding
    {ok, Token, Address, Port} =
        receive
            {udp, RcvSocket, A, P, Data} ->
                ?assertEqual(pull_data, semtech_id_atom(Data)),
                T = semtech_udp:token(Data),
                {ok, T, A, P}
        after timer:seconds(2) -> ct:fail({no_pull_data})
        end,
    ?assert(erlang:is_binary(Token)),

    %% There is an outstanding pull_data
    {ok, WorkerPid} = hpr_gwmp_sup:lookup_worker(PubKeyBin),
    ?assertEqual(
        1,
        maps:size(element(5, sys:get_state(WorkerPid))),
        "1 outstanding pull_data"
    ),

    %% send pull ack from server
    PullAck = semtech_udp:pull_ack(Token),
    ok = gen_udp:send(RcvSocket, Address, Port, PullAck),

    %% pull_data has been acked
    ok = test_utils:wait_until(fun() ->
        [acknowledged] == maps:values(element(5, sys:get_state(WorkerPid)))
    end),

    %% ensure url was resolved
    ?assertEqual(TestURL, meck:capture(first, inet, gethostbyname, '_', 1)),

    meck:unload(),

    ok.

region_port_redirect_test(_Config) ->
    FallbackPort = 2777,
    USPort = 1778,
    EUPort = 1779,

    {Route, _, _} = test_route(
        "127.0.0.1",
        FallbackPort,
        [
            #{region => 'US915', port => USPort},
            #{region => 'EU868', port => EUPort}
        ]
    ),

    {ok, FallbackSocket} = gen_udp:open(FallbackPort, [binary, {active, true}]),
    {ok, USSocket} = gen_udp:open(USPort, [binary, {active, true}]),
    {ok, EUSocket} = gen_udp:open(EUPort, [binary, {active, true}]),

    #{public := EUPubKey} = libp2p_crypto:generate_keys(ed25519),
    EUPubKeyBin = libp2p_crypto:pubkey_to_bin(EUPubKey),
    ok = hpr_packet_router_service:register(EUPubKeyBin),

    %% This gateway will have no mapping, and should result in sending to the
    %% fallback port.
    #{public := CNPubKey} = libp2p_crypto:generate_keys(ed25519),
    CNPubKeyBin = libp2p_crypto:pubkey_to_bin(CNPubKey),
    ok = hpr_packet_router_service:register(CNPubKeyBin),

    %% NOTE: Hotspot needs to be changed because 1 hotspot can't send from 2 regions.
    USPacketUp = fake_join_up_packet(),
    EUPacketUp = USPacketUp#packet_router_packet_up_v1_pb{gateway = EUPubKeyBin, region = 'EU868'},
    CNPacketUp = USPacketUp#packet_router_packet_up_v1_pb{gateway = CNPubKeyBin, region = 'CN470'},

    %% US send packet
    hpr_protocol_gwmp:send(USPacketUp, Route),
    {ok, _, _} = expect_pull_data(USSocket, us_redirected_pull_data),
    {ok, _} = expect_push_data(USSocket, us_redirected_push_data),

    %% EU send packet
    hpr_protocol_gwmp:send(EUPacketUp, Route),
    {ok, _, _} = expect_pull_data(EUSocket, eu_redirected_pull_data),
    {ok, _} = expect_push_data(EUSocket, eu_redirected_push_data),

    %% No messages received on the fallback port
    receive
        {udp, FallbackSocket, _Address, _Port, _Data} ->
            ct:fail(expected_no_messages_on_fallback_port)
    after 250 -> ok
    end,

    %% Send from the last region to make sure fallback port is chosen
    hpr_protocol_gwmp:send(CNPacketUp, Route),
    {ok, _, _} = expect_pull_data(FallbackSocket, fallback_pull_data),
    {ok, _} = expect_push_data(FallbackSocket, fallback_push_data),

    %% cleanup
    ok = gen_udp:close(FallbackSocket),
    ok = gen_udp:close(USSocket),
    ok = gen_udp:close(EUSocket),

    ok.

gateway_disconnect_test(_Config) ->
    {ok, RcvSocket} = gen_udp:open(1777, [binary, {active, true}]),

    {Route, EUIPairs, DevAddrRanges} = test_route(1777),
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

    %% Initial PULL_DATA
    {ok, _Token, _MAC} = expect_pull_data(RcvSocket, route_pull_data),
    %% PUSH_DATA
    {ok, Data} = expect_push_data(RcvSocket, router_push_data),
    ok = verify_push_data(PacketUp, Data),

    ?assertEqual(1, proplists:get_value(active, supervisor:count_children(hpr_gwmp_sup))),

    ok = gen_server:stop(GatewayPid),
    ok = test_utils:wait_until(
        fun() ->
            0 == proplists:get_value(active, supervisor:count_children(hpr_gwmp_sup))
        end
    ),

    ok = gen_udp:close(RcvSocket),

    ok.

%% ===================================================================
%% Helpers
%% ===================================================================

test_route(Port) ->
    test_route("127.0.0.1", Port).

test_route(Host, Port) ->
    test_route(Host, Port, []).

test_route(Host, Port, RegionMapping) ->
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 0,
        oui => 42,
        server => #{
            host => Host,
            port => Port,
            protocol => {gwmp, #{mapping => RegionMapping}}
        },
        max_copies => 1
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

expect_pull_data(Socket, Reason) ->
    receive
        {udp, Socket, _Address, _Port, Data} ->
            ?assertEqual(pull_data, semtech_id_atom(Data), Reason),
            Token = semtech_udp:token(Data),
            MAC = semtech_udp:mac(Data),
            {ok, Token, MAC}
    after timer:seconds(2) -> ct:fail({no_pull_data, Reason})
    end.

expect_push_data(Socket, Reason) ->
    receive
        {udp, Socket, _Address, _Port, Data} ->
            ?assertEqual(push_data, semtech_id_atom(Data), Reason),
            {ok, Data}
    after timer:seconds(2) -> ct:fail({no_push_data, Reason})
    end.

semtech_id_atom(Data) ->
    semtech_udp:identifier_to_atom(semtech_udp:identifier(Data)).

no_more_messages() ->
    receive
        Msg ->
            ct:fail({unexpected_msg, Msg})
    after timer:seconds(1) -> ok
    end.

%% Pulled from a virtual-device session
fake_join_up_packet() ->
    PubKeyBin =
        <<1, 154, 70, 24, 151, 192, 204, 57, 167, 252, 250, 139, 253, 71, 222, 143, 87, 111, 170,
            125, 26, 173, 134, 204, 181, 85, 5, 55, 163, 222, 154, 89, 114>>,
    ok = hpr_packet_router_service:register(PubKeyBin),
    #packet_router_packet_up_v1_pb{
        payload =
            <<0, 139, 222, 157, 101, 233, 17, 95, 30, 219, 224, 30, 233, 253, 104, 189, 10, 37, 23,
                110, 239, 137, 95>>,
        timestamp = 620124,
        rssi = -120,
        frequency = 903_900_024,
        datarate = 'SF10BW125',
        snr = 5.5,
        region = 'US915',
        hold_time = 0,
        gateway = PubKeyBin,
        signature =
            <<29, 184, 117, 202, 112, 159, 1, 47, 91, 121, 185, 105, 107, 72, 122, 119, 202, 112,
                128, 43, 48, 31, 128, 255, 102, 166, 200, 105, 130, 39, 131, 148, 46, 112, 145, 235,
                61, 200, 166, 101, 111, 8, 25, 81, 34, 7, 218, 70, 180, 134, 3, 206, 244, 175, 46,
                185, 130, 191, 104, 131, 164, 40, 68, 11>>
    }.

%% Pulled from semtech_udp eunit.
%% data needed to encoded to be valid to use.
fake_down_packet() ->
    DownMap = fake_down_map(),
    DownToken = semtech_udp:token(),
    #{
        token => DownToken,
        pull_resp => semtech_udp:pull_resp(DownToken, DownMap),
        data => DownMap
    }.

fake_class_c_down_packet() ->
    DownMap0 = fake_down_map(),
    DownMap = DownMap0#{imme => true},
    DownToken = semtech_udp:token(),
    #{
        token => DownToken,
        pull_resp => semtech_udp:pull_resp(DownToken, DownMap),
        data => DownMap
    }.

fake_down_map() ->
    DownMap = #{
        imme => false,
        freq => 904.1,
        rfch => 0,
        powe => 27,
        modu => <<"LORA">>,
        datr => <<"SF11BW125">>,
        codr => <<"4/6">>,
        ipol => false,
        size => 32,
        tmst => erlang:system_time(millisecond) band 16#FFFF_FFFF,
        data => base64:encode(<<"H3P3N2i9qc4yt7rK7ldqoeCVJGBybzPY5h1Dd7P7p8v">>)
    },
    DownMap.

verify_push_data(PacketUp, PushDataBinary) ->
    JsonData = semtech_udp:json_data(PushDataBinary),

    PubKeyBin = hpr_packet_up:gateway(PacketUp),
    MapFromPacketUp = #{
        <<"rxpk">> =>
            [
                #{
                    <<"chan">> => 0,
                    <<"codr">> => <<"4/5">>,
                    <<"data">> => base64:encode(hpr_packet_up:payload(PacketUp)),
                    <<"datr">> => erlang:atom_to_binary(hpr_packet_up:datarate(PacketUp)),
                    <<"freq">> => list_to_float(
                        float_to_list(hpr_packet_up:frequency_mhz(PacketUp), [
                            {decimals, 4}, compact
                        ])
                    ),
                    <<"lsnr">> => hpr_packet_up:snr(PacketUp),
                    <<"modu">> => <<"LORA">>,
                    <<"rfch">> => 0,
                    <<"rssi">> => hpr_packet_up:rssi(PacketUp),
                    <<"size">> => erlang:byte_size(hpr_packet_up:payload(PacketUp)),
                    <<"stat">> => 1,
                    <<"time">> => fun erlang:is_binary/1,
                    <<"tmst">> => hpr_packet_up:timestamp(PacketUp) band 16#FFFF_FFFF,
                    <<"meta">> => #{
                        <<"gateway_id">> => erlang:list_to_binary(
                            libp2p_crypto:bin_to_b58(PubKeyBin)
                        ),
                        <<"gateway_name">> => erlang:list_to_binary(
                            hpr_utils:gateway_name(PubKeyBin)
                        ),
                        <<"regi">> => erlang:atom_to_binary(
                            hpr_packet_up:region(PacketUp))
                    }
                }
            ]
    },
    ?assert(test_utils:match_map(MapFromPacketUp, JsonData)).
