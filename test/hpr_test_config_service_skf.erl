-module(hpr_test_config_service_skf).

-behaviour(helium_config_session_key_filter_bhvr).

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
    stream_resp/1
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    Self = self(),
    true = erlang:register(?MODULE, self()),
    lager:notice("init ~p @ ~p", [?MODULE, Self]),
    StreamState.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({stream_resp, SKFStreamResp}, StreamState) ->
    lager:notice("got SKFStreamResp ~p", [SKFStreamResp]),
    grpcbox_stream:send(false, SKFStreamResp, StreamState);
handle_info(_Msg, StreamState) ->
    StreamState.

list(_Ctx, _SKFListReq) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

get(_Ctx, _SKFListReq) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

create(_Ctx, _SKFListReq) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

update(_Ctx, _SKFListReq) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

delete(_Ctx, _SKFListReq) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

stream(SKFStreamReq, StreamState) ->
    lager:notice("stream_req ~p", [SKFStreamReq]),
    case hpr_skf_stream_req:verify(SKFStreamReq) of
        false ->
            lager:notice("PERMISSION_DENIED"),
            {grpc_error, {7, <<"PERMISSION_DENIED">>}};
        true ->
            lager:notice("OK"),
            {ok, StreamState}
    end.

-spec stream_resp(
    SKFStreamResp :: hpr_skf_stream_res:res()
) -> ok.
stream_resp(SKFStreamResp) ->
    lager:notice("stream_resp ~p  @ ~p", [SKFStreamResp, erlang:whereis(?MODULE)]),
    ?MODULE ! {stream_resp, SKFStreamResp},
    ok.
