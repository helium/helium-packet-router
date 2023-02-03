-module(hpr_route_stream_req).

-include("../autogen/iot_config_pb.hrl").

-export([
    new/0,
    timestamp/1,
    signature/1,
    sign/2,
    verify/2
]).

-type req() :: #iot_config_route_stream_req_v1_pb{}.

-export_type([req/0]).

-spec new() -> req().
new() ->
    #iot_config_route_stream_req_v1_pb{
        timestamp = erlang:system_time(millisecond)
    }.

-spec timestamp(RouteStreamReq :: req()) -> non_neg_integer().
timestamp(RouteStreamReq) ->
    RouteStreamReq#iot_config_route_stream_req_v1_pb.timestamp.

-spec signature(RouteStreamReq :: req()) -> binary().
signature(RouteStreamReq) ->
    RouteStreamReq#iot_config_route_stream_req_v1_pb.signature.

-spec sign(RouteStreamReq :: req(), SigFun :: fun()) -> req().
sign(RouteStreamReq, SigFun) ->
    EncodedRouteStreamReq = iot_config_pb:encode_msg(
        RouteStreamReq, iot_config_route_stream_req_v1_pb
    ),
    RouteStreamReq#iot_config_route_stream_req_v1_pb{signature = SigFun(EncodedRouteStreamReq)}.

-spec verify(RouteStreamReq :: req(), Signer :: libp2p_crypto:pubkey_bin()) -> boolean().
verify(RouteStreamReq, Signer) ->
    EncodedRouteStreamReq = iot_config_pb:encode_msg(
        RouteStreamReq#iot_config_route_stream_req_v1_pb{
            signature = <<>>
        },
        iot_config_route_stream_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedRouteStreamReq,
        ?MODULE:signature(RouteStreamReq),
        libp2p_crypto:bin_to_pubkey(Signer)
    ).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

timestamp_test() ->
    Timestamp = erlang:system_time(millisecond),
    ?assert(Timestamp =< ?MODULE:timestamp(?MODULE:new())),
    ok.

signature_test() ->
    ?assertEqual(
        <<>>,
        ?MODULE:signature(?MODULE:new())
    ),
    ok.

sign_verify_test() ->
    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Signer = libp2p_crypto:pubkey_to_bin(PubKey),
    RouteStreamReq = ?MODULE:new(),

    SignedRouteStreamReq = ?MODULE:sign(RouteStreamReq, SigFun),

    ?assert(?MODULE:verify(SignedRouteStreamReq, Signer)),
    ok.

-endif.
