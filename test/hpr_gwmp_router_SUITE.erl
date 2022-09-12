-module(hpr_gwmp_router_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    single_lns_test/1,
    multi_lns_test/1,
    single_lns_downlink_test/1,
    multi_lns_downlink_test/1,
    multi_gw_single_lns_test/1,
    shutdown_idle_worker_test/1,
    pull_data_test/1,
    gateway_dest_redirect/1,
    bad_route_test/1
]).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/server/packet_router_pb.hrl").

-define(REDIRECT_WORKER_PORT, 2777).
-define(REDIRECT_WORKER_ENDPOINT, <<"127.0.0.1:2777">>).

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
        single_lns_test,
        multi_lns_test,
        single_lns_downlink_test,
        multi_lns_downlink_test,
        multi_gw_single_lns_test,
        shutdown_idle_worker_test,
        pull_data_test,
        gateway_dest_redirect,
        bad_route_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(gateway_dest_redirect = TestCase, Config) ->
    application:set_env(hpr, redirect_by_region, #{
        port => ?REDIRECT_WORKER_PORT,
        remap => #{
            <<"US915">> => <<"127.0.0.1:1778">>,
            <<"EU868">> => <<"127.0.0.1:1779">>
        }
    }),
    test_utils:init_per_testcase(TestCase, Config);
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

single_lns_test(_Config) ->
    PacketUp = fake_join_up_packet(),

    Route = test_route_1777(),

    {ok, RcvSocket} = gen_udp:open(1777, [binary, {active, true}]),

    hpr_gwmp_router:send(PacketUp, unused_test_stream_handler, Route),
    %% Initial PULL_DATA
    {ok, _Token, _MAC} = expect_pull_data(RcvSocket, route_pull_data),
    %% PUSH_DATA
    {ok, Data} = expect_push_data(RcvSocket, router_push_data),
    ok = verify_push_data(PacketUp, Data),

    ok = gen_udp:close(RcvSocket),

    ok.

test_route_1777() ->
    hpr_route:new(
        1337,
        [],
        [],
        <<"127.0.0.1:1777">>,
        gwmp,
        42
    ).

multi_lns_test(_Config) ->
    PacketUp = fake_join_up_packet(),

    Route1 = hpr_route:new(1337, [], [], <<"127.0.0.1:1777">>, gwmp, 42),
    Route2 = hpr_route:new(1337, [], [], <<"127.0.0.1:1778">>, gwmp, 42),

    {ok, RcvSocket1} = gen_udp:open(1777, [binary, {active, true}]),
    {ok, RcvSocket2} = gen_udp:open(1778, [binary, {active, true}]),

    %% Send packet to route 1
    hpr_gwmp_router:send(PacketUp, unused_test_stream_handler, Route1),
    {ok, _Token, _MAC} = expect_pull_data(RcvSocket1, route1_pull_data),
    {ok, _} = expect_push_data(RcvSocket1, route1_push_data),

    %% Same packet to route 2
    hpr_gwmp_router:send(PacketUp, unused_test_stream_handler, Route2),
    {ok, _Token2, _MAC2} = expect_pull_data(RcvSocket2, route2_pull_data),
    {ok, _} = expect_push_data(RcvSocket2, route2_push_data),

    %% Another packet to route 1
    hpr_gwmp_router:send(PacketUp, unused_test_stream_handler, Route1),
    {ok, _} = expect_push_data(RcvSocket1, route1_push_data_repeat),
    ok = no_more_messages(),

    ok = gen_udp:close(RcvSocket1),
    ok = gen_udp:close(RcvSocket2),

    ok.

single_lns_downlink_test(_Config) ->
    PacketUp = fake_join_up_packet(),

    %% Sending a packet up, to get a packet down.
    Route1 = hpr_route:new(1337, [], [], <<"127.0.0.1:1777">>, gwmp, 42),
    {ok, LnsSocket} = gen_udp:open(1777, [binary, {active, true}]),

    %% Send packet
    _ = hpr_gwmp_router:send(PacketUp, unused_test_stream_handler, Route1),

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

    %% Mock out the return path for the downlink (grpc)
    Self = self(),
    meck:new(grpcbox_stream, [passthrough, no_history]),
    meck:expect(grpcbox_stream, send, fun(Eos, PacketDown, _StreamHandler) ->
        ?assertEqual(false, Eos, "we don't want to be ending the stream"),
        Self ! {packet_down, PacketDown}
    end),

    %% Send a downlink to the worker
    {DownToken, DownPullResp} = fake_down_packet(),

    %%    save these fake values to compare with what is received
    #{
        data := Data,
        freq := Freq,
        datr := Datr
    } = fake_down_map(),
    ok = gen_udp:send(LnsSocket, ReturnSocketDest, DownPullResp),

    %% receive the PacketRouterPacketDownV1 as the grpc stream.
    receive
        {packet_down, #packet_router_packet_down_v1_pb{
            payload = Payload,
            rx1 = #window_v1_pb{
                timestamp = Timestamp,
                frequency = Frequency,
                datarate = Datarate
            }
        }} ->
            ?assert(erlang:is_integer(Timestamp)),
            ?assertEqual(Data, base64:encode(Payload)),
            ?assertEqual(Freq, Frequency),
            ?assertEqual(Datr, Datarate),
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

    meck:unload(grpcbox_stream),

    ok.

