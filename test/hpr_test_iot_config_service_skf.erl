-module(hpr_test_iot_config_service_skf).

-behaviour(helium_iot_config_session_key_filter_bhvr).

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
handle_info({stream_resp, SKFStreamResp}, StreamState) ->
    lager:notice("got SKFStreamResp ~p", [SKFStreamResp]),
    grpcbox_stream:send(false, SKFStreamResp, StreamState);
handle_info({set_signer, Signer}, StreamState) ->
    lager:notice("got new Signer ~p @ ~p", [Signer, ?MODULE]),
    HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    grpcbox_stream:stream_handler_state(StreamState, HandlerState#state{signer = Signer});
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
    HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    Signer = HandlerState#state.signer,
    case hpr_skf_stream_req:verify(SKFStreamReq, Signer) of
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

-spec set_signer(Signer :: libp2p_crypto:pubkey_bin()) -> ok.
set_signer(Signer) ->
    lager:notice("set_signer ~p @ ~p", [Signer, erlang:whereis(?MODULE)]),
    ?MODULE ! {set_signer, Signer},
    ok.
