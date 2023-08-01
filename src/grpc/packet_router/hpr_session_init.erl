-module(hpr_session_init).

-include("../autogen/packet_router_pb.hrl").

-export([
    gateway/1,
    nonce/1,
    session_key/1,
    signature/1,
    verify/1
]).

-ifdef(TEST).

-export([
    test_new/3,
    sign/2
]).

-endif.

-type session() :: #packet_router_session_init_v1_pb{}.

-spec gateway(Session :: session()) -> binary().
gateway(Session) ->
    Session#packet_router_session_init_v1_pb.gateway.

-spec nonce(Session :: session()) -> binary().
nonce(Session) ->
    Session#packet_router_session_init_v1_pb.nonce.

-spec session_key(Session :: session()) -> binary().
session_key(Session) ->
    Session#packet_router_session_init_v1_pb.session_key.

-spec signature(Session :: session()) -> binary().
signature(Session) ->
    Session#packet_router_session_init_v1_pb.signature.

-spec verify(Session :: session()) -> boolean().
verify(Session) ->
    try
        BaseSes = Session#packet_router_session_init_v1_pb{signature = <<>>},
        EncodedSes = packet_router_pb:encode_msg(BaseSes),
        Signature = ?MODULE:signature(Session),
        PubKeyBin = ?MODULE:gateway(Session),
        PubKey = libp2p_crypto:bin_to_pubkey(PubKeyBin),
        libp2p_crypto:verify(EncodedSes, Signature, PubKey)
    of
        Bool -> Bool
    catch
        _E:_R ->
            false
    end.

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec test_new(Gateway :: binary(), Nonce :: binary(), SessionKey :: binary()) -> session().
test_new(Gateway, Nonce, SessionKey) ->
    #packet_router_session_init_v1_pb{
        gateway = Gateway,
        nonce = Nonce,
        session_key = SessionKey
    }.

-spec sign(Ses :: session(), SigFun :: fun()) -> session().
sign(Ses, SigFun) ->
    SesEncoded = packet_router_pb:encode_msg(Ses#packet_router_session_init_v1_pb{
        signature = <<>>
    }),
    Ses#packet_router_session_init_v1_pb{
        signature = SigFun(SesEncoded)
    }.

-endif.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

new_test() ->
    Ses = ?MODULE:test_new(<<"gateway">>, <<"nonce">>, <<"session_key">>),
    ?assertEqual(<<"gateway">>, Ses#packet_router_session_init_v1_pb.gateway),
    ?assertEqual(<<"session_key">>, Ses#packet_router_session_init_v1_pb.session_key),
    ?assertEqual(<<"nonce">>, Ses#packet_router_session_init_v1_pb.nonce),
    ok.

gateway_test() ->
    Ses = ?MODULE:test_new(<<"gateway">>, <<"nonce">>, <<"session_key">>),
    ?assertEqual(<<"gateway">>, ?MODULE:gateway(Ses)),
    ok.

signature_test() ->
    Ses = ?MODULE:test_new(<<"gateway">>, <<"nonce">>, <<"session_key">>),
    ?assertEqual(<<>>, ?MODULE:signature(Ses)),
    ok.

common() ->
    #{secret := GwPrivKey, public := GwPubKey} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := SessPrivKey, public := SessPubKey} = libp2p_crypto:generate_keys(ed25519),
    GwSigFun = libp2p_crypto:mk_sig_fun(GwPrivKey),
    SesSigFun = libp2p_crypto:mk_sig_fun(SessPrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(GwPubKey),
    SessionKey = libp2p_crypto:pubkey_to_bin(SessPubKey),
    Nonce = crypto:strong_rand_bytes(16),
    {Gateway, GwSigFun, SessionKey, SesSigFun, Nonce}.

verify_test() ->
    {Gateway, GwSigFun, SessionKey, _SesSigFun, Nonce} = common(),
    Ses = ?MODULE:test_new(Gateway, SessionKey, Nonce),
    SesSigned = ?MODULE:sign(Ses, GwSigFun),
    ?assert(verify(SesSigned)),
    ok.

verify_random_fail_test() ->
    {Gateway, _GwSigFun, SessionKey, _SesSigFun, Nonce} = common(),
    Ses = ?MODULE:test_new(Gateway, SessionKey, Nonce),
    RandomSig = fun(_Message) -> crypto:strong_rand_bytes(65) end,
    SesBadlySigned = ?MODULE:sign(Ses, RandomSig),
    ?assertEqual(verify(SesBadlySigned), false),
    ok.

verify_wrong_key_fail_test() ->
    %% Sign with session key, not gateway key, and verify that verify
    %% fails.
    {Gateway, _GwSigFun, SessionKey, SesSigFun, Nonce} = common(),
    Ses = ?MODULE:test_new(Gateway, SessionKey, Nonce),
    SesBadlySigned = ?MODULE:sign(Ses, SesSigFun),
    ?assertEqual(verify(SesBadlySigned), false),
    ok.

-endif.
