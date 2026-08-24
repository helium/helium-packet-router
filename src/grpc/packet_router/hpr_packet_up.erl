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
    net_id/1,
    md/1, md/2
]).

-ifdef(TEST).

-export([
    test_new/1,
    sign/2
]).

-endif.

%% lager's own DEBUG mask, from lager.hrl. Duplicated rather than including
%% lager's header: this is the literal the lager parse transform bakes into every
%% lager:debug/N call site, so it is fixed for a pinned lager.
-define(LAGER_DEBUG_MASK, 128).

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

-spec net_id(Packet :: packet()) -> {ok, lora_subnet:net_id()} | {error, any()}.
net_id(Packet) ->
    case ?MODULE:payload(Packet) of
        <<?JOIN_REQUEST:3, _:5, _AppEUI:64/little-unsigned-integer,
            _DevEUI:64/little-unsigned-integer, _DevNonce:2/binary, _MIC:4/binary>> ->
            {error, join};
        (<<FType:3, _:5, DevAddr:32/little-unsigned-integer, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1,
            FOptsLen:4, _FCnt:16/little-unsigned-integer, _FOpts:FOptsLen/binary,
            PayloadAndMIC/binary>>) when
            (FType == ?UNCONFIRMED_UP orelse FType == ?CONFIRMED_UP) andalso
                %% MIC is 4 bytes, so the binary must be at least that long
                erlang:byte_size(PayloadAndMIC) >= 4
        ->
            lora_subnet:parse_netid(DevAddr, little);
        _ ->
            {error, undefined}
    end.

-spec md(PacketUp :: packet()) -> ok.
md(PacketUp) ->
    ?MODULE:md(PacketUp, #{}).

-spec md(PacketUp :: packet(), Opts :: map()) -> ok.
md(PacketUp, Opts) ->
    PacketGateway = ?MODULE:gateway(PacketUp),
    StreamGateway = maps:get(gateway, Opts, undefined),
    StreamGatewayName = gateway_name(StreamGateway, Opts),
    %% The two are the same gateway on every packet we go on to route --
    %% hpr_routing:gateway_check/2 drops the packet otherwise -- so reuse the name
    %% the stream process already resolved instead of encoding it a second time.
    PacketGatewayName =
        case PacketGateway =:= StreamGateway of
            true -> StreamGatewayName;
            false -> hpr_utils:gateway_name(PacketGateway)
        end,
    PHash = hpr_utils:bin_to_hex_string(
        case maps:get(phash, Opts, undefined) of
            undefined -> ?MODULE:phash(PacketUp);
            Hash -> Hash
        end
    ),
    SessionKey =
        case maps:get(session_key, Opts, undefined) of
            undefined ->
                "undefined";
            K ->
                %% base58check is ~10us measured and nothing reads this field
                %% except a human in a debug line, so only pay for it when
                %% something is actually listening.
                case verbose_md() of
                    true -> libp2p_crypto:bin_to_b58(K);
                    false -> "elided"
                end
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
                {phash, PHash}
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
                {phash, PHash}
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
                {phash, PHash}
            ])
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec gateway_name(Gateway :: undefined | binary(), Opts :: map()) -> string().
gateway_name(undefined, _Opts) ->
    "undefined";
gateway_name(Gateway, Opts) ->
    case maps:get(gateway_name, Opts, undefined) of
        undefined -> hpr_utils:gateway_name(Gateway);
        Name -> Name
    end.

%% Is anything going to read debug-level metadata? This is the same condition
%% lager's parse transform wraps every lager:debug/N call in: debug enabled on the
%% default sink, or any trace installed. Checking traces matters -- hpr_utils:trace/2
%% installs one and filters on the metadata keys built here, so a trace must still
%% see complete metadata. lager_config:lookup/2 is a guarded persistent_term read,
%% so this is cheap and safe before lager has started (it returns the default).
-spec verbose_md() -> boolean().
verbose_md() ->
    case lager_config:get({lager_event, loglevel}, {0, []}) of
        {_Level, Traces} when Traces =/= [] -> true;
        {Level, _Traces} -> (Level band ?LAGER_DEBUG_MASK) =/= 0
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

