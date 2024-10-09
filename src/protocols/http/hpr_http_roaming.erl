%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs
%%% @doc
%%%
%%% @end
%%% Created : 17. Sep 2022 3:40 PM
%%%-------------------------------------------------------------------
-module(hpr_http_roaming).
-author("jonathanruttenberg").

%% Uplinking
-export([
    make_uplink_payload/6,
    select_best/1
]).

%% Downlinking
-export([
    handle_message/1,
    handle_prstart_ans/1,
    handle_xmitdata_req/1
]).

%% Tokens
-export([
    make_uplink_token/4,
    parse_uplink_token/1
]).

-export([
    auth_headers/1
]).

-export([new_packet/3]).

-define(NO_ROAMING_AGREEMENT, <<"NoRoamingAgreement">>).

%% Default Delays
-define(JOIN1_DELAY, 5_000_000).
-define(JOIN2_DELAY, 6_000_000).
-define(RX2_DELAY, 2_000_000).
-define(RX1_DELAY, 1_000_000).

%% Roaming MessageTypes
-type prstart_req() :: map().
-type prstart_ans() :: map().
-type xmitdata_req() :: map().
-type xmitdata_ans() :: map().

-type netid_num() :: non_neg_integer().
-type received_time() :: non_neg_integer().

-type downlink() :: {
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    PacketDown :: hpr_packet_down:packet()
}.

-type region() :: atom().
-type token() :: binary().

-define(TOKEN_SEP, <<"::">>).

-record(packet, {
    packet_up :: hpr_packet_up:packet(),
    received_time :: received_time(),
    gateway_location :: hpr_gateway_location:loc()
}).
-type packet() :: #packet{}.

-export_type([
    netid_num/0,
    packet/0,
    received_time/0,
    downlink/0
]).

%% ------------------------------------------------------------------
%% Uplink
%% ------------------------------------------------------------------

-spec new_packet(
    PacketUp :: hpr_packet_up:packet(),
    ReceivedTime :: received_time(),
    GatewayLocation :: hpr_gateway_location:loc()
) -> #packet{}.
new_packet(PacketUp, ReceivedTime, GatewayLocation) ->
    #packet{
        packet_up = PacketUp,
        received_time = ReceivedTime,
        gateway_location = GatewayLocation
    }.

-spec make_uplink_payload(
    NetID :: netid_num(),
    Uplinks :: list(packet()),
    TransactionID :: integer(),
    DedupWindowSize :: non_neg_integer(),
    RouteID :: hpr_route:id(),
    ReceiverNSID :: binary()
) -> prstart_req().
make_uplink_payload(
    NetID,
    Uplinks,
    TransactionID,
    DedupWindowSize,
    RouteID,
    _ReceiverNSID
) ->
    #packet{
        packet_up = PacketUp,
        received_time = ReceivedTime
    } = select_best(Uplinks),
    Payload = hpr_packet_up:payload(PacketUp),
    PacketTime = hpr_packet_up:timestamp(PacketUp),

    PubKeyBin = hpr_packet_up:gateway(PacketUp),
    Region = hpr_packet_up:region(PacketUp),
    DataRate = hpr_packet_up:datarate(PacketUp),
    Frequency = hpr_packet_up:frequency_mhz(PacketUp),

    {RoutingKey, RoutingValue} = routing_key_and_value(PacketUp),

    Token = make_uplink_token(PubKeyBin, Region, PacketTime, RouteID),

    VersionBase = #{
        'ProtocolVersion' => <<"1.0">>,
        'DedupWindowSize' => DedupWindowSize
    },

    VersionBase#{
        'SenderID' => <<"0xC00053">>,
        'ReceiverID' => hpr_http_roaming_utils:hexstring(NetID),
        'TransactionID' => TransactionID,
        'MessageType' => <<"PRStartReq">>,
        'PHYPayload' => hpr_http_roaming_utils:binary_to_hexstring(Payload),
        'ULMetaData' => #{
            RoutingKey => RoutingValue,
            'DataRate' => hpr_lorawan:datarate_to_index(Region, DataRate),
            'ULFreq' => Frequency,
            'RecvTime' => hpr_http_roaming_utils:format_time(ReceivedTime),
            'RFRegion' => Region,
            'FNSULToken' => Token,
            'GWCnt' => erlang:length(Uplinks),
            'GWInfo' => lists:map(fun gw_info/1, Uplinks)
        }
    }.

