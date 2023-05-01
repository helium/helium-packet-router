-module(hpr_test_downlink_service_http_roaming).

-behaviour(helium_downlink_http_roaming_bhvr).

-include("hpr.hrl").

-export([
    init/2,
    handle_info/2
]).

-export([
    stream/2
]).

-export([
    downlink/1
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
handle_info({downlink, Resp}, StreamState) ->
    lager:notice("got Resp ~p", [Resp]),
    grpcbox_stream:send(false, Resp, StreamState);
handle_info(_Msg, StreamState) ->
    StreamState.

stream(Req, StreamState) ->
    HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    Signer = HandlerState#state.signer,
    case hpr_http_roaming_register:verify(Req, Signer) of
        false ->
            {grpc_error, {grpcbox_stream:code_to_status(7), <<"PERMISSION_DENIED">>}};
        true ->
            {ok, StreamState}
    end.

-spec downlink(Resp :: downlink_pb:http_roaming_downlink_v1_pb()) -> ok.
downlink(Resp) ->
    lager:notice("downlink ~p  @ ~p", [Resp, erlang:whereis(?MODULE)]),
    ?MODULE ! {downlink, Resp},
    ok.
