-module(hpr_hotspot_service).

-behaviour(packet_router_hotspot_bhvr).

-export([
    init/1,
    send_packet/2,
    handle_info/2
]).

-spec init(Stream :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(Stream) ->
    Stream.

-spec send_packet(Ref :: reference(), Stream :: grpcbox_stream:t()) ->
    ok | {continue, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
send_packet(_Ref, Stream) ->
    {continue, Stream}.

-spec handle_info(Msg :: any(), Stream :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_Msg, Stream) ->
    Stream.
