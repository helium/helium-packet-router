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
init(RPC, StreamState) ->
    case RPC of
        stream ->
            Self = self(),
            true = erlang:register(?MODULE, self()),
            lager:notice("init ~p @ ~p", [?MODULE, Self]);
        _ ->
            lager:notice("initialize stream for ~p", [RPC])
    end,
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

get_euis(GetEUIsReq, StreamState) ->
    Encoded = iot_config_pb:encode_msg(GetEUIsReq#iot_config_route_get_euis_req_v1_pb{
        signature = <<>>
    }),
    case
        libp2p_crypto:verify(
            Encoded,
            GetEUIsReq#iot_config_route_get_euis_req_v1_pb.signature,
            libp2p_crypto:bin_to_pubkey(GetEUIsReq#iot_config_route_get_euis_req_v1_pb.signer)
        )
    of
        false ->
            {grpc_error, {grpcbox_stream:code_to_status(7), <<"PERMISSION_DENIED">>}};
        true ->
            lists:foreach(
                fun({Last, El}) -> grpcbox_stream:send(Last, El, StreamState) end,
                hpr_utils:enumerate_last(application:get_env(hpr, test_route_get_euis, []))
            ),
            {stop, StreamState}
    end.

update_euis(_Msg, _Stream) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

delete_euis(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

get_devaddr_ranges(RouteDevaddrReq, StreamState) ->
    Encoded = iot_config_pb:encode_msg(
        RouteDevaddrReq#iot_config_route_get_devaddr_ranges_req_v1_pb{signature = <<>>}
    ),
    case
        libp2p_crypto:verify(
            Encoded,
            RouteDevaddrReq#iot_config_route_get_devaddr_ranges_req_v1_pb.signature,
            libp2p_crypto:bin_to_pubkey(
                RouteDevaddrReq#iot_config_route_get_devaddr_ranges_req_v1_pb.signer
            )
        )
    of
        false ->
            {grpc_error, {grpcbox_stream:code_to_status(7), <<"PERMISSION_DENIED">>}};
        true ->
            %% send what we have and close the stream
            lists:foreach(
                fun({Last, El}) -> grpcbox_stream:send(Last, El, StreamState) end,
                hpr_utils:enumerate_last(
                    application:get_env(hpr, test_route_get_devaddr_ranges, [])
                )
            ),
            {stop, StreamState}
    end.

update_devaddr_ranges(_Msg, _Stream) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

delete_devaddr_ranges(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

get_skfs(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

list_skfs(RouteSKFReq, StreamState) ->
    Encoded = iot_config_pb:encode_msg(RouteSKFReq#iot_config_route_skf_list_req_v1_pb{
        signature = <<>>
    }),
    case
        libp2p_crypto:verify(
            Encoded,
            RouteSKFReq#iot_config_route_skf_list_req_v1_pb.signature,
            libp2p_crypto:bin_to_pubkey(RouteSKFReq#iot_config_route_skf_list_req_v1_pb.signer)
        )
    of
        false ->
            {grpc_error, {grpcbox_stream:code_to_status(7), <<"PERMISSION_DENIED">>}};
        true ->
            lists:foreach(
                fun({Last, El}) -> grpcbox_stream:send(Last, El, StreamState) end,
                hpr_utils:enumerate_last(application:get_env(hpr, test_route_list_skfs, []))
            ),
            {stop, StreamState}
    end.

update_skfs(_Ctx, _Msg) ->
    {grpc_error, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}}.

-spec stream_resp(RouteStreamResp :: hpr_route_stream_res:res()) -> ok.
stream_resp(RouteStreamResp) ->
    lager:notice("stream_resp ~p  @ ~p", [RouteStreamResp, erlang:whereis(?MODULE)]),
    ?MODULE ! {stream_resp, RouteStreamResp},
    ok.
