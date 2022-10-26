%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 17. Sep 2022 3:40 PM
%%%-------------------------------------------------------------------
-module(hpr_http_roaming).
-author("jonathanruttenberg").

%% Uplinking
-export([
    make_uplink_payload/8,
    select_best/1,
    gateway_time/1,
    response_stream/1
]).

%% Downlinking
-export([
    handle_message/1,
    handle_prstart_ans/1,
    handle_xmitdata_req/1
]).

%% Tokens
-export([
    make_uplink_token/5,
    parse_uplink_token/1
]).

-export([new_packet/3]).

-define(NO_ROAMING_AGREEMENT, <<"NoRoamingAgreement">>).

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
-type gateway_time() :: non_neg_integer().

-type downlink() :: {
    ResponseStream :: hpr_router_stream_manager:gateway_stream(),
    Response :: any()
}.

-type transaction_id() :: integer().
-type region() :: atom().
-type token() :: binary().
-type dest_url() :: binary().
-type flow_type() :: sync | async.

-define(TOKEN_SEP, <<"::">>).

-record(packet, {
    packet_up :: hpr_packet_up:packet(),
    gateway_time :: gateway_time(),
    response_stream :: hpr_router_stream_manager:gateway_stream()
}).
-type packet() :: #packet{}.

-type downlink_packet() :: hpr_packet_down:packet().

-export_type([
    netid_num/0,
    packet/0,
    gateway_time/0,
    downlink/0,
    downlink_packet/0
]).

%% ------------------------------------------------------------------
%% Uplink
%% ------------------------------------------------------------------

-spec new_packet(
    PacketUp :: hpr_packet_up:packet(),
    GatewayTime :: gateway_time(),
    GatewayStream :: hpr_router_stream_manager:gateway_stream()
) -> #packet{}.
new_packet(PacketUp, GatewayTime, GatewayStream) ->
    #packet{
        packet_up = PacketUp,
        gateway_time = GatewayTime,
        response_stream = GatewayStream
    }.

-spec gateway_time(#packet{}) -> gateway_time().
gateway_time(#packet{gateway_time = GWTime}) ->
    GWTime.

-spec response_stream(#packet{}) -> hpr_router_stream_manager:gateway_stream().
response_stream(#packet{response_stream = ResponseStream}) ->
    ResponseStream.

-spec make_uplink_payload(
    NetID :: netid_num(),
    Uplinks :: list(packet()),
    TransactionID :: integer(),
    ProtocolVersion :: pv_1_0 | pv_1_1,
    DedupWindowSize :: non_neg_integer(),
    Destination :: binary(),
    FlowType :: sync | async,
    RoutingInfo :: hpr_routing:routing_info()
) -> prstart_req().
make_uplink_payload(
    NetID,
    Uplinks,
    TransactionID,
    ProtocolVersion,
    DedupWindowSize,
    Destination,
    FlowType,
    RoutingInfo
) ->
    #packet{
        packet_up = PacketUp,
        gateway_time = GatewayTime,
        response_stream = ResponseStream
    } = select_best(Uplinks),
    Payload = hpr_packet_up:payload(PacketUp),
    PacketTime = hpr_packet_up:timestamp(PacketUp),

    Region = hpr_packet_up:region(PacketUp),
    DataRate = hpr_packet_up:datarate(PacketUp),
    Frequency = hpr_packet_up:frequency_mhz(PacketUp),

    {RoutingKey, RoutingValue} =
        case RoutingInfo of
            {devaddr, DevAddr} -> {'DevAddr', encode_devaddr(DevAddr)};
            {eui, DevEUI, _AppEUI} -> {'DevEUI', encode_deveui(DevEUI)}
        end,

    Token = make_uplink_token(TransactionID, Region, PacketTime, Destination, FlowType),

    ok = hpr_http_roaming_utils:insert_handler(TransactionID, ResponseStream),

    VersionBase =
        case ProtocolVersion of
            pv_1_0 ->
                #{'ProtocolVersion' => <<"1.0">>};
            pv_1_1 ->
                #{
                    'ProtocolVersion' => <<"1.1">>,
                    'SenderNSID' => <<"">>,
                    'DedupWindowSize' => DedupWindowSize
                }
        end,

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
            'RecvTime' => hpr_http_roaming_utils:format_time(GatewayTime),
            'RFRegion' => Region,
            'FNSULToken' => Token,
            'GWCnt' => erlang:length(Uplinks),
            'GWInfo' => lists:map(fun gw_info/1, Uplinks)
        }
    }.

%% ------------------------------------------------------------------
%% Downlink
%% ------------------------------------------------------------------

