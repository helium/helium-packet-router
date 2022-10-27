-module(test_config_service).

-behaviour(helium_config_route_bhvr).

-include("../src/grpc/autogen/server/config_pb.hrl").

-export([
    init/2,
    handle_info/2
]).

-export([
    list/2,
    get/2,
    create/2,
    update/2,
    delete/2,
    stream/2
]).

-export([
    route_v1/1
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    Self = self(),
    true = erlang:register(?MODULE, self()),
    ct:pal("init ~p @ ~p", [?MODULE, Self]),
    StreamState.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({route_v1, RouteStreamResp}, StreamState) ->
    ct:pal("got RouteStreamResp ~p", [RouteStreamResp]),
    grpcbox_stream:send(false, RouteStreamResp, StreamState);
handle_info(_Msg, StreamState) ->
    StreamState.

list(_Ctx, _RouteListReq) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

get(_Ctx, _RouteListReq) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

create(_Ctx, _RouteListReq) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

update(_Ctx, _RouteListReq) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

delete(_Ctx, _RouteListReq) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

%% TODO: Check RouteStreamReq
stream(_RouteStreamReq, StreamState) ->
    {ok, StreamState}.

-spec route_v1(RouteStreamResp :: #config_route_stream_res_v1_pb{}) -> ok.
route_v1(RouteStreamResp) ->
    ct:pal("route_v1 ~p  @ ~p", [RouteStreamResp, erlang:whereis(?MODULE)]),
    ?MODULE ! {route_v1, RouteStreamResp},
    ok.