md_test_() ->
    {foreach, fun() -> ok end, fun(ok) -> lager:md([]) end, [
        {"reuses the gateway name the stream resolved", ?_test(md_reuses_cached_gateway_name())},
        {"resolves the name itself when the gateways differ",
            ?_test(md_resolves_name_when_gateways_differ())},
        {"uses the phash handed to it", ?_test(md_uses_opts_phash())},
        {"elides the session key when nothing is listening", ?_test(md_elides_session_key())},
        {"keeps the session key while a trace is installed",
            ?_test(md_keeps_session_key_under_trace())}
    ]}.

md_test_gateway() ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    libp2p_crypto:pubkey_to_bin(PubKey).

md_reuses_cached_gateway_name() ->
    Gateway = md_test_gateway(),
    PacketUp = ?MODULE:test_new(#{gateway => Gateway}),
    %% A sentinel the real encoder would never produce, so this proves the cached
    %% value is used rather than recomputed.
    ok = ?MODULE:md(PacketUp, #{
        gateway => Gateway, gateway_name => "cached-name", stream_pid => self()
    }),
    MD = lager:md(),
    ?assertEqual("cached-name", proplists:get_value(stream_gateway, MD)),
    %% Same gateway, so the packet_gateway field reuses it too.
    ?assertEqual("cached-name", proplists:get_value(packet_gateway, MD)),
    ok.

md_resolves_name_when_gateways_differ() ->
    PacketGateway = md_test_gateway(),
    StreamGateway = md_test_gateway(),
    PacketUp = ?MODULE:test_new(#{gateway => PacketGateway}),
    ok = ?MODULE:md(PacketUp, #{
        gateway => StreamGateway, gateway_name => "cached-name", stream_pid => self()
    }),
    MD = lager:md(),
    ?assertEqual("cached-name", proplists:get_value(stream_gateway, MD)),
    %% Must not borrow the stream's name for a different gateway.
    ?assertEqual(
        hpr_utils:gateway_name(PacketGateway), proplists:get_value(packet_gateway, MD)
    ),
    ok.

md_uses_opts_phash() ->
    Gateway = md_test_gateway(),
    PacketUp = ?MODULE:test_new(#{gateway => Gateway}),
    Handed = crypto:hash(sha256, <<"something else">>),
    ok = ?MODULE:md(PacketUp, #{gateway => Gateway, phash => Handed, stream_pid => self()}),
    ?assertEqual(
        hpr_utils:bin_to_hex_string(Handed), proplists:get_value(phash, lager:md())
    ),
    %% Falls back to hashing the payload when it is not handed one.
    ok = ?MODULE:md(PacketUp, #{gateway => Gateway, stream_pid => self()}),
    ?assertEqual(
        hpr_utils:bin_to_hex_string(?MODULE:phash(PacketUp)),
        proplists:get_value(phash, lager:md())
    ),
    ok.

md_elides_session_key() ->
    Gateway = md_test_gateway(),
    #{public := SessionPubKey} = libp2p_crypto:generate_keys(ed25519),
    SessionKey = libp2p_crypto:pubkey_to_bin(SessionPubKey),
    PacketUp = ?MODULE:test_new(#{gateway => Gateway}),
    %% lager is not running, so lager_config returns the default: not verbose.
    ok = ?MODULE:md(PacketUp, #{
        gateway => Gateway, session_key => SessionKey, stream_pid => self()
    }),
    ?assertEqual("elided", proplists:get_value(session_key, lager:md())),
    ok.

md_keeps_session_key_under_trace() ->
    Gateway = md_test_gateway(),
    #{public := SessionPubKey} = libp2p_crypto:generate_keys(ed25519),
    SessionKey = libp2p_crypto:pubkey_to_bin(SessionPubKey),
    PacketUp = ?MODULE:test_new(#{gateway => Gateway}),
    {ok, _} = application:ensure_all_started(lager),
    try
        %% hpr_utils:trace/2 installs a lager trace and filters on the very
        %% metadata built here, so an installed trace must get the full value.
        {ok, Trace} = lager:trace_console([{module, ?MODULE}]),
        try
            ok = ?MODULE:md(PacketUp, #{
                gateway => Gateway, session_key => SessionKey, stream_pid => self()
            }),
            ?assertEqual(
                libp2p_crypto:bin_to_b58(SessionKey),
                proplists:get_value(session_key, lager:md())
            )
        after
            lager:stop_trace(Trace)
        end
    after
        application:stop(lager)
    end,
    ok.

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
