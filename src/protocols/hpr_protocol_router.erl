-module(hpr_protocol_router).

-include("../grpc/autogen/server/packet_router_pb.hrl").

% TODO: should be in a common include file
-define(JOIN_REQUEST, 2#000).

-export([send/3]).

% ------------------------------------------------------------------------------
% API
% ------------------------------------------------------------------------------

-spec send(
    Packet :: hpr_packet_up:packet(),
    GatewayStream :: pid(),
    Route :: hpr_route:route()
) -> ok.
send(PacketUp, GatewayStream, Route) ->
    LNS = Route#packet_router_route_v1_pb.lns,
    PacketUpMap = hpr_packet_up:to_map(PacketUp),
    {ok, RouterStream} = hpr_router_stream_manager:get_stream(GatewayStream, LNS),
    ok = grpc_client:send(RouterStream, PacketUpMap).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

basic_test_() ->
    [
        {foreach, fun per_testcase_setup/0, fun per_testcase_cleanup/1, [
            ?_test(test_send())
        ]}
    ].

per_testcase_setup() ->
    meck:new(hpr_router_stream_manager),
    meck:new(grpc_client),
    ok.

per_testcase_cleanup(ok) ->
    meck:unload(hpr_router_stream_manager),
    meck:unload(grpc_client).

% send/3: happy path
test_send() ->
    HprPacketUp = test_utils:join_packet_up(#{}),
    HprPacketUpMap = hpr_packet_up:to_map(HprPacketUp),
    Stream = self(),
    GatewayStream = self(),
    Route = hpr_route:new(1, [], [], lns(), router, 1),

    meck:expect(hpr_router_stream_manager, get_stream, [GatewayStream, lns()], {ok, Stream}),
    meck:expect(grpc_client, send, [Stream, HprPacketUpMap], ok),

    ResponseValue = send(HprPacketUp, Stream, Route),

    ?assertEqual(ok, ResponseValue),
    ?assertEqual(1, meck:num_calls(hpr_router_stream_manager, get_stream, 2)),
    ?assertEqual(1, meck:num_calls(grpc_client, send, 2)).

%% ------------------------------------------------------------------
%% Private Test Functions
%% ------------------------------------------------------------------

host() -> "example-lns.com".
port() -> 4321.
lns() ->
    <<(list_to_binary(host()))/binary, $:, (integer_to_binary(port()))/binary>>.

-endif.
