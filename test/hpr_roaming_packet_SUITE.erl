%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 06. Oct 2022 2:11 PM
%%%-------------------------------------------------------------------
-module(hpr_roaming_packet_SUITE).
-author("jonathanruttenberg").

-define(TRANSACTION_ETS, hpr_http_roaming_transaction_ets).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    http_sync_uplink_join_test/1
]).

%% Elli callback functions
-export([
    handle/2,
    handle_event/3
]).

%% downlink response ets
-export([
    insert_transaction_id/3,
    lookup_transaction_id/1
    , init_ets/0, frame_packet/5]).

-include_lib("eunit/include/eunit.hrl").

-include("lorawan_vars.hrl").
-include("../src/grpc/autogen/server/packet_router_pb.hrl").
-include("../src/grpc/autogen/server/config_pb.hrl").

%% NetIDs
-define(NET_ID_ACTILITY, 16#000002).
-define(NET_ID_ACTILITY_BIN, <<"0x000002">>).

-define(NET_ID_COMCAST, 16#000022).
-define(NET_ID_COMCAST_2, 16#60001C).
-define(NET_ID_EXPERIMENTAL, 16#000000).
-define(NET_ID_ORANGE, 16#00000F).
-define(NET_ID_TEKTELIC, 16#000037).

%% DevAddrs

% pp_utils:hex_to_binary(<<"04ABCDEF">>)
-define(DEVADDR_ACTILITY, <<4, 171, 205, 239>>).
-define(DEVADDR_ACTILITY_BIN, <<"0x04ABCDEF">>).

% pp_utils:hex_to_binary(<<"45000042">>)
-define(DEVADDR_COMCAST, <<69, 0, 0, 66>>).
% pp_utils:hex_to_binary(<<"0000041">>)
-define(DEVADDR_EXPERIMENTAL, <<0, 0, 0, 42>>).
%pp_utils:hex_to_binary(<<"1E123456">>)
-define(DEVADDR_ORANGE, <<30, 18, 52, 86>>).
% pp_utils:hex_to_binary(<<"6E123456">>)
-define(DEVADDR_TEKTELIC, <<110, 18, 52, 86>>).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

all() ->
    [].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

http_sync_uplink_join_test(_Config) ->
    %% One Gateway is going to be sending all the packets.
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    ok = start_uplink_listener(),

    %% NOTE: Leading 00 are important in this test.
    %% We want to make sure EUI are encoded with the correct number of bytes.
    DevEUI = <<"00BBCCDDEEFF0011">>,
    AppEUI = <<"1122334455667788">>,

    SendPacketFun = fun(DevAddr) ->
        RoutingInformationPB = hpr_roaming_utils:make_routing_information_pb(
            {
                eui,
                erlang:binary_to_integer(DevEUI, 16),
                erlang:binary_to_integer(AppEUI, 16)
            }
        ),
        GatewayTime = erlang:system_time(millisecond),
        PacketUp = frame_packet(
            ?UNCONFIRMED_UP,
            PubKeyBin,
            DevAddr,
            0,
            RoutingInformationPB,
            #{timestamp => GatewayTime}
        ),
        hpr_routing:handle_packet(PacketUp),
        %%    pp_sc_packet_handler:handle_packet(Packet, GatewayTime, self()),
        {ok, PacketUp, GatewayTime}
    end,

    %%  ok = pp_config:load_config([
    %%    #{
    %%      <<"name">> => <<"test">>,
    %%      <<"net_id">> => ?NET_ID_ACTILITY,
    %%      <<"configs">> => [
    %%        #{
    %%          <<"protocol">> => <<"http">>,
    %%          <<"http_endpoint">> => <<"http://127.0.0.1:3002/uplink">>,
    %%          <<"http_flow_type">> => <<"sync">>,
    %%          <<"joins">> => [
    %%            #{<<"dev_eui">> => DevEUI, <<"app_eui">> => AppEUI}
    %%          ],
    %%          <<"devaddrs">> => []
    %%        }
    %%      ]
    %%    }
    %%  ]),
    Route = #config_route_v1_pb{
        net_id = ?NET_ID_ACTILITY,
        server = #config_server_v1_pb{
            port = 3002,
            host = <<"127.0.0.1">>,
            protocol = #config_protocol_http_roaming_v1_pb{}
        },
        euis = [
            #config_eui_v1_pb{
                dev_eui = DevEUI,
                app_eui = AppEUI
            }
        ],
        devaddr_ranges = []
    },
    hpr_config:insert_route(Route),

    %% ===================================================================
    %% Done with setup.

    %% 1. Send a join uplink
    {ok, PacketUp, GatewayTime} = SendPacketFun(?DEVADDR_ACTILITY),
    Region = hpr_packet_up:region(PacketUp),
    PacketTime = hpr_packet_up:timestamp(PacketUp),

    %% 2. Expect a PRStartReq to the lns
    {
        ok,
        #{<<"TransactionID">> := TransactionID, <<"ULMetaData">> := #{<<"FNSULToken">> := Token}},
        _Request,
        {200, RespBody}
    } = pp_lns:http_rcv(
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => fun erlang:is_binary/1,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => hpr_roaming_utils:binary_to_hexstring(
                hpr_packet_up:payload(PacketUp)
            ),
            <<"ULMetaData">> => #{
                <<"DevEUI">> => <<"0x", DevEUI/binary>>,
                <<"DataRate">> => hpr_lorawan:datarate_to_index(
                    Region,
                    hpr_packet_up:datarate(PacketUp)
                ),
                <<"ULFreq">> => hpr_packet_up:frequency_mhz(PacketUp),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => hpr_roaming_utils:format_time(GatewayTime),

                <<"FNSULToken">> => fun erlang:is_binary/1,
                <<"GWCnt">> => 1,
                <<"GWInfo">> => [
                    #{
                        <<"RFRegion">> => erlang:atom_to_binary(Region),
                        <<"RSSI">> => erlang:trunc(
                            hpr_packet_up:rssi(PacketUp)
                        ),
                        <<"SNR">> => hpr_packet_up:snr(PacketUp),
                        <<"DLAllowed">> => true,
                        <<"ID">> => hpr_roaming_utils:binary_to_hexstring(
                            hpr_utils:pubkeybin_to_mac(PubKeyBin)
                        )
                    }
                ]
            }
        }
    ),

    ?assertMatch(
        {ok, TransactionID, 'US915', PacketTime, <<"http://127.0.0.1:3002/uplink">>, sync},
        hpr_roaming_protocol:parse_uplink_token(Token)
    ),

    %% 3. Expect a PRStartAns from the lns
    %%   - With DevEUI
    %%   - With PHyPayload
    case
        test_utils:match_map(
            #{
                <<"ProtocolVersion">> => <<"1.1">>,
                <<"TransactionID">> => TransactionID,
                <<"SenderID">> => ?NET_ID_ACTILITY_BIN,
                <<"ReceiverID">> => <<"0xC00053">>,
                <<"MessageType">> => <<"PRStartAns">>,
                <<"Result">> => #{
                    <<"ResultCode">> => <<"Success">>
                },
                <<"PHYPayload">> => hpr_roaming_utils:binary_to_hexstring(
                    <<"join_accept_payload">>
                ),
                <<"DevEUI">> => <<"0x", DevEUI/binary>>,
                <<"DLMetaData">> => #{
                    <<"DLFreq1">> => hpr_packet_up:frequency_mhz(PacketUp),
                    <<"FNSULToken">> => Token,
                    <<"Lifetime">> => 0,
                    <<"DataRate1">> => fun erlang:is_integer/1
                }
            },
            RespBody
        )
    of
        true -> ok;
        {false, Reason} -> ct:fail({http_response, Reason})
    end,

    %% 4. Expect downlink queued for gateway
    ok = gateway_expect_downlink(fun(_PacketDown) ->
        %%    ?assertEqual(27, hpr_packet_down:rssi(Downlink)),
        ok
    end),

    ok.

