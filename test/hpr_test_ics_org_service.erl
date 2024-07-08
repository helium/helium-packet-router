-module(hpr_test_ics_org_service).

-behaviour(helium_iot_config_org_bhvr).

-include("../src/grpc/autogen/iot_config_pb.hrl").

-export([
    init/2,
    handle_info/2
]).

-export([
    list/2,
    get/2,
    create_helium/2,
    create_roamer/2,
    update/2,
    disable/2,
    enable/2
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    StreamState.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_Msg, StreamState) ->
    StreamState.

list(Ctx, _Msg) ->
    OrgList = #iot_config_org_list_res_v1_pb{
        orgs = application:get_env(hpr, test_org_service_orgs, []),
        timestamp = erlang:system_time(millisecond),
        signer = <<>>,
        signature = <<>>
    },
    {ok, OrgList, Ctx}.

get(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

create_helium(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

create_roamer(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

update(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

disable(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

enable(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.
