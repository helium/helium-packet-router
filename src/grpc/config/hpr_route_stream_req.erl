-module(hpr_route_stream_req).

-include("../autogen/server/config_pb.hrl").

-export([
    new/2,
    pub_key/1,
    signature/1,
    timestamp/1,
    sign/2,
    verify/1,
    to_map/1
]).

-type route_stream_req() :: #config_route_stream_req_v1_pb{}.

-export_type([route_stream_req/0]).

-spec new(PubKeyBin :: binary(), Timestamp :: non_neg_integer()) -> route_stream_req().
new(PubKeyBin, Timestamp) ->
    #config_route_stream_req_v1_pb{
        pub_key = PubKeyBin,
        timestamp = Timestamp
    }.

-spec pub_key(RouteStreamReq :: route_stream_req()) -> binary().
pub_key(RouteStreamReq) ->
    RouteStreamReq#config_route_stream_req_v1_pb.pub_key.

-spec timestamp(RouteStreamReq :: route_stream_req()) -> non_neg_integer().
timestamp(RouteStreamReq) ->
    RouteStreamReq#config_route_stream_req_v1_pb.timestamp.

-spec signature(RouteStreamReq :: route_stream_req()) -> binary().
signature(RouteStreamReq) ->
    RouteStreamReq#config_route_stream_req_v1_pb.signature.

-spec sign(RouteStreamReq :: route_stream_req(), SigFun :: fun()) -> route_stream_req().
sign(RouteStreamReq, SigFun) ->
    EncodedRouteStreamReq = config_pb:encode_msg(RouteStreamReq, config_route_stream_req_v1_pb),
    RouteStreamReq#config_route_stream_req_v1_pb{signature = SigFun(EncodedRouteStreamReq)}.

-spec verify(RouteStreamReq :: route_stream_req()) -> boolean().
verify(RouteStreamReq) ->
    EncodedRouteStreamReq = config_pb:encode_msg(
        RouteStreamReq#config_route_stream_req_v1_pb{
            signature = <<>>
        },
        config_route_stream_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedRouteStreamReq,
        ?MODULE:signature(RouteStreamReq),
        libp2p_crypto:bin_to_pubkey(?MODULE:pub_key(RouteStreamReq))
    ).

-spec to_map(RouteStreamReq :: route_stream_req()) -> map().
to_map(RouteStreamReq) ->
    client_config_pb:decode_msg(
        config_pb:encode_msg(RouteStreamReq, config_route_stream_req_v1_pb),
        route_stream_req_v1_pb
    ).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

new_test() ->
    PubKeyBin = <<"PubKeyBin">>,
    Timestamp = erlang:system_time(millisecond),
    ?assertEqual(
        #config_route_stream_req_v1_pb{
            pub_key = PubKeyBin,
            timestamp = Timestamp
        },
        ?MODULE:new(PubKeyBin, Timestamp)
    ),
    ok.

pub_key_test() ->
    PubKeyBin = <<"PubKeyBin">>,
    Timestamp = erlang:system_time(millisecond),
    ?assertEqual(
        PubKeyBin,
        ?MODULE:pub_key(?MODULE:new(PubKeyBin, Timestamp))
    ),
    ok.

timestamp_test() ->
    PubKeyBin = <<"PubKeyBin">>,
    Timestamp = erlang:system_time(millisecond),
    ?assertEqual(
        Timestamp,
        ?MODULE:timestamp(?MODULE:new(PubKeyBin, Timestamp))
    ),
    ok.

signature_test() ->
    PubKeyBin = <<"PubKeyBin">>,
    Timestamp = erlang:system_time(millisecond),
    ?assertEqual(
        <<>>,
        ?MODULE:signature(?MODULE:new(PubKeyBin, Timestamp))
    ),
    ok.

sign_verify_test() ->
    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    Timestamp = erlang:system_time(millisecond),
    RouteStreamReq = ?MODULE:new(PubKeyBin, Timestamp),

    SignedRouteStreamReq = ?MODULE:sign(RouteStreamReq, SigFun),

    ?assert(?MODULE:verify(SignedRouteStreamReq)),
    ok.

to_map_test() ->
    PubKeyBin = <<"PubKeyBin">>,
    Timestamp = erlang:system_time(millisecond),
    Req = ?MODULE:new(PubKeyBin, Timestamp),
    ?assertEqual(
        #{
            pub_key => PubKeyBin,
            timestamp => Timestamp,
            signature => <<>>
        },
        ?MODULE:to_map(Req)
    ),
    ok.

-endif.