-spec routing_key_and_value(PacketUp :: hpr_packet_up:packet()) -> {atom(), binary()}.
routing_key_and_value(PacketUp) ->
    PacketType = hpr_packet_up:type(PacketUp),
    {RoutingKey, RoutingValue} =
        case PacketType of
            {join_req, {_AppEUI, DevEUI}} ->
                {'DevEUI', encode_deveui(DevEUI)};
            {uplink, {_Type, DevAddr}} ->
                {'DevAddr', encode_devaddr(DevAddr)}
        end,
    {RoutingKey, RoutingValue}.

%% ------------------------------------------------------------------
%% Downlink
%% ------------------------------------------------------------------

-spec handle_message(prstart_ans() | xmitdata_req()) ->
    ok
    | {downlink, xmitdata_ans(), downlink(), RouteID :: hpr_route:id()}
    | {join_accept, downlink()}
    | {error, any()}.
handle_message(#{<<"MessageType">> := MT} = M) ->
    case MT of
        <<"PRStartAns">> ->
            handle_prstart_ans(M);
        <<"XmitDataReq">> ->
            handle_xmitdata_req(M);
        <<"ErrorNotif">> ->
            lager:warning("sent bad roaming message message: ~p", [M]),
            ok;
        _Err ->
            throw({bad_message, M})
    end.

-spec handle_prstart_ans(prstart_ans()) ->
    ok | {join_accept, downlink()} | {error, any()}.
handle_prstart_ans(
    #{
        <<"Result">> := #{<<"ResultCode">> := <<"Success">>},
        <<"MessageType">> := <<"PRStartAns">>,
        <<"SenderID">> := _ReceiverID,
        <<"TransactionID">> := _TransactionID,

        <<"PHYPayload">> := Payload,
        <<"DevEUI">> := _DevEUI,

        <<"DLMetaData">> := #{
            <<"DLFreq1">> := FrequencyMhz,
            <<"DataRate1">> := DR,
            <<"FNSULToken">> := Token
        } = DLMeta
    }
) ->
    case parse_uplink_token(Token) of
        {error, _} = Err ->
            Err;
        {ok, PubKeyBin, Region, PacketTime, _RouteID} ->
            DownlinkPacket = hpr_packet_down:new_downlink(
                hpr_http_roaming_utils:hexstring_to_binary(Payload),
                hpr_http_roaming_utils:uint32(PacketTime + ?JOIN1_DELAY),
                FrequencyMhz * 1000000,
                hpr_lorawan:index_to_datarate(Region, DR),
                rx2_from_dlmetadata(DLMeta, PacketTime, Region, ?JOIN2_DELAY)
            ),

            {join_accept, {PubKeyBin, DownlinkPacket}}
    end;
handle_prstart_ans(
    #{
        <<"Result">> := #{<<"ResultCode">> := <<"Success">>},
        <<"MessageType">> := <<"PRStartAns">>,
        <<"SenderID">> := _ReceiverID,
        <<"TransactionID">> := _TransactionID,

        <<"PHYPayload">> := Payload,
        <<"DevEUI">> := _DevEUI,

        <<"DLMetaData">> := #{
            <<"DLFreq2">> := FrequencyMhz,
            <<"DataRate2">> := DR,
            <<"FNSULToken">> := Token
        }
    }
) ->
    case parse_uplink_token(Token) of
        {error, _} = Err ->
            Err;
        {ok, PubKeyBin, Region, PacketTime, _RouteID} ->
            DataRate = hpr_lorawan:index_to_datarate(Region, DR),
            DownlinkPacket = hpr_packet_down:new_downlink(
                hpr_http_roaming_utils:hexstring_to_binary(Payload),
                hpr_http_roaming_utils:uint32(PacketTime + ?JOIN2_DELAY),
                FrequencyMhz * 1000000,
                DataRate,
                undefined
            ),
            {join_accept, {PubKeyBin, DownlinkPacket}}
    end;