-spec insert_transaction_id(integer(), binary(), atom()) -> ok.
insert_transaction_id(TransactionID, Endpoint, FlowType) ->
    true = ets:insert(?TRANSACTION_ETS, {TransactionID, Endpoint, FlowType}),
    ok.

-spec lookup_transaction_id(integer()) -> {ok, binary(), atom()} | {error, routing_not_found}.
lookup_transaction_id(TransactionID) ->
    case ets:lookup(?TRANSACTION_ETS, TransactionID) of
        [] -> {error, routing_not_found};
        [{_, Endpoint, FlowType}] -> {ok, Endpoint, FlowType}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec init_ets() -> ok.
init_ets() ->
    ?TRANSACTION_ETS = ets:new(?TRANSACTION_ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    ok.

handle(Req, Args) ->
    Method =
        case elli_request:get_header(<<"Upgrade">>, Req) of
            <<"websocket">> ->
                websocket;
            _ ->
                elli_request:method(Req)
        end,
    ct:pal("~p", [{Method, elli_request:path(Req), Req, Args}]),
    handle(Method, elli_request:path(Req), Req, Args).

%% ------------------------------------------------------------------
%% NOTE: HPR starts up with a downlink listener
%% using `hpr_roaming_downlink' as the handler.
%%
%% Tests using the HTTP protocol start 2 Elli listeners.
%%
%% A forwarding listener :: (fns) Downlink Handler
%% A roaming listener    :: (sns) Uplink Handler as roaming partner
%%
%% The normal downlink listener is started, but ignored.
%%
%% The downlink handler in this file delegates to `hpr_roaming_downlink' while
%% sending extra messages to the test running so the production code doesn't
%% need to know about the tests.
%% ------------------------------------------------------------------
handle('POST', [<<"downlink">>], Req, Args) ->
    Forward = maps:get(forward, Args),
    Body = elli_request:body(Req),
    #{<<"TransactionID">> := TransactionID} = Decoded = jsx:decode(Body),

    FlowType =
        case lookup_transaction_id(TransactionID) of
            {ok, _Endpoint, FT} ->
                FT;
            {error, _} ->
                Forward ! {http_downlink_data_error, transaction_id_not_found}
        end,

    case FlowType of
        async ->
            Forward ! {http_downlink_data, Body},
            Res = hpr_roaming_downlink:handle(Req, Args),
            ct:pal("Downlink handler resp: ~p", [Res]),
            Forward ! {http_downlink_data_response, 200},
            {200, [], <<>>};
        sync ->
            ct:pal("sync handling downlink:~n~p", [Decoded]),
            Response = hpr_roaming_downlink:handle(Req, Args),

            %% ResponseBody = make_response_body(Decoded),
            %% Response = {200, [], jsx:encode(ResponseBody)},
            Forward ! {http_msg, Body, Req, Response},
            Response
    end;
handle('POST', [<<"uplink">>], Req, Args) ->
    Forward = maps:get(forward, Args),
    Body = elli_request:body(Req),
    #{<<"TransactionID">> := TransactionID} = jsx:decode(Body),

    {ok, _, FlowType} = lookup_transaction_id(TransactionID),

    ResponseBody =
        case maps:get(response, Args, undefined) of
            undefined ->
                make_response_body(jsx:decode(Body));
            Resp ->
                ct:pal("Using canned response: ~p", [Resp]),
                Resp
        end,

    case FlowType of
        async ->
            Response = {200, [], <<>>},
            Forward ! {http_uplink_data, Body},
            Forward ! {http_uplink_data_response, 200},
            spawn(fun() ->
                timer:sleep(250),
                Res = hackney:post(
                    <<"http://127.0.0.1:3003/downlink">>,
                    [{<<"Host">>, <<"localhost">>}],
                    jsx:encode(ResponseBody),
                    [with_body]
                ),
                ct:pal("Downlink Res: ~p", [Res])
            end),

            Response;
        sync ->
            Response = {200, [], jsx:encode(ResponseBody)},
            Forward ! {http_msg, Body, Req, Response},

            Response
    end.

handle_event(_Event, _Data, _Args) ->
    %% uncomment for Elli errors.
    ct:print("Elli Event (~p):~nData~n~p~nArgs~n~p", [_Event, _Data, _Args]),
    ok.

make_response_body(#{
    <<"ProtocolVersion">> := ProtocolVersion,
    <<"MessageType">> := <<"PRStartReq">>,
    <<"ReceiverID">> := ReceiverID,
    <<"SenderID">> := SenderID,
    <<"TransactionID">> := TransactionID,
    <<"ULMetaData">> := #{
        <<"ULFreq">> := Freq,
        <<"DevEUI">> := DevEUI,
        <<"FNSULToken">> := Token
    }
}) ->
    %% Join Response
    %% includes similar information from XmitDataReq
    #{
        'ProtocolVersion' => ProtocolVersion,
        'SenderID' => ReceiverID,
        'ReceiverID' => SenderID,
        'TransactionID' => TransactionID,
        'MessageType' => <<"PRStartAns">>,
        'Result' => #{'ResultCode' => <<"Success">>},
        'PHYPayload' => hpr_roaming_utils:binary_to_hexstring(<<"join_accept_payload">>),
        'DevEUI' => DevEUI,

        %% 11.3.1 Passive Roaming Start
        %% Step 6: stateless fNS operation
        'DLMetaData' => #{
            'DLFreq1' => Freq,
            'DataRate1' => 1,
            'FNSULToken' => Token,
            'Lifetime' => 0
        }
    };
