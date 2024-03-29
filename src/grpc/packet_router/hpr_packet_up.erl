-module(hpr_packet_up).

-include("../autogen/packet_router_pb.hrl").

-export([
    payload/1,
    timestamp/1,
    rssi/1,
    frequency/1,
    frequency_mhz/1,
    datarate/1,
    snr/1,
    region/1,
    hold_time/1,
    gateway/1,
    signature/1,
    phash/1,
    verify/1, verify/2,
    encode/1,
    decode/1,
    type/1,
    md/1, md/2
]).

-ifdef(TEST).

-export([
    test_new/1,
    sign/2
]).

-endif.

-define(JOIN_REQUEST, 2#000).
-define(UNCONFIRMED_UP, 2#010).
-define(CONFIRMED_UP, 2#100).

-type packet() :: #packet_router_packet_up_v1_pb{}.
-type packet_map() :: #packet_router_packet_up_v1_pb{}.
-type packet_type() ::
    {join_req, {non_neg_integer(), non_neg_integer()}}
    | {uplink, {confirmed | unconfirmed, non_neg_integer()}}
    | {undefined, any()}.

-export_type([packet/0, packet_map/0, packet_type/0]).

-spec payload(Packet :: packet()) -> binary().
payload(Packet) ->
    Packet#packet_router_packet_up_v1_pb.payload.

-spec timestamp(Packet :: packet()) -> non_neg_integer().
timestamp(Packet) ->
    Packet#packet_router_packet_up_v1_pb.timestamp.

-spec rssi(Packet :: packet()) -> integer() | undefined.
rssi(Packet) ->
    Packet#packet_router_packet_up_v1_pb.rssi.

-spec frequency(Packet :: packet()) -> non_neg_integer() | undefined.
frequency(Packet) ->
    Packet#packet_router_packet_up_v1_pb.frequency.

-spec frequency_mhz(Packet :: packet()) -> float().
frequency_mhz(Packet) ->
    Mhz = Packet#packet_router_packet_up_v1_pb.frequency / 1000000,
    list_to_float(float_to_list(Mhz, [{decimals, 4}, compact])).

-spec datarate(Packet :: packet()) -> atom().
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

-spec verify(Packet :: packet(), SessionKey :: binary()) -> boolean().
verify(Packet, SessionKey) ->
    try
        BasePacket = Packet#packet_router_packet_up_v1_pb{signature = <<>>},
        EncodedPacket = ?MODULE:encode(BasePacket),
        Signature = ?MODULE:signature(Packet),
        PubKey = libp2p_crypto:bin_to_pubkey(SessionKey),
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

-spec type(Packet :: packet()) -> packet_type().
type(Packet) ->
    case ?MODULE:payload(Packet) of
        <<?JOIN_REQUEST:3, _:5, AppEUI:64/integer-unsigned-little,
            DevEUI:64/integer-unsigned-little, _DevNonce:2/binary, _MIC:4/binary>> ->
            {join_req, {AppEUI, DevEUI}};
        (<<FType:3, _:5, DevAddr:32/integer-unsigned-little, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1,
            FOptsLen:4, _FCnt:16/little-unsigned-integer, _FOpts:FOptsLen/binary,
            PayloadAndMIC/binary>>) when
            (FType == ?UNCONFIRMED_UP orelse FType == ?CONFIRMED_UP) andalso
                %% MIC is 4 bytes, so the binary must be at least that long
                erlang:byte_size(PayloadAndMIC) >= 4
        ->
            Body = binary:part(PayloadAndMIC, {0, byte_size(PayloadAndMIC) - 4}),
            FPort =
                case Body of
                    <<>> -> undefined;
                    <<Port:8, _Payload/binary>> -> Port
                end,
            case FPort of
                0 when FOptsLen /= 0 ->
                    {undefined, FType};
                _ ->
                    case FType of
                        ?CONFIRMED_UP -> {uplink, {confirmed, DevAddr}};
                        ?UNCONFIRMED_UP -> {uplink, {unconfirmed, DevAddr}}
                    end
            end;
        <<FType:3, _/bitstring>> ->
            {undefined, FType};
        _ ->
            {undefined, 0}
    end.

-spec md(PacketUp :: packet()) -> ok.
md(PacketUp) ->
    ?MODULE:md(PacketUp, #{}).

-spec md(PacketUp :: packet(), Opts :: map()) -> ok.
md(PacketUp, Opts) ->
    PacketGateway = ?MODULE:gateway(PacketUp),
    PacketGatewayName = hpr_utils:gateway_name(PacketGateway),
    SessionKey =
        case maps:get(session_key, Opts, undefined) of
            undefined -> "undefined";
            K -> libp2p_crypto:bin_to_b58(K)
        end,
    StreamGatewayName =
        case maps:get(gateway, Opts, undefined) of
            undefined -> "undefined";
            G -> hpr_utils:gateway_name(G)
        end,
    StreamPid =
        case maps:get(stream_pid, Opts, undefined) of
            undefined ->
                case hpr_packet_router_service:locate(PacketGateway) of
                    {ok, Pid} -> Pid;
                    {error, _} -> "undefined"
                end;
            Pid ->
                Pid
        end,
    case ?MODULE:type(PacketUp) of
        {undefined, FType} ->
            lager:md([
                {stream_pid, StreamPid},
                {stream_gateway, StreamGatewayName},
                {packet_gateway, PacketGatewayName},
                {session_key, SessionKey},
                {packet_type, FType},
                {phash, hpr_utils:bin_to_hex_string(?MODULE:phash(PacketUp))}
            ]);
        {join_req, {AppEUI, DevEUI}} ->
            lager:md([
                {stream_pid, StreamPid},
                {stream_gateway, StreamGatewayName},
                {packet_gateway, PacketGatewayName},
                {session_key, SessionKey},
                {app_eui, hpr_utils:int_to_hex_string(AppEUI)},
                {dev_eui, hpr_utils:int_to_hex_string(DevEUI)},
                {app_eui_int, AppEUI},
                {dev_eui_int, DevEUI},
                {packet_type, join_req},
                {phash, hpr_utils:bin_to_hex_string(?MODULE:phash(PacketUp))}
            ]);
        {uplink, {Type, DevAddr}} ->
            lager:md([
                {stream_pid, StreamPid},
                {stream_gateway, StreamGatewayName},
                {packet_gateway, PacketGatewayName},
                {session_key, SessionKey},
                {devaddr, hpr_utils:int_to_hex_string(DevAddr)},
                %% TODO: Add net id (warning they might not have one)
                {devaddr_int, DevAddr},
                {packet_type, Type},
                {phash, hpr_utils:bin_to_hex_string(?MODULE:phash(PacketUp))}
            ])
    end.

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec test_new(Opts :: map()) -> packet().
test_new(Opts) ->
    #packet_router_packet_up_v1_pb{
        payload = maps:get(payload, Opts, test_utils:join_payload(#{})),
        timestamp = maps:get(timestamp, Opts, erlang:system_time(millisecond)),
        rssi = maps:get(rssi, Opts, -40),
        frequency = maps:get(frequency, Opts, 904_300_000),
        datarate = maps:get(datarate, Opts, 'SF7BW125'),
        snr = maps:get(snr, Opts, 7.0),
        region = maps:get(region, Opts, 'US915'),
        hold_time = maps:get(hold_time, Opts, 0),
        gateway = maps:get(gateway, Opts, <<"gateway">>),
        signature = maps:get(signature, Opts, <<"signature">>)
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
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

payload_test() ->
    PacketUp = ?MODULE:test_new(#{payload => <<"payload">>}),
    ?assertEqual(<<"payload">>, payload(PacketUp)),
    ok.

timestamp_test() ->
    Now = erlang:system_time(millisecond),
    PacketUp = ?MODULE:test_new(#{timestamp => Now}),
    ?assertEqual(Now, timestamp(PacketUp)),
    ok.

rssi_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual(-40, rssi(PacketUp)),
    ok.

frequency_mhz_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual(904.30, frequency_mhz(PacketUp)),
    ok.

datarate_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual('SF7BW125', datarate(PacketUp)),
    ok.

snr_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual(7.0, snr(PacketUp)),
    ok.

region_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual('US915', region(PacketUp)),
    ok.

hold_time_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual(0, hold_time(PacketUp)),
    ok.

gateway_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual(<<"gateway">>, gateway(PacketUp)),
    ok.

signature_test() ->
    PacketUp = ?MODULE:test_new(#{}),
    ?assertEqual(<<"signature">>, signature(PacketUp)),
    ok.

verify_test() ->
    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ed25519),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),
    Gateway1 = libp2p_crypto:pubkey_to_bin(PubKey1),
    PacketUp1 = ?MODULE:test_new(#{gateway => Gateway1}),
    SignedPacketUp1 = ?MODULE:sign(PacketUp1, SigFun1),

    ?assert(verify(SignedPacketUp1)),

    #{secret := PrivKey2, public := PubKey2} = libp2p_crypto:generate_keys(ed25519),
    SigFun2 = libp2p_crypto:mk_sig_fun(PrivKey2),
    SessionKey = libp2p_crypto:pubkey_to_bin(PubKey2),
    SignedPacketUp2 = ?MODULE:sign(PacketUp1, SigFun2),
    ?assert(verify(SignedPacketUp2, SessionKey)),
    ok.

encode_decode_test() ->
    PacketUp = ?MODULE:test_new(#{frequency => 904_000_000}),
    ?assertEqual(PacketUp, decode(encode(PacketUp))),
    ok.

type_test() ->
    ?assertEqual(
        {join_req, {1, 1}},
        ?MODULE:type(
            ?MODULE:test_new(#{
                payload =>
                    <<
                        (?JOIN_REQUEST):3,
                        0:3,
                        1:2,
                        1:64/integer-unsigned-little,
                        1:64/integer-unsigned-little,
                        (crypto:strong_rand_bytes(2))/binary,
                        (crypto:strong_rand_bytes(4))/binary
                    >>
            })
        )
    ),
    UnconfirmedUp = ?UNCONFIRMED_UP,
    ?assertEqual(
        {uplink, {unconfirmed, 1}},
        ?MODULE:type(
            ?MODULE:test_new(#{
                payload =>
                    <<UnconfirmedUp:3, 0:3, 1:2, 16#00000001:32/integer-unsigned-little, 0:1, 0:1,
                        0:1, 0:1, 1:4, 2:16/little-unsigned-integer,
                        (crypto:strong_rand_bytes(1))/binary, 2:8/integer,
                        (crypto:strong_rand_bytes(20))/binary>>
            })
        )
    ),
    ConfirmedUp = ?CONFIRMED_UP,
    ?assertEqual(
        {uplink, {confirmed, 1}},
        ?MODULE:type(
            ?MODULE:test_new(#{
                payload =>
                    <<ConfirmedUp:3, 0:3, 1:2, 16#00000001:32/integer-unsigned-little, 0:1, 0:1,
                        0:1, 0:1, 1:4, 2:16/little-unsigned-integer,
                        (crypto:strong_rand_bytes(1))/binary, 2:8/integer,
                        (crypto:strong_rand_bytes(20))/binary>>
            })
        )
    ),
    ?assertEqual(
        {undefined, 7},
        ?MODULE:type(
            ?MODULE:test_new(#{payload => <<2#111:3, (crypto:strong_rand_bytes(20))/binary>>})
        )
    ),
    ?assertEqual({undefined, 0}, ?MODULE:type(?MODULE:test_new(#{payload => <<>>}))),
    ok.

-endif.