handle_prstart_ans(#{
    <<"MessageType">> := <<"PRStartAns">>,
    <<"Result">> := #{<<"ResultCode">> := <<"Success">>}
}) ->
    ok;
handle_prstart_ans(#{
    <<"MessageType">> := <<"PRStartAns">>,
    <<"Result">> := #{<<"ResultCode">> := ?NO_ROAMING_AGREEMENT},
    <<"SenderID">> := SenderID
}) ->
    NetID = hpr_http_roaming_utils:hexstring_to_int(SenderID),

    lager:debug("stop buying [net_id: ~p] [reason: no roaming agreement]", [NetID]),

    ok;
handle_prstart_ans(#{
    <<"MessageType">> := <<"PRStartAns">>,
    <<"Result">> := #{<<"ResultCode">> := ResultCode} = Result,
    <<"SenderID">> := SenderID
}) ->
    %% Catchall for properly formatted messages with results we don't yet support
    lager:debug(
        "[result: ~p] [sender: ~p] [description: ~p]",
        [ResultCode, SenderID, maps:get(<<"Description">>, Result, "No Description")]
    ),
    ok;
handle_prstart_ans(Res) ->
    lager:warning("unrecognized prstart_ans: ~p", [Res]),
    throw({bad_response, Res}).

-spec handle_xmitdata_req(xmitdata_req()) ->
    {downlink, xmitdata_ans(), downlink(), RouteID :: hpr_route:id()} | {error, any()}.
%% Class A ==========================================
handle_xmitdata_req(#{
    <<"MessageType">> := <<"XmitDataReq">>,
    <<"ProtocolVersion">> := ProtocolVersion,
    <<"TransactionID">> := IncomingTransactionID,
    <<"SenderID">> := SenderID,
    <<"PHYPayload">> := Payload,
    <<"DLMetaData">> := #{
        <<"ClassMode">> := <<"A">>,
        <<"FNSULToken">> := Token,
        <<"DataRate1">> := DR1,
        <<"DLFreq1">> := FrequencyMhz1,
        <<"RXDelay1">> := Delay0
    } = DLMeta
}) ->
    PayloadResponse = #{
        'ProtocolVersion' => ProtocolVersion,
        'MessageType' => <<"XmitDataAns">>,
        'ReceiverID' => SenderID,
        'SenderID' => <<"0xC00053">>,
        'Result' => #{'ResultCode' => <<"Success">>},
        'TransactionID' => IncomingTransactionID,
        'DLFreq1' => FrequencyMhz1
    },

    %% Make downlink packet
    case parse_uplink_token(Token) of
        {error, _} = Err ->
            Err;
        {ok, PubKeyBin, Region, PacketTime, RouteID} ->
            DataRate1 = hpr_lorawan:index_to_datarate(Region, DR1),
            Delay1 =
                case Delay0 of
                    N when N < 2 -> 1;
                    N -> N
                end,
            DownlinkPacket = hpr_packet_down:new_downlink(
                hpr_http_roaming_utils:hexstring_to_binary(Payload),
                hpr_http_roaming_utils:uint32(PacketTime + (Delay1 * ?RX1_DELAY)),
                FrequencyMhz1 * 1000000,
                DataRate1,
                rx2_from_dlmetadata(DLMeta, PacketTime, Region, ?RX2_DELAY)
            ),
            {downlink, PayloadResponse, {PubKeyBin, DownlinkPacket}, RouteID}
    end;
