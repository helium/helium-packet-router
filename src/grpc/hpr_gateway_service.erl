-module(hpr_gateway_service).

-behaviour(helium_packet_router_gateway_bhvr).

-include("../grpc/autogen/server/packet_router_pb.hrl").

-export([
    init/2,
    send_packet/2,
    handle_info/2
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    StreamState.

-spec send_packet(hpr_packet_up:packet(), grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
send_packet(PacketUp, StreamState) ->
    grpcbox_service_reply(hpr_routing:handle_packet(PacketUp), StreamState).

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({reply, Reply}, StreamState) ->
    grpcbox_stream:send(false, Reply, StreamState);
handle_info(_Msg, StreamState) ->
    StreamState.

%% ===================================================================

-spec grpcbox_service_reply
    (ok, grpcbox_stream:t()) -> {ok, grpc_stream:t()};
    ({error, any()}, grpcbox_stream:t()) -> grpcbox_stream:grpc_error_response().
grpcbox_service_reply(ok, StreamState) ->
    {ok, StreamState};
grpcbox_service_reply({error, Error}, _StreamState) ->
    % TODO proper error code and error formatting?
    {grpc_error, {2, iolist_to_binary(io_lib:print(Error))}}.
