-module(hpr_test_iot_config_service_route).

-behaviour(helium_iot_config_route_bhvr).

-include("../src/grpc/autogen/iot_config_pb.hrl").

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
    stream/2,
    get_euis/2,
    update_euis/2,
    delete_euis/2,
    get_devaddr_ranges/2,
    update_devaddr_ranges/2,
    delete_devaddr_ranges/2,
    get_skfs/2,
    list_skfs/2,
    update_skfs/2
]).

-export([
    stream_resp/1
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    Self = self(),
    true = erlang:register(?MODULE, self()),
    lager:notice("init ~p @ ~p", [?MODULE, Self]),
    StreamState.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({stream_resp, RouteStreamResp}, StreamState) ->
    lager:notice("got RouteStreamResp ~p", [RouteStreamResp]),
    grpcbox_stream:send(false, RouteStreamResp, StreamState);
handle_info(_Msg, StreamState) ->
    StreamState.

list(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

get(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

create(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

update(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

delete(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

stream(RouteStreamReq, StreamState) ->
    case hpr_route_stream_req:verify(RouteStreamReq) of
        false ->
            {grpc_error, {grpcbox_stream:code_to_status(7), <<"PERMISSION_DENIED">>}};
        true ->
            {ok, StreamState}
    end.

get_euis(_Msg, _Stream) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

update_euis(_Msg, _Stream) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

delete_euis(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

get_devaddr_ranges(_Msg, _Stream) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

update_devaddr_ranges(_Msg, _Stream) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

delete_devaddr_ranges(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

get_skfs(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

list_skfs(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

update_skfs(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

-spec stream_resp(RouteStreamResp :: hpr_route_stream_res:res()) -> ok.
stream_resp(RouteStreamResp) ->
    lager:notice("stream_resp ~p  @ ~p", [RouteStreamResp, erlang:whereis(?MODULE)]),
    ?MODULE ! {stream_resp, RouteStreamResp},
    ok.