%% Class C ==========================================
handle_xmitdata_req(#{
    <<"MessageType">> := <<"XmitDataReq">>,
    <<"ProtocolVersion">> := ProtocolVersion,
    <<"TransactionID">> := IncomingTransactionID,
    <<"SenderID">> := SenderID,
    <<"PHYPayload">> := Payload,
    <<"DLMetaData">> := #{
        <<"ClassMode">> := DeviceClass,
        <<"FNSULToken">> := Token,
        <<"DLFreq2">> := FrequencyMhz,
        <<"DataRate2">> := DR,
        <<"RXDelay1">> := Delay0
    }
}) ->
    PayloadResponse = #{
        'ProtocolVersion' => ProtocolVersion,
        'MessageType' => <<"XmitDataAns">>,
        'ReceiverID' => SenderID,
        'SenderID' => <<"0xC00053">>,
        'Result' => #{'ResultCode' => <<"Success">>},
        'TransactionID' => IncomingTransactionID,
        'DLFreq2' => FrequencyMhz
    },

    case parse_uplink_token(Token) of
        {error, _} = Err ->
            Err;
        {ok, PubKeyBin, Region, PacketTime, RouteID} ->
            DataRate = hpr_lorawan:index_to_datarate(Region, DR),
            Delay1 =
                case Delay0 of
                    N when N < 2 -> 1;
                    N -> N
                end,

            DownlinkPacket =
                case DeviceClass of
                    <<"C">> ->
                        hpr_packet_down:new_imme_downlink(
                            hpr_http_roaming_utils:hexstring_to_binary(Payload),
                            FrequencyMhz * 1000000,
                            DataRate
                        );
                    <<"A">> ->
                        Timeout = PacketTime + (Delay1 * ?RX1_DELAY) + ?RX1_DELAY,
                        hpr_packet_down:new_downlink(
                            hpr_http_roaming_utils:hexstring_to_binary(Payload),
                            hpr_http_roaming_utils:uint32(Timeout),
                            FrequencyMhz * 1000000,
                            DataRate,
                            undefined
                        )
                end,
            {downlink, PayloadResponse, {PubKeyBin, DownlinkPacket}, RouteID}
    end.

-spec rx2_from_dlmetadata(
    DownlinkMetadata :: map(), non_neg_integer(), region(), non_neg_integer()
) ->
    undefined | packet_router_pb:window_v1_pb().
rx2_from_dlmetadata(
    #{
        <<"DataRate2">> := DR,
        <<"DLFreq2">> := FrequencyMhz
    },
    PacketTime,
    Region,
    Timeout
) ->
    try hpr_lorawan:index_to_datarate(Region, DR) of
        DataRate ->
            hpr_packet_down:window(
                hpr_http_roaming_utils:uint32(PacketTime + Timeout),
                FrequencyMhz * 1000000,
                DataRate
            )
    catch
        Err ->
            lager:warning("skipping rx2, bad dr_to_datar(~p, ~p) [err: ~p]", [Region, DR, Err]),
            undefined
    end;
rx2_from_dlmetadata(_, _, _, _) ->
    lager:debug("skipping rx2, no details"),
    undefined.

%% ------------------------------------------------------------------
%% Tokens
%% ------------------------------------------------------------------

-spec make_uplink_token(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Region :: region(),
    PacketTime :: non_neg_integer(),
    RouteID :: hpr_route:id()
) -> token().
make_uplink_token(PubKeyBin, Region, PacketTime, RouteID) ->
    Parts = [
        erlang:atom_to_binary(Region),
        erlang:integer_to_binary(PacketTime),
        RouteID,
        PubKeyBin
    ],
    Token0 = lists:join(?TOKEN_SEP, Parts),
    Token1 = erlang:iolist_to_binary(Token0),
    hpr_http_roaming_utils:binary_to_hexstring(Token1).

-spec parse_uplink_token(token()) ->
    {ok, libp2p_crypto:pubkey_bin(), region(), non_neg_integer(), RouteID :: hpr_route:id()}
    | {error, any()}.
parse_uplink_token(<<"0x", Token/binary>>) ->
    parse_uplink_token(Token);
