-module(test_hpr_gateway_service).

-behaviour(helium_packet_router_gateway_bhvr).

-export([
    init/2,
    send_packet/2,
    handle_info/2
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(RPC, StreamState) ->
    %% ct:print("TEST: initializing stream for ~p: ~p", [RPC, StreamState]),
    F = application:get_env(hpr, gateway_service_init_fun, fun(_, _) -> StreamState end),
    F(RPC, StreamState).

-spec send_packet(hpr_packet_up:packet(), grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
send_packet(PacketUp, StreamState) ->
    %% ct:print("TEST: send_packet: ~p", [PacketUp]),
    F = application:get_env(hpr, gateway_service_send_packet_fun, fun(_, _) -> StreamState end),
    F(PacketUp, StreamState).

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(Msg, StreamState) ->
    %% ct:print("TEST: handle_info: ~p", [Msg]),
    F = application:get_env(hpr, gateway_service_handle_info_fun, fun(_, _) -> StreamState end),
    F(Msg, StreamState).