make_response_body(#{
    <<"ProtocolVersion">> := ProtocolVersion,
    <<"ReceiverID">> := ReceiverID,
    <<"TransactionID">> := TransactionID
}) ->
    %% Ack to regular uplink
    #{
        'ProtocolVersion' => ProtocolVersion,
        'SenderID' => ReceiverID,
        'ReceiverID' => <<"0xC00053">>,
        'TransactionID' => TransactionID,
        'MessageType' => <<"PRStartAns">>,
        'Result' => #{'ResultCode' => <<"Success">>},
        %% 11.3.1 Passive Roaming Start
        %% Step 6: stateless fNS operation
        'Lifetime' => 0
    }.

start_uplink_listener() ->
    start_uplink_listener(#{callback_args => #{}}).

start_uplink_listener(Options) ->
    %% Uplinks we send to an LNS
    CallbackArgs = maps:get(callback_args, Options, #{}),
    {ok, _ElliPid} = elli:start_link([
        {callback, pp_lns},
        {callback_args, maps:merge(#{forward => self()}, CallbackArgs)},
        {port, maps:get(port, Options, 3002)},
        {min_acceptors, 1}
    ]),
    ok.

frame_packet(MType, PubKeyBin, DevAddr, FCnt, Options) ->
  <<DevNum:32/integer-unsigned>> = DevAddr,
  Routing = hpr_roaming_utils:make_routing_information_pb({devaddr, DevNum}),
  frame_packet(MType, PubKeyBin, DevAddr, FCnt, Routing, Options).

frame_packet(MType, PubKeyBin, DevAddr, FCnt, _Routing, Options) ->
    NwkSessionKey = <<81, 103, 129, 150, 35, 76, 17, 164, 210, 66, 210, 149, 120, 193, 251, 85>>,
    AppSessionKey = <<245, 16, 127, 141, 191, 84, 201, 16, 111, 172, 36, 152, 70, 228, 52, 95>>,
    Payload1 = frame_payload(MType, DevAddr, NwkSessionKey, AppSessionKey, FCnt),

    PacketUp = #packet_router_packet_up_v1_pb{
        timestamp = maps:get(timestamp, Options, erlang:system_time(millisecond)),
        payload = Payload1,
        frequency = 923.3,
        datarate = maps:get(datarate, Options, 'SF8BW125'),
        rssi = maps:get(rssi, Options, 0.0),
        snr = maps:get(snr, Options, 0.0),
        region = 'US915',
        gateway = PubKeyBin
    },
    PacketUp.

frame_payload(MType, DevAddr, NwkSessionKey, AppSessionKey, FCnt) ->
    MHDRRFU = 0,
    Major = 0,
    ADR = 0,
    ADRACKReq = 0,
    ACK = 0,
    RFU = 0,
    FOptsBin = <<>>,
    FOptsLen = byte_size(FOptsBin),
    <<Port:8/integer, Body/binary>> = <<1:8>>,
    Data = reverse(
        cipher(Body, AppSessionKey, MType band 1, DevAddr, FCnt)
    ),
    FCntSize = 16,
    Payload0 =
        <<MType:3, MHDRRFU:3, Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
            FOptsLen:4, FCnt:FCntSize/little-unsigned-integer, FOptsBin:FOptsLen/binary,
            Port:8/integer, Data/binary>>,
    B0 = b0(MType band 1, DevAddr, FCnt, erlang:byte_size(Payload0)),
    MIC = crypto:macN(cmac, aes_128_cbc, NwkSessionKey, <<B0/binary, Payload0/binary>>, 4),
    <<Payload0/binary, MIC:4/binary>>.

gateway_expect_downlink(ExpectFn) ->
    receive
        {send_response, PacketDown} ->
            ExpectFn(PacketDown)
    after 1000 -> ct:fail(gateway_expect_downlink_timeout)
    end.

%% ------------------------------------------------------------------
%% PP Utils
%% ------------------------------------------------------------------

-spec b0(integer(), binary(), integer(), integer()) -> binary().
b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0, 0, 0, 0, Dir, DevAddr:4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

%% ------------------------------------------------------------------
%% Lorawan Utils
%% ------------------------------------------------------------------

reverse(Bin) -> reverse(Bin, <<>>).

reverse(<<>>, Acc) -> Acc;
reverse(<<H:1/binary, Rest/binary>>, Acc) -> reverse(Rest, <<H/binary, Acc/binary>>).

cipher(Bin, Key, Dir, DevAddr, FCnt) ->
    cipher(Bin, Key, Dir, DevAddr, FCnt, 1, <<>>).

cipher(<<Block:16/binary, Rest/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:crypto_one_time(aes_128_ecb, Key, ai(Dir, DevAddr, FCnt, I), true),
    cipher(Rest, Key, Dir, DevAddr, FCnt, I + 1, <<(binxor(Block, Si, <<>>))/binary, Acc/binary>>);
cipher(<<>>, _Key, _Dir, _DevAddr, _FCnt, _I, Acc) ->
    Acc;
cipher(<<LastBlock/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:crypto_one_time(aes_128_ecb, Key, ai(Dir, DevAddr, FCnt, I), true),
    <<(binxor(LastBlock, binary:part(Si, 0, byte_size(LastBlock)), <<>>))/binary, Acc/binary>>.

-spec ai(integer(), binary(), integer(), integer()) -> binary().
ai(Dir, DevAddr, FCnt, I) ->
    <<16#01, 0, 0, 0, 0, Dir, DevAddr:4/binary, FCnt:32/little-unsigned-integer, 0, I>>.

-spec binxor(binary(), binary(), binary()) -> binary().
binxor(<<>>, <<>>, Acc) ->
    Acc;
binxor(<<A, RestA/binary>>, <<B, RestB/binary>>, Acc) ->
    binxor(RestA, RestB, <<(A bxor B), Acc/binary>>).
