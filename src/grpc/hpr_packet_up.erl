-module(hpr_packet_up).

-include("../grpc/autogen/server/packet_router_pb.hrl").

-export([
    payload/1,
    timestamp/1,
    rssi/1,
    frequency_mhz/1,
    datarate/1,
    snr/1,
    region/1,
    hold_time/1,
    gateway/1,
    signature/1,
    phash/1,
    verify/1,
    encode/1,
    decode/1
]).

-ifdef(TEST).

-export([
    new/1,
    sign/2
]).

-endif.

-type packet() :: #packet_router_packet_up_v1_pb{}.

-export_type([packet/0]).

-spec payload(Packet :: packet()) -> binary().
payload(Packet) ->
    Packet#packet_router_packet_up_v1_pb.payload.

-spec timestamp(Packet :: packet()) -> non_neg_integer().
timestamp(Packet) ->
    Packet#packet_router_packet_up_v1_pb.timestamp.

-spec rssi(Packet :: packet()) -> float().
rssi(Packet) ->
    Packet#packet_router_packet_up_v1_pb.rssi.

-spec frequency_mhz(Packet :: packet()) -> float().
frequency_mhz(Packet) ->
    Packet#packet_router_packet_up_v1_pb.frequency_mhz.

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

-spec gateway(Packet :: packet()) -> binary().
gateway(Packet) ->
    Packet#packet_router_packet_up_v1_pb.gateway.

-spec signature(Packet :: packet()) -> binary().
signature(Packet) ->
    Packet#packet_router_packet_up_v1_pb.signature.

-spec phash(Packet :: packet()) -> binary().
phash(Packet) ->
    Payload = ?MODULE:payload(Packet),
    crypto:hash(sha256, Payload).

-spec verify(Packet :: packet()) -> boolean().
verify(Packet) ->
    try
        BasePacket = Packet#packet_router_packet_up_v1_pb{signature = <<>>},
        EncodedPacket = ?MODULE:encode(BasePacket),
        Signature = ?MODULE:signature(Packet),
        PubKeyBin = ?MODULE:gateway(Packet),
        PubKey = libp2p_crypto:bin_to_pubkey(PubKeyBin),
        libp2p_crypto:verify(EncodedPacket, Signature, PubKey)
    of
        Bool -> Bool
    catch
        _E:_R ->
            false
    end.

-spec encode(Packet :: packet()) -> binary().
encode(#packet_router_packet_up_v1_pb{} = Packet) ->
    packet_router_pb:encode_msg(Packet).

-spec decode(BinaryPacket :: binary()) -> packet().
decode(BinaryPacket) ->
    packet_router_pb:decode_msg(BinaryPacket, packet_router_packet_up_v1_pb).

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec new(Opts :: map()) -> packet().
new(Opts) ->
    #packet_router_packet_up_v1_pb{
        payload = maps:get(payload, Opts, <<"payload">>),
        timestamp = maps:get(timestamp, Opts, erlang:system_time(millisecond)),
        rssi = maps:get(rssi, Opts, -35.0),
        frequency_mhz = maps:get(frequency_mhz, Opts, 904.30),
        datarate = maps:get(datarate, Opts, "SF7BW125"),
        snr = maps:get(snr, Opts, 7.0),
        region = maps:get(region, Opts, 'US915'),
        hold_time = maps:get(hold_time, Opts, 0),
        gateway = maps:get(gateway, Opts, <<"gateway">>),
        signature = maps:get(gateway, Opts, <<"signature">>)
    }.

-spec sign(Packet :: packet(), SigFun :: fun()) -> packet().
sign(Packet, SigFun) ->
    PacketEncoded = ?MODULE:encode(Packet#packet_router_packet_up_v1_pb{
        signature = <<>>
    }),
    Packet#packet_router_packet_up_v1_pb{
        signature = SigFun(PacketEncoded)
    }.

-endif.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

payload_test() ->
    PacketUp = ?MODULE:new(#{}),
    ?assertEqual(<<"payload">>, payload(PacketUp)),
    ok.

timestamp_test() ->
    Now = erlang:system_time(millisecond),
    PacketUp = ?MODULE:new(#{timestamp => Now}),
    ?assertEqual(Now, timestamp(PacketUp)),
    ok.

rssi_test() ->
    PacketUp = ?MODULE:new(#{}),
    ?assertEqual(-35.0, rssi(PacketUp)),
    ok.

frequency_mhz_test() ->
    PacketUp = ?MODULE:new(#{}),
    ?assertEqual(904.30, frequency_mhz(PacketUp)),
    ok.

datarate_test() ->
    PacketUp = ?MODULE:new(#{}),
    ?assertEqual("SF7BW125", datarate(PacketUp)),
    ok.

snr_test() ->
    PacketUp = ?MODULE:new(#{}),
    ?assertEqual(7.0, snr(PacketUp)),
    ok.

region_test() ->
    PacketUp = ?MODULE:new(#{}),
    ?assertEqual('US915', region(PacketUp)),
    ok.

hold_time_test() ->
    PacketUp = ?MODULE:new(#{}),
    ?assertEqual(0, hold_time(PacketUp)),
    ok.

gateway_test() ->
    PacketUp = ?MODULE:new(#{}),
    ?assertEqual(<<"gateway">>, gateway(PacketUp)),
    ok.

signature_test() ->
    PacketUp = ?MODULE:new(#{}),
    ?assertEqual(<<"signature">>, signature(PacketUp)),
    ok.

verify_test() ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),
    PacketUp = ?MODULE:new(#{gateway => Gateway}),
    SignedPacketUp = ?MODULE:sign(PacketUp, SigFun),

    ?assert(verify(SignedPacketUp)),
    ok.

encode_decode_test() ->
    PacketUp = ?MODULE:new(#{frequency_mhz => 904.0}),
    ?assertEqual(PacketUp, decode(encode(PacketUp))),
    ok.

-endif.