-spec handle_message(prstart_ans() | xmitdata_req()) ->
    ok
    | {downlink, xmitdata_ans(), downlink(), {dest_url(), flow_type()}}
    | {join_accept, downlink()}
    | {error, any()}.
handle_message(#{<<"MessageType">> := MT} = M) ->
    case MT of
        <<"PRStartAns">> ->
            handle_prstart_ans(M);
        <<"XmitDataReq">> ->
            handle_xmitdata_req(M);
        _Err ->
            throw({bad_message, M})
    end.

-spec handle_prstart_ans(prstart_ans()) -> ok | {join_accept, downlink()} | {error, any()}.
handle_prstart_ans(#{
    <<"Result">> := #{<<"ResultCode">> := <<"Success">>},
    <<"MessageType">> := <<"PRStartAns">>,

    <<"PHYPayload">> := Payload,
    <<"DevEUI">> := _DevEUI,

    <<"DLMetaData">> := #{
        <<"DLFreq1">> := FrequencyMhz,
        <<"DataRate1">> := DR,
        <<"FNSULToken">> := Token
    } = DLMeta
}) ->
    {ok, TransactionID, Region, PacketTime, _, _} = parse_uplink_token(Token),

    DownlinkPacket = new_downlink(
        hpr_http_roaming_utils:hexstring_to_binary(Payload),
        hpr_http_roaming_utils:uint32(PacketTime + ?JOIN1_DELAY),
        FrequencyMhz * 1000000,
        hpr_lorawan:index_to_datarate(Region, DR),
        rx2_from_dlmetadata(DLMeta, PacketTime, Region, ?JOIN2_DELAY)
    ),

    case hpr_http_roaming_utils:lookup_handler(TransactionID) of
        {error, _} = Err -> Err;
        {ok, ResponseStream} -> {join_accept, {ResponseStream, DownlinkPacket}}
    end;
handle_prstart_ans(#{
    <<"Result">> := #{<<"ResultCode">> := <<"Success">>},
    <<"MessageType">> := <<"PRStartAns">>,

    <<"PHYPayload">> := Payload,
    <<"DevEUI">> := _DevEUI,

    <<"DLMetaData">> := #{
        <<"DLFreq2">> := FrequencyMhz,
        <<"DataRate2">> := DR,
        <<"FNSULToken">> := Token
    }
}) ->
    case parse_uplink_token(Token) of
        {error, _} = Err ->
            Err;
        {ok, TransactionID, Region, PacketTime, _, _} ->
            DataRate = hpr_lorawan:index_to_datarate(Region, DR),

            DownlinkPacket = new_downlink(
                hpr_http_roaming_utils:hexstring_to_binary(Payload),
                hpr_http_roaming_utils:uint32(PacketTime + ?JOIN2_DELAY),
                FrequencyMhz * 1000000,
                DataRate,
                undefined
            ),

            case hpr_http_roaming_utils:lookup_handler(TransactionID) of
                {error, _} = Err -> Err;
                {ok, ResponseStream} -> {join_accept, {ResponseStream, DownlinkPacket}}
            end
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

    lager:info("stop buying [net_id: ~p] [reason: no roaming agreement]", [NetID]),

    ok;
handle_prstart_ans(#{
    <<"MessageType">> := <<"PRStartAns">>,
    <<"Result">> := #{<<"ResultCode">> := ResultCode} = Result,
    <<"SenderID">> := SenderID
}) ->
    %% Catchall for properly formatted messages with results we don't yet support
    lager:info(
        "[result: ~p] [sender: ~p] [description: ~p]",
        [ResultCode, SenderID, maps:get(<<"Description">>, Result, "No Description")]
    ),
    ok;
handle_prstart_ans(Res) ->
    lager:error("unrecognized prstart_ans: ~p", [Res]),
    throw({bad_response, Res}).