parse_uplink_token(Token) ->
    Bin = binary:decode_hex(Token),
    case do_token_split(Bin, []) of
        [PubKeyBin, RegionBin, PacketTimeBin, RouteIDBin] ->
            Region = erlang:binary_to_existing_atom(RegionBin),
            PacketTime = erlang:binary_to_integer(PacketTimeBin),
            RouteID = erlang:binary_to_list(RouteIDBin),
            {ok, PubKeyBin, Region, PacketTime, RouteID};
        _ ->
            {error, {malformed_token, Token}}
    end.

%% We collect all the parts of the token, and know the rest is the pubkeybin.
%% Note the parts are re-ordered before being returned.
-spec do_token_split(binary(), list(binary())) -> list(binary()).
do_token_split(PubKeyBin, [RouteIDBin, PacketTimeBin, RegionBin]) ->
    [PubKeyBin, RegionBin, PacketTimeBin, RouteIDBin];
do_token_split(Bin, Parts) ->
    case binary:split(Bin, ?TOKEN_SEP) of
        [Part, Rest] ->
            do_token_split(Rest, [Part | Parts]);
        [Part] ->
            do_token_split(<<>>, [Part | Parts])
    end.

-spec auth_headers(Route :: hpr_route:route()) -> proplists:proplist().
auth_headers(Route) ->
    case hpr_route:http_auth_header(Route) of
        null ->
            [{<<"Content-Type">>, <<"application/json">>}];
        Auth ->
            [
                {<<"Content-Type">>, <<"application/json">>},
                {<<"Authorization">>, Auth}
            ]
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec select_best(list(packet())) -> packet().
select_best(Copies) ->
    [Best | _] = lists:sort(
        fun(#packet{packet_up = PacketUpA}, #packet{packet_up = PacketUpB}) ->
            RSSIA = hpr_packet_up:rssi(PacketUpA),
            RSSIB = hpr_packet_up:rssi(PacketUpB),
            RSSIA > RSSIB
        end,
        Copies
    ),
    Best.

-spec gw_info(packet()) -> map().
gw_info(#packet{packet_up = PacketUp, gateway_location = GatewayLocation}) ->
    PubKeyBin = hpr_packet_up:gateway(PacketUp),
    Region = hpr_packet_up:region(PacketUp),

    SNR = hpr_packet_up:snr(PacketUp),
    RSSI = hpr_packet_up:rssi(PacketUp),

    GW = #{
        'ID' => hpr_http_roaming_utils:binary_to_hexstring(hpr_utils:pubkeybin_to_mac(PubKeyBin)),
        'RFRegion' => Region,
        'RSSI' => RSSI,
        'SNR' => SNR,
        'DLAllowed' => true
    },
    case GatewayLocation of
        undefined ->
            GW;
        {_h3Index, Lat, Long} ->
            GW#{
                'Lat' => Lat,
                'Lon' => Long
            }
    end.

-spec encode_deveui(non_neg_integer()) -> binary().
encode_deveui(Num) ->
    hpr_http_roaming_utils:hexstring(Num, 16).

-spec encode_devaddr(non_neg_integer()) -> binary().
encode_devaddr(Num) ->
    hpr_http_roaming_utils:hexstring(Num, 8).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

encode_deveui_test() ->
    ?assertEqual(encode_deveui(0), <<"0x0000000000000000">>),
    ok.

encode_devaddr_test() ->
    ?assertEqual(encode_devaddr(0), <<"0x00000000">>),
    ok.

