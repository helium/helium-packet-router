-module(hpr_skf_stream_req).

-include("../autogen/server/config_pb.hrl").

-export([
    new/1,
    timestamp/1,
    signer/1,
    signature/1,
    sign/2,
    verify/1
]).

-type req() :: #config_session_key_filter_stream_req_v1_pb{}.

-export_type([req/0]).

-spec new(Signer :: libp2p_crypto:pubkey_bin()) -> req().
new(Signer) ->
    #config_session_key_filter_stream_req_v1_pb{
        timestamp = erlang:system_time(millisecond),
        signer = Signer
    }.

-spec timestamp(RouteStreamReq :: req()) -> non_neg_integer().
timestamp(RouteStreamReq) ->
    RouteStreamReq#config_session_key_filter_stream_req_v1_pb.timestamp.

-spec signer(RouteStreamReq :: req()) -> libp2p_crypto:pubkey_bin().
signer(RouteStreamReq) ->
    RouteStreamReq#config_session_key_filter_stream_req_v1_pb.signer.

-spec signature(RouteStreamReq :: req()) -> binary().
signature(RouteStreamReq) ->
    RouteStreamReq#config_session_key_filter_stream_req_v1_pb.signature.

-spec sign(RouteStreamReq :: req(), SigFun :: fun()) ->
    req().
sign(RouteStreamReq, SigFun) ->
    EncodedRouteStreamReq = config_pb:encode_msg(
        RouteStreamReq, config_session_key_filter_stream_req_v1_pb
    ),
    RouteStreamReq#config_session_key_filter_stream_req_v1_pb{
        signature = SigFun(EncodedRouteStreamReq)
    }.

-spec verify(RouteStreamReq :: req()) -> boolean().
verify(RouteStreamReq) ->
    EncodedRouteStreamReq = config_pb:encode_msg(
        RouteStreamReq#config_session_key_filter_stream_req_v1_pb{
            signature = <<>>
        },
        config_session_key_filter_stream_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedRouteStreamReq,
        ?MODULE:signature(RouteStreamReq),
        libp2p_crypto:bin_to_pubkey(?MODULE:signer(RouteStreamReq))
    ).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

timestamp_test() ->
    Signer = <<"Signer">>,
    Timestamp = erlang:system_time(millisecond),
    ?assert(Timestamp =< ?MODULE:timestamp(?MODULE:new(Signer))),
    ok.

signer_test() ->
    Signer = <<"Signer">>,
    ?assertEqual(
        Signer,
        ?MODULE:signer(?MODULE:new(Signer))
    ),
    ok.

signature_test() ->
    Signer = <<"Signer">>,
    ?assertEqual(
        <<>>,
        ?MODULE:signature(?MODULE:new(Signer))
    ),
    ok.

sign_verify_test() ->
    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Signer = libp2p_crypto:pubkey_to_bin(PubKey),
    RouteStreamReq = ?MODULE:new(Signer),

    SignedRouteStreamReq = ?MODULE:sign(RouteStreamReq, SigFun),

    ?assert(?MODULE:verify(SignedRouteStreamReq)),
    ok.

-endif.