multi_lns_downlink_test(_Config) ->
    %% When communicating with multiple LNS, the udp worker needs to be able to
    %% ack pull_resp to the proper LNS.
    PacketUp = fake_join_up_packet(),

    %% Sending a packet up, to get a packet down.
    Route1 = hpr_route:new(1337, [], [], <<"127.0.0.1:1777">>, gwmp, 42),
    Route2 = hpr_route:new(1337, [], [], <<"127.0.0.1:1778">>, gwmp, 42),

    {ok, LNSSocket1} = gen_udp:open(1777, [binary, {active, true}]),
    {ok, LNSSocket2} = gen_udp:open(1778, [binary, {active, true}]),

    %% Send packet to LNS 1
    _ = hpr_gwmp_router:send(PacketUp, unused_test_stream_handler, Route1),
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
    _ = hpr_gwmp_router:send(PacketUp, unused_test_stream_handler, Route2),
    {ok, _Token2, _Data2} = expect_pull_data(LNSSocket2, downlink_test_initiate_connection_lns2),
    {ok, _} = expect_push_data(LNSSocket2, route2_push_data),

    %% LNS 2 is now the most recent communicator with the UDP worker.
    %% Regardless, sending a PULL_RESP, the UDP worker should ack the sender,
    %% not the most recent.

    %% Mock out the return path for the downlink (grpc)
    Self = self(),
    meck:new(grpcbox_stream, [passthrough, no_history]),
    meck:expect(grpcbox_stream, send, fun(Eos, PacketDown, _StreamHandler) ->
        ?assertEqual(false, Eos, "we don't want to be ending the stream"),
        Self ! {packet_down, PacketDown}
    end),

    %% Send a downlink to the worker from LNS 1
    %% we don't care about the contents
    {DownToken, DownPullResp} = fake_down_packet(),
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

    meck:unload(grpcbox_stream),

    ok.

multi_gw_single_lns_test(_Config) ->
    %% Ensure gws start up uniquely
    PacketUp1 = fake_join_up_packet(),
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    PacketUp2 = PacketUp1#packet_router_packet_up_v1_pb{gateway = PubKeyBin},

    Route = hpr_route:new(
        1337,
        [],
        [],
        <<"127.0.0.1:1777">>,
        gwmp,
        42
    ),

    {ok, RcvSocket} = gen_udp:open(1777, [binary, {active, true}]),

    %% Send the packet from the first gateway
    hpr_gwmp_router:send(PacketUp1, unused_test_stream_handler, Route),
    {ok, _Token, _Data} = expect_pull_data(RcvSocket, first_gw_pull_data),
    {ok, _} = expect_push_data(RcvSocket, first_gw_push_data),

    %% Send the same packet from the second gateway
    hpr_gwmp_router:send(PacketUp2, unused_test_stream_handler, Route),
    {ok, _Token2, _Data2} = expect_pull_data(RcvSocket, second_gw_pull_data),
    {ok, _} = expect_push_data(RcvSocket, second_gw_push_data),

    ok = gen_udp:close(RcvSocket),

    ok.

