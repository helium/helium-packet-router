-module(hpr_packet_service).

-behaviour(helium_packet_router_packet_bhvr).

-export([
    init/2,
    route/2,
    handle_info/2
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    StreamState.

-spec route(hpr_packet_up:packet(), grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
route(PacketUp, StreamState) ->
    case hpr_routing:handle_packet(PacketUp) of
        ok ->
            {ok, StreamState};
        {error, Err} ->
            {grpc_error, {2, erlang:iolist_to_binary(io_lib:print(Err))}}
    end.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({reply, Reply}, StreamState) ->
    grpcbox_stream:send(false, Reply, StreamState);
handle_info({router_reply, ReplyMap}, StreamState) ->
    Reply = hpr_packet_down:to_record(ReplyMap),
    grpcbox_stream:send(false, Reply, StreamState);
handle_info(_Msg, StreamState) ->
    StreamState.