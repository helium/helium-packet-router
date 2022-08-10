-module(helium_packet_router_service).

-behaviour(helium_packet_router_packet_router_bhvr).

-export([
    init/1,
    msg/2,
    handle_info/2
]).

-spec init(Stream :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(Stream) ->
    Stream.

-spec msg(Ref :: reference(), Stream :: grpcbox_stream:t()) ->
    ok | {continue, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
msg(_Ref, Stream) ->
    {continue, Stream}.

-spec handle_info(Msg :: any(), Stream :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_Msg, Stream) ->
    Stream.
