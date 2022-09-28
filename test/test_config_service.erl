-module(test_config_service).

-behaviour(helium_config_config_service_bhvr).

-include("../src/grpc/autogen/server/config_pb.hrl").

-export([
    init/2,
    handle_info/2,
    route_updates/2
]).
-export([
    config_route_res_v1/1
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    Self = self(),
    ok = persistent_term:put(?MODULE, self()),
    ct:pal("init ~p @ ~p", [?MODULE, Self]),
    StreamState.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({config_route_res_v1, ConfigRouteResV1}, StreamState) ->
    ct:pal("got config_route_res_v1 ~p", [ConfigRouteResV1]),
    grpcbox_stream:send(false, ConfigRouteResV1, StreamState);
handle_info(_Msg, StreamState) ->
    StreamState.

-spec route_updates(config_pb:config_routes_req_v1_pb(), grpcbox_stream:t()) ->
    ok
    | {ok, grpcbox_stream:t()}
    | {ok, config_pb:config_routes_res_v1_pb(), grpcbox_stream:t()}
    | {stop, grpcbox_stream:t()}
    | {stop, config_pb:config_routes_res_v1_pb(), grpcbox_stream:t()}
    | grpcbox_stream:grpc_error_response().
route_updates(#config_routes_req_v1_pb{}, StreamState) ->
    {ok, StreamState}.

-spec config_route_res_v1(ConfigRouteResV1 :: #config_routes_res_v1_pb{}) -> ok.
config_route_res_v1(ConfigRouteResV1) ->
    Pid = persistent_term:get(?MODULE),
    ct:pal("config_route_res_v1 ~p  @ ~p", [ConfigRouteResV1, Pid]),
    Pid ! {config_route_res_v1, ConfigRouteResV1},
    ok.
