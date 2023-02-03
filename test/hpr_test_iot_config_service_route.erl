-module(hpr_test_iot_config_service_route).

-behaviour(helium_iot_config_route_bhvr).

-include("hpr.hrl").

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
    get_euis/2,
    update_euis/2,
    delete_euis/2,
    get_devaddr_ranges/2,
    update_devaddr_ranges/2,
    delete_devaddr_ranges/2,
    stream/2
]).

-export([
    stream_resp/1,
    set_signer/1
]).

-record(state, {
    signer :: undefined | libp2p_crypto:pubkey_bin()
}).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    Self = self(),
    true = erlang:register(?MODULE, self()),
    {PubKey, _SigFun} = persistent_term:get(?HPR_KEY, {undefined, undefined}),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    lager:notice("init ~p @ ~p with signer ~p", [?MODULE, Self, PubKeyBin]),
    grpcbox_stream:stream_handler_state(StreamState, #state{signer = PubKeyBin}).

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({stream_resp, RouteStreamResp}, StreamState) ->
    lager:notice("got RouteStreamResp ~p", [RouteStreamResp]),
    grpcbox_stream:send(false, RouteStreamResp, StreamState);
handle_info({set_signer, Signer}, StreamState) ->
    lager:notice("got new Signer ~p @ ~p", [Signer, ?MODULE]),
    HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    grpcbox_stream:stream_handler_state(StreamState, HandlerState#state{signer = Signer});
handle_info(_Msg, StreamState) ->
    StreamState.

list(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

get(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

create(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

update(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

delete(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

get_euis(_Msg, _Stream) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

update_euis(_Msg, _Stream) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

delete_euis(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

get_devaddr_ranges(_Msg, _Stream) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

update_devaddr_ranges(_Msg, _Stream) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

delete_devaddr_ranges(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

stream(RouteStreamReq, StreamState) ->
    HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    Signer = HandlerState#state.signer,
    case hpr_route_stream_req:verify(RouteStreamReq, Signer) of
        false ->
            {grpc_error, {7, <<"PERMISSION_DENIED">>}};
        true ->
            {ok, StreamState}
    end.

-spec stream_resp(RouteStreamResp :: hpr_route_stream_res:res()) -> ok.
stream_resp(RouteStreamResp) ->
    lager:notice("stream_resp ~p  @ ~p", [RouteStreamResp, erlang:whereis(?MODULE)]),
    ?MODULE ! {stream_resp, RouteStreamResp},
    ok.

-spec set_signer(Signer :: libp2p_crypto:pubkey_bin()) -> ok.
set_signer(Signer) ->
    lager:notice("set_signer ~p @ ~p", [Signer, erlang:whereis(?MODULE)]),
    ?MODULE ! {set_signer, Signer},
    ok.
