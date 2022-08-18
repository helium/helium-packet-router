-module(hpr_gwmp_router_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    single_lns_test/1,
    multi_lns_test/1
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
        multi_lns_test
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
    PacketUp =
        #packet_router_packet_up_v1_pb{
            payload =
                <<0, 139, 222, 157, 101, 233, 17, 95, 30, 219, 224, 30, 233, 253, 104, 189, 10, 37,
                    23, 110, 239, 137, 95>>,
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
                <<29, 184, 117, 202, 112, 159, 1, 47, 91, 121, 185, 105, 107, 72, 122, 119, 202,
                    112, 128, 43, 48, 31, 128, 255, 102, 166, 200, 105, 130, 39, 131, 148, 46, 112,
                    145, 235, 61, 200, 166, 101, 111, 8, 25, 81, 34, 7, 218, 70, 180, 134, 3, 206,
                    244, 175, 46, 185, 130, 191, 104, 131, 164, 40, 68, 11>>
        },

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
    PacketUp =
        #packet_router_packet_up_v1_pb{
            payload =
                <<0, 139, 222, 157, 101, 233, 17, 95, 30, 219, 224, 30, 233, 253, 104, 189, 10, 37,
                    23, 110, 239, 137, 95>>,
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
                <<29, 184, 117, 202, 112, 159, 1, 47, 91, 121, 185, 105, 107, 72, 122, 119, 202,
                    112, 128, 43, 48, 31, 128, 255, 102, 166, 200, 105, 130, 39, 131, 148, 46, 112,
                    145, 235, 61, 200, 166, 101, 111, 8, 25, 81, 34, 7, 218, 70, 180, 134, 3, 206,
                    244, 175, 46, 185, 130, 191, 104, 131, 164, 40, 68, 11>>
        },

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
