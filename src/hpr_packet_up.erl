-module(hpr_packet_up).

-include_lib("helium_proto/include/packet_router_pb.hrl").

-export([
    payload/1,
    timestamp/1,
    signal_strength/1,
    frequency/1,
    datarate/1,
    snr/1,
    region/1,
    hold_time/1,
    hotspot/1,
    signature/1,
    verify/1,
    encode/1,
    decode/1
]).

-type packet() :: #packet_router_packet_up_v1_pb{}.

-export_type([packet/0]).

-spec payload(Packet :: packet()) -> binary().
payload(Packet) ->
    Packet#packet_router_packet_up_v1_pb.payload.

-spec timestamp(Packet :: packet()) -> non_neg_integer().
timestamp(Packet) ->
    Packet#packet_router_packet_up_v1_pb.timestamp.

-spec signal_strength(Packet :: packet()) -> float().
signal_strength(Packet) ->
    Packet#packet_router_packet_up_v1_pb.signal_strength.

-spec frequency(Packet :: packet()) -> float().
frequency(Packet) ->
    Packet#packet_router_packet_up_v1_pb.frequency.

-spec datarate(Packet :: packet()) -> unicode:chardata().
datarate(Packet) ->
    Packet#packet_router_packet_up_v1_pb.datarate.

-spec snr(Packet :: packet()) -> float().
snr(Packet) ->
    Packet#packet_router_packet_up_v1_pb.snr.

-spec region(Packet :: packet()) -> atom().
region(Packet) ->
    Packet#packet_router_packet_up_v1_pb.region.

-spec hold_time(Packet :: packet()) -> non_neg_integer().
hold_time(Packet) ->
    Packet#packet_router_packet_up_v1_pb.hold_time.

-spec hotspot(Packet :: packet()) -> binary().
hotspot(Packet) ->
    Packet#packet_router_packet_up_v1_pb.hotspot.

-spec signature(Packet :: packet()) -> binary().
signature(Packet) ->
    Packet#packet_router_packet_up_v1_pb.signature.

-spec verify(Packet :: packet()) -> boolean().
verify(Packet) ->
    BasePacket = Packet#packet_router_packet_up_v1_pb{signature = <<>>},
    EncodedPacket = ?MODULE:encode(BasePacket),
    Signature = ?MODULE:signature(Packet),
    PubKeyBin = ?MODULE:hotspot(Packet),
    PubKey = libp2p_crypto:bin_to_pubkey(PubKeyBin),
    libp2p_crypto:verify(EncodedPacket, Signature, PubKey).

-spec encode(Packet :: packet()) -> binary().
encode(#packet_router_packet_up_v1_pb{} = Packet) ->
    packet_router_pb:encode_msg(Packet).

-spec decode(BinaryPacket :: binary()) -> packet().
decode(BinaryPacket) ->
    packet_router_pb:decode_msg(BinaryPacket, packet_router_packet_up_v1_pb).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

payload_test() ->
    PacketUp = new(),
    ?assertEqual(<<"payload">>, payload(PacketUp)),
    ok.

timestamp_test() ->
    PacketUp = new(),
    ?assertEqual(0, timestamp(PacketUp)),
    ok.

signal_strength_test() ->
    PacketUp = new(),
    ?assertEqual(1.0, signal_strength(PacketUp)),
    ok.

frequency_test() ->
    PacketUp = new(),
    ?assertEqual(2.0, frequency(PacketUp)),
    ok.

datarate_test() ->
    PacketUp = new(),
    ?assertEqual([], datarate(PacketUp)),
    ok.

snr_test() ->
    PacketUp = new(),
    ?assertEqual(3.0, snr(PacketUp)),
    ok.

region_test() ->
    PacketUp = new(),
    ?assertEqual('US915', region(PacketUp)),
    ok.

hold_time_test() ->
    PacketUp = new(),
    ?assertEqual(4, hold_time(PacketUp)),
    ok.

hotspot_test() ->
    PacketUp = new(),
    ?assertEqual(<<"hotspot">>, hotspot(PacketUp)),
    ok.

signature_test() ->
    PacketUp = new(),
    ?assertEqual(<<"signature">>, signature(PacketUp)),
    ok.

verify_test() ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Hotspot = libp2p_crypto:pubkey_to_bin(PubKey),
    PacketUp0 = new(),
    PacketUp1 = PacketUp0#packet_router_packet_up_v1_pb{hotspot = Hotspot},
    PacketUpEncoded = encode(PacketUp1#packet_router_packet_up_v1_pb{signature = <<>>}),
    PacketSigned = PacketUp1#packet_router_packet_up_v1_pb{signature = SigFun(PacketUpEncoded)},

    ?assert(verify(PacketSigned)),
    ok.

encode_devoce_test() ->
    PacketUp = new(),
    ?assertEqual(PacketUp, decode(encode(PacketUp))),
    ok.

new() ->
    #packet_router_packet_up_v1_pb{
        payload = <<"payload">>,
        timestamp = 0,
        signal_strength = 1.0,
        frequency = 2.0,
        datarate = [],
        snr = 3.0,
        region = 'US915',
        hold_time = 4,
        hotspot = <<"hotspot">>,
        signature = <<"signature">>
    }.

-endif.
