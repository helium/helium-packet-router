-module(hpr_hotspot_service).

-behaviour(helium_packet_router_hotspot_bhvr).

-include("../grpc/autogen/server/packet_router_pb.hrl").

-export([
    init/1,
    send_packet/2,
    handle_info/2
]).

-spec init(Stream :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(Stream) ->
    Stream.

-spec send_packet(hpr_packet_up:packet(), grpcbox_stream:t()) ->
    ok
    | {ok, grpcbox_stream:t()}
    | {ok, packet_router_pb:packet_router_packet_down_v1_pb(), grpcbox_stream:t()}
    | {stop, grpcbox_stream:t()}
    | {stop, packet_router_pb:packet_router_packet_down_v1_pb(), grpcbox_stream:t()}
    | grpcbox_stream:grpc_error_response().
send_packet(_PacketUp, Stream) ->
    {ok, Stream}.

-spec handle_info(Msg :: any(), Stream :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_Msg, Stream) ->
    Stream.
