-module(hpr_http_roaming_register).

-include("../autogen/downlink_pb.hrl").

-export([
    new/1,
    region/1,
    timestamp/1,
    signature/1,
    sign/2,
    verify/2
]).

-type http_roaming_register() :: #http_roaming_register_v1_pb{}.

-export_type([http_roaming_register/0]).

-spec new(Region :: atom()) -> http_roaming_register().
new(Region) ->
    #http_roaming_register_v1_pb{
        region = Region,
        timestamp = erlang:system_time(millisecond)
    }.

-spec region(HttpRoamingReg :: http_roaming_register()) -> atom().
region(HttpRoamingReg) ->
    HttpRoamingReg#http_roaming_register_v1_pb.region.

-spec timestamp(HttpRoamingReg :: http_roaming_register()) -> non_neg_integer().
timestamp(HttpRoamingReg) ->
    HttpRoamingReg#http_roaming_register_v1_pb.timestamp.

-spec signature(HttpRoamingReg :: http_roaming_register()) -> binary().
signature(HttpRoamingReg) ->
    HttpRoamingReg#http_roaming_register_v1_pb.signature.

-spec sign(HttpRoamingReg :: http_roaming_register(), SigFun :: fun()) ->
    http_roaming_register().
sign(HttpRoamingReg, SigFun) ->
    EncodedHttpRoamingReg = downlink_pb:encode_msg(
        HttpRoamingReg, http_roaming_register_v1_pb
    ),
    HttpRoamingReg#http_roaming_register_v1_pb{
        signature = SigFun(EncodedHttpRoamingReg)
    }.

-spec verify(HttpRoamingReg :: http_roaming_register(), PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    boolean().
verify(HttpRoamingReg, PubKeyBin) ->
    EncodedHttpRoamingReg = downlink_pb:encode_msg(
        HttpRoamingReg#http_roaming_register_v1_pb{
            signature = <<>>
        },
        http_roaming_register_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedHttpRoamingReg,
        ?MODULE:signature(HttpRoamingReg),
        libp2p_crypto:bin_to_pubkey(PubKeyBin)
    ).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

region_test() ->
    Region = 'EU868',
    ?assertEqual(
        Region,
        ?MODULE:region(?MODULE:new(Region))
    ),
    ok.

timestamp_test() ->
    Timestamp = erlang:system_time(millisecond),
    ?assert(Timestamp =< ?MODULE:timestamp(?MODULE:new('EU868'))),
    ok.

signature_test() ->
    ?assertEqual(
        <<>>,
        ?MODULE:signature(?MODULE:new('EU868'))
    ),
    ok.

sign_verify_test() ->
    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    HttpRoamingReg = ?MODULE:new('EU868'),

    SignedHttpRoamingReg = ?MODULE:sign(HttpRoamingReg, SigFun),

    ?assert(?MODULE:verify(SignedHttpRoamingReg, libp2p_crypto:pubkey_to_bin(PubKey))),
    ok.

-endif.