class_c_downlink_test() ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    Token = ?MODULE:make_uplink_token(
        PubKeyBin,
        'US915',
        erlang:system_time(millisecond),
        "route-id-1"
    ),

    Input = #{
        <<"ProtocolVersion">> => <<"1.0">>,
        <<"MessageType">> => <<"XmitDataReq">>,
        <<"ReceiverID">> => <<"0xc00053">>,
        <<"SenderID">> => <<"0x600013">>,
        <<"DLMetaData">> => #{
            <<"ClassMode">> => <<"C">>,
            <<"DLFreq2">> => 869.525,
            <<"DataRate2">> => 8,
            <<"DevEUI">> => <<"0x6081f9c306a777fd">>,
            <<"FNSULToken">> => Token,
            <<"HiPriorityFlag">> => false,
            <<"RXDelay1">> => 0
        },
        <<"PHYPayload">> => <<"0x60c04e26e000010001ae6cb4ddf7bc1997">>,
        <<"TransactionID">> => rand:uniform(16#FFFF_FFFF)
    },

    ?assertMatch({downlink, #{}, {PubKeyBin, _}, _Dest}, ?MODULE:handle_message(Input)),

    ok.

chirpstack_join_accept_test() ->
    TransactionID = 473719436,
    #{public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    Token = ?MODULE:make_uplink_token(
        PubKeyBin,
        'US915',
        erlang:system_time(millisecond),
        "route-id-1"
    ),

    A = #{
        <<"ProtocolVersion">> => <<"1.0">>,
        <<"MessageType">> => <<"PRStartAns">>,
        <<"ReceiverID">> => <<"C00053">>,
        <<"SenderID">> => <<"600013">>,
        <<"DLMetaData">> => #{
            <<"ClassMode">> => <<"A">>,
            <<"DLFreq1">> => 925.1,
            <<"DLFreq2">> => 923.3,
            <<"DataRate1">> => 10,
            <<"DataRate2">> => 8,
            <<"DevEUI">> => <<"6081f9c306a777fd">>,
            <<"FNSULToken">> => Token,
            <<"GWInfo">> => [#{}],
            <<"RXDelay1">> => 5
        },
        <<"DevAddr">> => <<"e0279ae8">>,
        <<"DevEUI">> => <<"6081f9c306a777fd">>,
        <<"FCntUp">> => 0,
        <<"FNwkSIntKey">> => #{
            <<"AESKey">> => <<"79dfbf88d0214e6f4b33360e987e9d50">>,
            <<"KEKLabel">> => <<>>
        },
        <<"Lifetime">> => 0,
        <<"PHYPayload">> =>
            <<"203851b55db2b1669f2c83a52b4b586d8ecca19880f22f6adda429dd719021160c">>,
        <<"Result">> => #{<<"Description">> => <<>>, <<"ResultCode">> => <<"Success">>},
        <<"TransactionID">> => TransactionID,
        <<"VSExtension">> => #{}
    },
    ?assertMatch({join_accept, {PubKeyBin, _}}, ?MODULE:handle_message(A)),

    ok.

rx1_timestamp_test() ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    PacketTime = 0,
    Token = ?MODULE:make_uplink_token(
        PubKeyBin,
        'US915',
        PacketTime,
        "route-id-1"
    ),

    MakeInput = fun(RXDelay) ->
        #{
            <<"ProtocolVersion">> => <<"1.0">>,
            <<"SenderID">> => <<"0x600013">>,
            <<"ReceiverID">> => <<"0xc00053">>,
            <<"TransactionID">> => rand:uniform(16#FFFF_FFFF),
            <<"MessageType">> => <<"XmitDataReq">>,
            <<"PHYPayload">> =>
                <<"0x60c04e26e020000000a754ba934840c3bc120989b532ee4613e06e3dd5d95d9d1ceb9e20b1f2">>,
            <<"DLMetaData">> => #{
                <<"DevEUI">> => <<"0x6081f9c306a777fd">>,

                <<"RXDelay1">> => RXDelay,
                <<"DLFreq1">> => 925.1,
                <<"DataRate1">> => 10,

                <<"FNSULToken">> => Token,

                <<"ClassMode">> => <<"A">>,
                <<"HiPriorityFlag">> => false
            }
        }
    end,

    lists:foreach(
        fun({RXDelay, ExpectedTimestamp}) ->
            Input = MakeInput(RXDelay),
            {downlink, _, {_, DownlinkPacket}, _} = ?MODULE:handle_xmitdata_req(Input),
            Timestamp = hpr_packet_down:rx1_timestamp(DownlinkPacket),
            ?assertEqual(ExpectedTimestamp, Timestamp)
        end,
        [
            {0, 1_000_000},
            {1, 1_000_000},
            {2, 2_000_000},
            {3, 3_000_000}
        ]
    ),

    ok.

