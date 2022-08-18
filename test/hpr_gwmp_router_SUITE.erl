-module(hpr_gwmp_router_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    single_lns_test/1,
    multi_lns_test/1,
    downlink_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/server/packet_router_pb.hrl").

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
        downlink_test
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

single_lns_test(_Config) ->
    PacketUp = fake_join_up_packet(),

    Route = hpr_route:new(
        1337,
        [],
        [],
        <<"127.0.0.1:1777">>,
        gwmp,
        42
    ),

    {ok, RcvSocket} = gen_udp:open(1777, [binary, {active, true}]),

    hpr_gwmp_router:send(PacketUp, self(), Route),
    %% Initial PULL_DATA
    ok = expect_pull_data(RcvSocket, route_pull_ata),
    %% PUSH_DATA
    {ok, _} = expect_push_data(RcvSocket, router_push_data),

    ok = gen_udp:close(RcvSocket),

    ok.

multi_lns_test(_Config) ->
    PacketUp = fake_join_up_packet(),

    Route1 = hpr_route:new(1337, [], [], <<"127.0.0.1:1777">>, gwmp, 42),
    Route2 = hpr_route:new(1337, [], [], <<"127.0.0.1:1778">>, gwmp, 42),

    {ok, RcvSocket1} = gen_udp:open(1777, [binary, {active, true}]),
    {ok, RcvSocket2} = gen_udp:open(1778, [binary, {active, true}]),

    %% Send packet to route 1
    hpr_gwmp_router:send(PacketUp, self(), Route1),
    ok = expect_pull_data(RcvSocket1, route1_pull_data),
    {ok, _} = expect_push_data(RcvSocket1, route1_push_data),

    %% Same packet to route 2
    hpr_gwmp_router:send(PacketUp, self(), Route2),
    ok = expect_pull_data(RcvSocket2, route2_pull_data),
    {ok, _} = expect_push_data(RcvSocket2, route2_push_data),

    %% Another packet to route 1
    hpr_gwmp_router:send(PacketUp, self(), Route1),
    {ok, _} = expect_push_data(RcvSocket1, route1_push_data_repeat),
    ok = no_more_messages(),

    ok = gen_udp:close(RcvSocket1),
    ok = gen_udp:close(RcvSocket2),

    ok.

downlink_test(_Config) ->
    PacketUp = fake_join_up_packet(),

    %% Sending a packet up, to get a packet down.
    Route1 = hpr_route:new(1337, [], [], <<"127.0.0.1:1777">>, gwmp, 42),
    {ok, LnsSocket} = gen_udp:open(1777, [binary, {active, true}]),

    %% Send packet
    _ = hpr_gwmp_router:send(PacketUp, self(), Route1),

    %% Eat the pull_data
    ok = expect_pull_data(LnsSocket, downlink_test_initiate_connection),
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
    %% we don't care about the contents
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
    DownToken = semtech_udp:token(),
    DownPullResp = semtech_udp:pull_resp(DownToken, DownMap),
    ok = gen_udp:send(LnsSocket, ReturnSocketDest, DownPullResp),

    %% receive the PacketRouterPacketDownV1 as the grpc stream.
    receive
        {packet_down, #packet_router_packet_down_v1_pb{}} ->
            %% Nothing in the packet_down we care to assert right now.
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

%% ===================================================================
%% Helpers
%% ===================================================================

expect_pull_data(Socket, Reason) ->
    receive
        {udp, Socket, _Address, _Port, Data} ->
            ?assertEqual(pull_data, semtech_id_atom(Data), Reason),
            ok
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
        signal_strength = -112.0,
        frequency = 903.9000244140625,
        datarate = "SF10BW125",
        snr = 5.5,
        region = 'US915',
        hold_time = 0,
        hotspot =
            <<1, 154, 70, 24, 151, 192, 204, 57, 167, 252, 250, 139, 253, 71, 222, 143, 87, 111,
                170, 125, 26, 173, 134, 204, 181, 85, 5, 55, 163, 222, 154, 89, 114>>,
        signature =
            <<29, 184, 117, 202, 112, 159, 1, 47, 91, 121, 185, 105, 107, 72, 122, 119, 202, 112,
                128, 43, 48, 31, 128, 255, 102, 166, 200, 105, 130, 39, 131, 148, 46, 112, 145, 235,
                61, 200, 166, 101, 111, 8, 25, 81, 34, 7, 218, 70, 180, 134, 3, 206, 244, 175, 46,
                185, 130, 191, 104, 131, 164, 40, 68, 11>>
    }.
