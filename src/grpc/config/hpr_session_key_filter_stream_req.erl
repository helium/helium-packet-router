-module(hpr_session_key_filter_stream_req).

-include("../autogen/server/config_pb.hrl").

-export([
    new/1,
    timestamp/1,
    signer/1,
    signature/1,
    sign/2,
    verify/1,
    to_map/1
]).

-type session_key_filter_stream_req() :: #config_session_key_filter_stream_req_v1_pb{}.

-export_type([session_key_filter_stream_req/0]).

-spec new(Signer :: libp2p_crypto:pubkey_bin()) -> session_key_filter_stream_req().
new(Signer) ->
    #config_session_key_filter_stream_req_v1_pb{
        timestamp = erlang:system_time(millisecond),
        signer = Signer
    }.

-spec timestamp(RouteStreamReq :: session_key_filter_stream_req()) -> non_neg_integer().
timestamp(RouteStreamReq) ->
    RouteStreamReq#config_session_key_filter_stream_req_v1_pb.timestamp.

-spec signer(RouteStreamReq :: session_key_filter_stream_req()) -> libp2p_crypto:pubkey_bin().
signer(RouteStreamReq) ->
    RouteStreamReq#config_session_key_filter_stream_req_v1_pb.signer.

-spec signature(RouteStreamReq :: session_key_filter_stream_req()) -> binary().
signature(RouteStreamReq) ->
    RouteStreamReq#config_session_key_filter_stream_req_v1_pb.signature.

-spec sign(RouteStreamReq :: session_key_filter_stream_req(), SigFun :: fun()) ->
    session_key_filter_stream_req().
sign(RouteStreamReq, SigFun) ->
    EncodedRouteStreamReq = config_pb:encode_msg(
        RouteStreamReq, config_session_key_filter_stream_req_v1_pb
    ),
    RouteStreamReq#config_session_key_filter_stream_req_v1_pb{
        signature = SigFun(EncodedRouteStreamReq)
    }.

-spec verify(RouteStreamReq :: session_key_filter_stream_req()) -> boolean().
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

-spec to_map(RouteStreamReq :: session_key_filter_stream_req()) -> map().
to_map(RouteStreamReq) ->
    client_config_pb:decode_msg(
        config_pb:encode_msg(RouteStreamReq, config_session_key_filter_stream_req_v1_pb),
        session_key_filter_stream_req_v1_pb
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

to_map_test() ->
    Req = ?MODULE:new(<<"Signer">>),
    Map = ?MODULE:to_map(Req),
    ?assertEqual(?MODULE:timestamp(Req), maps:get(timestamp, Map)),
    ?assertEqual(?MODULE:signer(Req), maps:get(signer, Map)),
    ?assertEqual(?MODULE:signature(Req), maps:get(signature, Map)),
    ok.

-endif.
