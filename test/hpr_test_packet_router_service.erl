-module(hpr_test_packet_router_service).

-behaviour(helium_packet_router_packet_bhvr).

-export([
    init/2,
    route/2,
    handle_info/2
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(RPC, StreamState) ->
    %% ct:print("TEST: initializing stream for ~p: ~p", [RPC, StreamState]),
    F = application:get_env(hpr, packet_service_init_fun, fun(_, _) -> StreamState end),
    F(RPC, StreamState).

-spec route(hpr_envelope_up:envelope(), grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
route(Env, StreamState) ->
    %% ct:print("TEST: route: ~p", [Env]),
    F = application:get_env(hpr, packet_service_route_fun, fun(_, _) -> {ok, StreamState} end),
    F(Env, StreamState).

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(Msg, StreamState) ->
    %% ct:print("TEST: handle_info: ~p", [Msg]),
    F = application:get_env(hpr, packet_service_handle_info_fun, fun(_, _) -> StreamState end),
    F(Msg, StreamState).