shutdown_idle_worker_test(_Config) ->
    %%    make an up packet
    PacketUp = fake_join_up_packet(),

    PubKeyBin = hpr_packet_up:gateway(PacketUp),
    %%    start worker
    {ok, WorkerPid1} = hpr_gwmp_udp_sup:maybe_start_worker(PubKeyBin, #{shutdown_timer => 100}),
    ?assert(erlang:is_process_alive(WorkerPid1)),

    %%    wait for shutdown timer to expire
    timer:sleep(120),
    ?assertNot(erlang:is_process_alive(WorkerPid1)),

    %%    start worker
    {ok, WorkerPid2} = hpr_gwmp_udp_sup:maybe_start_worker(PubKeyBin, #{shutdown_timer => 100}),
    ?assert(erlang:is_process_alive(WorkerPid2)),
    timer:sleep(50),

    %%    before timer expires, send push_data
    Route = test_route_1777(),
    ok = hpr_gwmp_router:send(PacketUp, unused_test_stream_handler, Route),

    %%    check that timer restarted when the push_data occurred
    timer:sleep(50),
    ?assert(erlang:is_process_alive(WorkerPid2)),

    %%    check that the timer expires and the worker is shut down
    timer:sleep(100),
    ?assertNot(erlang:is_process_alive(WorkerPid2)),

    ok.

pull_data_test(_Config) ->
    %%    send push_data to start sending of pull_data
    PacketUp = fake_join_up_packet(),
    PubKeyBin = hpr_packet_up:gateway(PacketUp),

    Route = test_route_1777(),

    {ok, RcvSocket} = gen_udp:open(1777, [binary, {active, true}]),

    hpr_gwmp_router:send(PacketUp, unused_test_stream_handler, Route),

    %% Initial PULL_DATA
    {ok, Token, MAC} = expect_pull_data(RcvSocket, route_pull_data),
    ?assert(erlang:is_binary(Token)),
    ?assertEqual(MAC, hpr_gwmp_worker:pubkeybin_to_mac(PubKeyBin)),

    ok.

gateway_dest_redirect(_Config) ->
    Route = hpr_route:new(1337, [], [], ?REDIRECT_WORKER_ENDPOINT, gwmp, 42),

    {ok, USSocket} = gen_udp:open(1778, [binary, {active, true}]),
    {ok, EUSocket} = gen_udp:open(1779, [binary, {active, true}]),

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% NOTE: Hotspot needs to be changed because 1 hotspot can't send from 2 regions.
    USPacketUp = fake_join_up_packet(),
    EUPacketUp = USPacketUp#packet_router_packet_up_v1_pb{gateway = PubKeyBin, region = 'EU868'},

    %% US send packet
    hpr_gwmp_router:send(USPacketUp, unused_test_stream_handler, Route),
    {ok, _, _} = expect_pull_data(USSocket, us_redirected_pull_data),
    {ok, _} = expect_push_data(USSocket, us_redirected_push_data),

    %% EU send packet
    hpr_gwmp_router:send(EUPacketUp, unused_test_stream_handler, Route),
    {ok, _, _} = expect_pull_data(EUSocket, eu_redirected_pull_data),
    {ok, _} = expect_push_data(EUSocket, eu_redirected_push_data),

    %% cleanup
    ok = gen_udp:close(USSocket),
    ok = gen_udp:close(EUSocket),

    ok.

bad_route_test(_Config) ->
    Route1 = hpr_route:new(1337, [], [], <<"bad_route">>, gwmp, 42),
    Route2 = hpr_route:new(1337, [], [], <<"127.0.0.1:1778">>, gwmp, 42),

    %%    First route is bad. Second route is good.
    Routes = [
        Route1,
        Route2
    ],

    PacketUp = fake_join_up_packet(),
    meck:new(hpr_packet_up, [passthrough, no_history]),
    meck:new(hpr_routing_config_worker, [passthrough, no_history]),

    meck:expect(hpr_packet_up, verify, fun(_) -> true end),
    meck:expect(hpr_routing_config_worker, lookup_eui, fun(_, _) -> Routes end),

    hpr_routing:handle_packet(PacketUp, unused),

    meck:unload(hpr_packet_up),
    meck:unload(hpr_routing_config_worker),
    ok.
%% ===================================================================
%% Helpers
%% ===================================================================

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
    #packet_router_packet_up_v1_pb{
        payload =
            <<0, 139, 222, 157, 101, 233, 17, 95, 30, 219, 224, 30, 233, 253, 104, 189, 10, 37, 23,
                110, 239, 137, 95>>,
        timestamp = 620124,
        rssi = 112,
        frequency_mhz = 903.9000244140625,
        datarate = 'SF10BW125',
        snr = 5.5,
        region = 'US915',
        hold_time = 0,
        gateway =
            <<1, 154, 70, 24, 151, 192, 204, 57, 167, 252, 250, 139, 253, 71, 222, 143, 87, 111,
                170, 125, 26, 173, 134, 204, 181, 85, 5, 55, 163, 222, 154, 89, 114>>,
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
    {DownToken, semtech_udp:pull_resp(DownToken, DownMap)}.

fake_down_map() ->
    DownMap = #{
        imme => true,
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
                    <<"tmst">> => hpr_packet_up:timestamp(PacketUp) band 16#FFFF_FFFF
                }
            ],
        <<"stat">> =>
            #{
                <<"pubk">> => libp2p_crypto:bin_to_b58(PubKeyBin),
                <<"regi">> => erlang:atom_to_binary(hpr_packet_up:region(PacketUp))
            }
    },
    ?assert(test_utils:match_map(MapFromPacketUp, JsonData)).
