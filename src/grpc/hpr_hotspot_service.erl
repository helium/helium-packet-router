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
    ok | {continue, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
send_packet(PacketUp, Stream) ->
    _ = proc_lib:spawn(hpr_routing, handle_packet, [PacketUp, Stream]),
    {continue, Stream}.

-spec handle_info(Msg :: any(), Stream :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_Msg, Stream) ->
    Stream.

%% ===================================================================
