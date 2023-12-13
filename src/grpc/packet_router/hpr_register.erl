-module(hpr_register).

-include("../autogen/packet_router_pb.hrl").

-export([
    timestamp/1,
    gateway/1,
    signature/1,
    session_capable/1,
    packet_ack_interval/1,
    verify/1
]).

-ifdef(TEST).

-export([
    test_new/1,
    sign/2
]).

-endif.

-type register() :: #packet_router_register_v1_pb{}.

-export_type([register/0]).

-spec timestamp(Reg :: register()) -> non_neg_integer().
timestamp(Reg) ->
    Reg#packet_router_register_v1_pb.timestamp.

-spec gateway(Reg :: register()) -> binary().
gateway(Reg) ->
    Reg#packet_router_register_v1_pb.gateway.

-spec signature(Reg :: register()) -> binary().
signature(Reg) ->
    Reg#packet_router_register_v1_pb.signature.

-spec session_capable(Reg :: register()) -> boolean().
session_capable(Reg) ->
    Reg#packet_router_register_v1_pb.session_capable.

-spec packet_ack_interval(Reg :: register()) -> non_neg_integer().
packet_ack_interval(Reg) ->
    Reg#packet_router_register_v1_pb.packet_ack_interval.

-spec verify(Reg :: register()) -> boolean().
verify(Reg) ->
    try
        BaseReg = Reg#packet_router_register_v1_pb{signature = <<>>},
        EncodedReg = packet_router_pb:encode_msg(BaseReg),
        Signature = ?MODULE:signature(Reg),
        PubKeyBin = ?MODULE:gateway(Reg),
        PubKey = libp2p_crypto:bin_to_pubkey(PubKeyBin),
        libp2p_crypto:verify(EncodedReg, Signature, PubKey)
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

-spec test_new(Gateway :: binary()) -> register().
test_new(Gateway) when is_binary(Gateway) ->
    #packet_router_register_v1_pb{
        timestamp = erlang:system_time(millisecond),
        gateway = Gateway
    };
test_new(Map) when is_map(Map) ->
    #packet_router_register_v1_pb{
        timestamp = erlang:system_time(millisecond),
        gateway = maps:get(gateway, Map),
        session_capable = maps:get(session_capable, Map),
        packet_ack_interval = maps:get(packet_ack_interval, Map, 0)
    }.

-spec sign(Reg :: register(), SigFun :: fun()) -> register().
sign(Reg, SigFun) ->
    RegEncoded = packet_router_pb:encode_msg(Reg#packet_router_register_v1_pb{
        signature = <<>>
    }),
    Reg#packet_router_register_v1_pb{
        signature = SigFun(RegEncoded)
    }.

-endif.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

new_test() ->
    Reg = ?MODULE:test_new(<<"gateway">>),
    ?assertEqual(<<"gateway">>, Reg#packet_router_register_v1_pb.gateway),
    ?assert(erlang:is_integer(Reg#packet_router_register_v1_pb.timestamp)),
    ?assertNot(Reg#packet_router_register_v1_pb.session_capable),
    ok.

timestamp_test() ->
    Reg = ?MODULE:test_new(<<"gateway">>),
    ?assert(erlang:is_integer(?MODULE:timestamp(Reg))),
    ok.

gateway_test() ->
    Reg = ?MODULE:test_new(<<"gateway">>),
    ?assertEqual(<<"gateway">>, ?MODULE:gateway(Reg)),
    ok.

signature_test() ->
    Reg = ?MODULE:test_new(<<"gateway">>),
    ?assertEqual(<<>>, ?MODULE:signature(Reg)),
    ok.

session_capable_test() ->
    Reg = ?MODULE:test_new(<<"gateway">>),
    ?assertEqual(false, ?MODULE:session_capable(Reg)),
    ok.

verify_test() ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),
    Reg = ?MODULE:test_new(Gateway),
    RegSigned = ?MODULE:sign(Reg, SigFun),
    ?assert(verify(RegSigned)),
    ok.

-endif.