-spec handle_xmitdata_req(xmitdata_req()) ->
    {downlink, xmitdata_ans(), downlink(), {dest_url(), flow_type()}} | {error, any()}.
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
        {ok, TransactionID, Region, PacketTime, DestURL, FlowType} ->
            DataRate1 = hpr_lorawan:index_to_datarate(Region, DR1),

            Delay1 =
                case Delay0 of
                    N when N < 2 -> 1;
                    N -> N
                end,

            DownlinkPacket = new_downlink(
                hpr_http_roaming_utils:hexstring_to_binary(Payload),
                hpr_http_roaming_utils:uint32(PacketTime + (Delay1 * ?RX1_DELAY)),
                FrequencyMhz1 * 1000000,
                DataRate1,
                rx2_from_dlmetadata(DLMeta, PacketTime, Region, ?RX2_DELAY)
            ),

            case hpr_http_roaming_utils:lookup_handler(TransactionID) of
                {error, _} = Err ->
                    Err;
                {ok, ResponseStream} ->
                    {downlink, PayloadResponse, {ResponseStream, DownlinkPacket},
                        {DestURL, FlowType}}
            end
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
        {ok, TransactionID, Region, PacketTime, DestURL, FlowType} ->
            DataRate = hpr_lorawan:index_to_datarate(Region, DR),

            Delay1 =
                case Delay0 of
                    N when N < 2 -> 1;
                    N -> N
                end,

            Timeout =
                case DeviceClass of
                    <<"C">> ->
                        immediate;
                    <<"A">> ->
                        hpr_http_roaming_utils:uint32(
                            PacketTime + (Delay1 * ?RX1_DELAY) + ?RX1_DELAY
                        )
                end,

            DownlinkPacket = new_downlink(
                hpr_http_roaming_utils:hexstring_to_binary(Payload),
                Timeout,
                FrequencyMhz * 1000000,
                DataRate,
                undefined
            ),

            case hpr_http_roaming_utils:lookup_handler(TransactionID) of
                {error, _} = Err ->
                    Err;
                {ok, ResponseStream} ->
                    {downlink, PayloadResponse, {ResponseStream, DownlinkPacket},
                        {DestURL, FlowType}}
            end
    end.

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
            window(
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

-spec make_uplink_token(transaction_id(), region(), non_neg_integer(), binary(), atom()) -> token().
make_uplink_token(TransactionID, Region, PacketTime, DestURL, FlowType) ->
    Parts = [
        erlang:integer_to_binary(TransactionID),
        erlang:atom_to_binary(Region),
        erlang:integer_to_binary(PacketTime),
        DestURL,
        erlang:atom_to_binary(FlowType)
    ],
    Token0 = lists:join(?TOKEN_SEP, Parts),
    Token1 = erlang:iolist_to_binary(Token0),
    hpr_http_roaming_utils:binary_to_hexstring(Token1).

-spec parse_uplink_token(token()) ->
    {ok, transaction_id(), region(), non_neg_integer(), dest_url(), flow_type()} | {error, any()}.
parse_uplink_token(<<"0x", Token/binary>>) ->
    parse_uplink_token(Token);
parse_uplink_token(Token) ->
    Bin = hpr_http_roaming_utils:hex_to_binary(Token),
    case binary:split(Bin, ?TOKEN_SEP, [global]) of
        [TransactionIDBin, RegionBin, PacketTimeBin, DestURLBin, FlowTypeBin] ->
            TransactionID = erlang:binary_to_integer(TransactionIDBin),
            Region = erlang:binary_to_existing_atom(RegionBin),
            PacketTime = erlang:binary_to_integer(PacketTimeBin),
            FlowType = erlang:binary_to_existing_atom(FlowTypeBin),
            {ok, TransactionID, Region, PacketTime, DestURLBin, FlowType};
        _ ->
            {error, malformed_token}
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
gw_info(#packet{packet_up = PacketUp}) ->
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
    GW.

-spec encode_deveui(non_neg_integer()) -> binary().
encode_deveui(Num) ->
    hpr_http_roaming_utils:hexstring(Num, 16).

-spec encode_devaddr(non_neg_integer()) -> binary().
encode_devaddr(Num) ->
    hpr_http_roaming_utils:hexstring(Num, 8).

-spec window(non_neg_integer(), 'undefined' | non_neg_integer(), atom()) ->
    packet_router_pb:window_v1_pb().
window(TS, FrequencyHz, DataRate) ->
    WindowMap = #{
        timestamp => TS,
        frequency => FrequencyHz,
        datarate => DataRate
    },
    hpr_packet_down:window(WindowMap).

-spec new_downlink(
    Payload :: binary(),
    Timestamp :: non_neg_integer(),
    Frequency :: atom() | number(),
    DataRate :: atom() | integer(),
    Rx2 :: packet_router_pb:window_v1_pb() | undefined
) -> downlink_packet().
new_downlink(Payload, Timestamp, FrequencyHz, DataRate, Rx2) ->
    PacketMap = #{
        payload => Payload,
        rx1 => #{
            timestamp => Timestamp,
            frequency => FrequencyHz,
            datarate => DataRate
        }
    },
    hpr_packet_down:to_record(PacketMap, Rx2).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

encode_deveui_test() ->
    ?assertEqual(encode_deveui(0), <<"0x0000000000000000">>),
    ok.

encode_devaddr_test() ->
    ?assertEqual(encode_devaddr(0), <<"0x00000000">>),
    ok.

-endif.