rx1_downlink_test() ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    Payload = <<"0x60c04e26e020000000a754ba934840c3bc120989b532ee4613e06e3dd5d95d9d1ceb9e20b1f2">>,
    RXDelay = 2,
    FrequencyMhz = 925.1,
    DataRate = 10,

    Token = ?MODULE:make_uplink_token(
        PubKeyBin,
        'US915',
        erlang:system_time(millisecond),
        "route-id-1"
    ),

    Input = #{
        <<"ProtocolVersion">> => <<"1.0">>,
        <<"SenderID">> => <<"0x600013">>,
        <<"ReceiverID">> => <<"0xc00053">>,
        <<"TransactionID">> => rand:uniform(16#FFFF_FFFF),
        <<"MessageType">> => <<"XmitDataReq">>,
        <<"PHYPayload">> => Payload,
        <<"DLMetaData">> => #{
            <<"DevEUI">> => <<"0x6081f9c306a777fd">>,

            <<"RXDelay1">> => RXDelay,
            <<"DLFreq1">> => FrequencyMhz,
            <<"DataRate1">> => DataRate,

            <<"FNSULToken">> => Token,
            <<"ClassMode">> => <<"A">>,
            <<"HiPriorityFlag">> => false
        }
    },

    {downlink, _Output, {PubKeyBin, DownlinkPacket}, _Dest} = ?MODULE:handle_xmitdata_req(
        Input
    ),

    PayloadFromDownlinkPacket = hpr_packet_down:payload(DownlinkPacket),

    ?assertEqual(
        hpr_http_roaming_utils:hexstring_to_binary(Payload),
        PayloadFromDownlinkPacket
    ),
    FrequencyFromDownlinkPacket = hpr_packet_down:rx1_frequency(DownlinkPacket),
    ?assertMatch({A, B} when A == B, {925100000, FrequencyFromDownlinkPacket}),

    DatarateFromDownlinkPacket = hpr_packet_down:rx1_datarate(DownlinkPacket),
    ?assertEqual(
        hpr_lorawan:index_to_datarate('US915', DataRate),
        DatarateFromDownlinkPacket
    ),

    ok.

rx2_downlink_test() ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    Token = ?MODULE:make_uplink_token(
        PubKeyBin,
        'US915',
        erlang:system_time(millisecond),
        "route-id-1"
    ),

    Input = #{
        <<"ProtocolVersion">> => <<"1.0">>,
        <<"SenderID">> => <<"0x600013">>,
        <<"ReceiverID">> => <<"0xc00053">>,
        <<"TransactionID">> => rand:uniform(16#FFFF_FFFF),
        <<"MessageType">> => <<"XmitDataReq">>,
        <<"PHYPayload">> =>
            <<"0x60c04e26e020000000a754ba934840c3bc120989b532ee4613e06e3dd5d95d9d1ceb9e20b1f2">>,
        <<"DLMetaData">> => #{
            <<"DevEUI">> => <<"0x6081f9c306a777fd">>,

            <<"RXDelay1">> => 1,
            <<"DLFreq1">> => 925.1,
            <<"DataRate1">> => 10,

            <<"DLFreq2">> => 923.3,
            <<"DataRate2">> => 8,

            <<"FNSULToken">> => Token,
            <<"ClassMode">> => <<"A">>,
            <<"HiPriorityFlag">> => false
        }
    },

    {downlink, _Output, {PubKeyBin, DownlinkPacket}, _Dest} = ?MODULE:handle_xmitdata_req(
        Input
    ),

    DatarateFromDownlinkPacket =
        hpr_packet_down:rx2_datarate(DownlinkPacket),

    ?assertEqual(
        hpr_lorawan:index_to_datarate('US915', 8),
        DatarateFromDownlinkPacket
    ),

    FrequencyFromDownlinkPacket = hpr_packet_down:rx2_frequency(DownlinkPacket),
    ?assertMatch({A, B} when A == B, {923_300_000, FrequencyFromDownlinkPacket}),
    ok.

-endif.
