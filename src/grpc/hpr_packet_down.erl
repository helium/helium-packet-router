-module(hpr_packet_down).

-include("../grpc/autogen/server/packet_router_pb.hrl").

-export([to_record/1]).

-type packet_map() :: client_packet_router_pb:packet_router_packet_down_v1_pb().
-type packet() :: packet_router_pb:packet_router_packet_down_v1_pb().

-export_type([
    packet_map/0,
    packet/0
]).

-spec to_record(packet_map() | map()) -> packet().
to_record(PacketMap) ->
    Template = #packet_router_packet_down_v1_pb{},
    #packet_router_packet_down_v1_pb{
        payload = maps:get(payload, PacketMap, Template#packet_router_packet_down_v1_pb.payload),
        rx1 = window(maps:get(rx1, PacketMap, Template#packet_router_packet_down_v1_pb.rx1)),
        rx2 = window(maps:get(rx2, PacketMap, Template#packet_router_packet_down_v1_pb.rx1))
    }.

% ------------------------------------------------------------------------------
% Private Functions
% ------------------------------------------------------------------------------

-spec window
    (undefined) -> undefined;
    (client_packet_router_pb:window_v1_pb() | map()) -> packet_router_pb:window_v1_pb().
window(undefined) ->
    undefined;
window(WindowMap) ->
    Template = #window_v1_pb{},
    #window_v1_pb{
        timestamp = maps:get(timestamp, WindowMap, Template#window_v1_pb.timestamp),
        frequency = maps:get(frequency, WindowMap, Template#window_v1_pb.frequency),
        datarate = maps:get(datarate, WindowMap, Template#window_v1_pb.datarate)
    }.

% ------------------------------------------------------------------------------
% Eunit tests
% ------------------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    [
        ?_test(test_window()),
        ?_test(test_to_record())
    ].

test_window() ->
    ?assertEqual(undefined, window(undefined)),
    ?assertEqual(#window_v1_pb{}, window(#{})),
    ?assertEqual(ok, packet_router_pb:verify_msg(window(fake_window()), window_v1_pb)),
    ?assertEqual(ok, packet_router_pb:verify_msg(window(#{}), window_v1_pb)).

test_to_record() ->
    ?assertEqual(#packet_router_packet_down_v1_pb{}, to_record(#{})),

    ?assertEqual(
        ok, packet_router_pb:verify_msg(to_record(fake_packet()), packet_router_packet_down_v1_pb)
    ),
    ?assertEqual(ok, packet_router_pb:verify_msg(to_record(#{}), packet_router_packet_down_v1_pb)).

% ------------------------------------------------------------------------------
% Eunit private functions
% ------------------------------------------------------------------------------

fake_window() ->
    WindowMap = #{
        timestamp => 1,
        frequency => 1.0,
        datarate => 'SF12BW125'
    },
    ?assertEqual(ok, client_packet_router_pb:verify_msg(WindowMap, window_v1_pb)),
    WindowMap.

fake_packet() ->
    PacketMap = #{
        payload => <<"fake payload">>,
        rx1 => fake_window(),
        rx2 => fake_window()
    },
    ?assertEqual(
        ok, client_packet_router_pb:verify_msg(PacketMap, packet_router_packet_down_v1_pb)
    ),
    PacketMap.

-endif.
