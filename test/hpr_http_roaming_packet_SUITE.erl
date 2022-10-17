%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 06. Oct 2022 2:11 PM
%%%-------------------------------------------------------------------
-module(hpr_http_roaming_packet_SUITE).
-author("jonathanruttenberg").

-define(TRANSACTION_ETS, hpr_http_roaming_transaction_ets).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    http_sync_uplink_join_test/1,
    http_sync_downlink_test/1,
    http_async_uplink_join_test/1
]).

%% Elli callback functions
-export([
    handle/2,
    handle_event/3
]).

-export([
    http_rcv/1
]).

-include_lib("eunit/include/eunit.hrl").

-include("lorawan_vars.hrl").

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
    [
        http_sync_uplink_join_test,
        http_sync_downlink_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    ok = hpr_http_roaming_utils:init_ets(),
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
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    {ok, _Pid} = hpr_http_roaming_sup:start_link(),

    ok = start_uplink_listener(),

    DevEUIBin = <<"00BBCCDDEEFF0011">>,
    DevEUI = erlang:binary_to_integer(DevEUIBin, 16),
    AppEUI = erlang:binary_to_integer(<<"1122334455667788">>, 16),

    SendPacketFun = fun() ->
        GatewayTime = erlang:system_time(millisecond),
        PacketUp = test_utils:frame_packet_join(
            PubKeyBin,
            SigFun,
            DevEUI,
            AppEUI,
            #{timestamp => GatewayTime}
        ),

        ok = hpr_routing:handle_packet(PacketUp),
        {ok, PacketUp, GatewayTime}
    end,

    uplink_test_route(DevEUI, AppEUI, sync),

    lager:debug(
        [
            {devaddr, ets:tab2list(hpr_config_routes_by_devaddr)},
            {eui, ets:tab2list(hpr_config_routes_by_eui)}
        ],
        "config ets"
    ),

    %% ===================================================================
    %% Done with setup.

    %% 1. Send a join uplink
    {ok, PacketUp, GatewayTime} = SendPacketFun(),
    Region = hpr_packet_up:region(PacketUp),
    PacketTime = hpr_packet_up:timestamp(PacketUp),

    %% 2. Expect a PRStartReq to the lns
    {
        ok,
        #{<<"TransactionID">> := TransactionID, <<"ULMetaData">> := #{<<"FNSULToken">> := Token}},
        _Request,
        {200, RespBody}
    } = ?MODULE:http_rcv(
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => fun erlang:is_binary/1,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => hpr_http_roaming_utils:binary_to_hexstring(
                hpr_packet_up:payload(PacketUp)
            ),
            <<"ULMetaData">> => #{
                <<"DevEUI">> => <<"0x", DevEUIBin/binary>>,
                <<"DataRate">> => hpr_lorawan:datarate_to_index(
                    Region,
                    hpr_packet_up:datarate(PacketUp)
                ),
                <<"ULFreq">> => hpr_packet_up:frequency_mhz(PacketUp),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => hpr_http_roaming_utils:format_time(GatewayTime),

                <<"FNSULToken">> => fun erlang:is_binary/1,
                <<"GWCnt">> => 1,
                <<"GWInfo">> => [
                    #{
                        <<"RFRegion">> => erlang:atom_to_binary(Region),
                        <<"RSSI">> => hpr_packet_up:rssi(PacketUp),
                        <<"SNR">> => hpr_packet_up:snr(PacketUp),
                        <<"DLAllowed">> => true,
                        <<"ID">> => hpr_http_roaming_utils:binary_to_hexstring(
                            hpr_utils:pubkeybin_to_mac(PubKeyBin)
                        )
                    }
                ]
            }
        }
    ),

    ?assertMatch(
        {ok, TransactionID, 'US915', PacketTime, <<"127.0.0.1:3002/uplink">>, sync},
        hpr_http_roaming:parse_uplink_token(Token)
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
                <<"PHYPayload">> => hpr_http_roaming_utils:binary_to_hexstring(
                    <<"join_accept_payload">>
                ),
                <<"DevEUI">> => <<"0x", DevEUIBin/binary>>,
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

    %% 4. Expect downlink for gateway
    ok = gateway_expect_downlink(fun(PacketDown) ->
        ?assertEqual(
            true,
            hpr_packet_up:frequency_mhz(PacketUp) ==
                hpr_packet_down:rx1_frequency(PacketDown) / 1000000
        ),
        ok
    end),

    ok.

http_sync_downlink_test(_Config) ->
    ok = start_forwarder_listener(),

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    DownlinkPayload = <<"downlink_payload">>,
    DownlinkTimestamp = erlang:system_time(millisecond),
    DownlinkFreq = 915.0,
    DownlinkDatr = 'SF10BW125',
    TransactionID = 23,

    Token = hpr_http_roaming:make_uplink_token(
        TransactionID,
        'US915',
        DownlinkTimestamp,
        <<"http://127.0.0.1:3002/uplink">>,
        sync
    ),
    RXDelay = 1,

    DownlinkBody = #{
        'ProtocolVersion' => <<"1.1">>,
        'SenderID' => hpr_http_roaming_utils:binary_to_hexstring(?NET_ID_ACTILITY),
        'ReceiverID' => <<"0xC00053">>,
        'TransactionID' => TransactionID,
        'MessageType' => <<"XmitDataReq">>,
        'PHYPayload' => hpr_http_roaming_utils:binary_to_hexstring(DownlinkPayload),
        'DLMetaData' => #{
            'DevEUI' => <<"0xaabbffccfeeff001">>,
            'DLFreq1' => DownlinkFreq,
            'DataRate1' => 0,
            'RXDelay1' => RXDelay,
            'FNSULToken' => Token,
            'GWInfo' => [
                #{'ULToken' => libp2p_crypto:bin_to_b58(PubKeyBin)}
            ],
            'ClassMode' => <<"A">>,
            'HiPriorityFlag' => false
        }
    },

    %% NOTE: We need to insert the transaction and handler here because we're
    %% only simulating downlinks. In a normal flow, these details would be
    %% filled during the uplink process.
    %%    ok = pp_config:insert_transaction_id(TransactionID, <<"http://127.0.0.1:3002/uplink">>, sync),
    ok = hpr_http_roaming_utils:insert_handler(TransactionID, self()),

    downlink_test_route(),

    {ok, 200, _Headers, Resp} = hackney:post(
        <<"http://127.0.0.1:3003/downlink">>,
        [{<<"Host">>, <<"localhost">>}],
        jsx:encode(DownlinkBody),
        [with_body]
    ),

    case
        test_utils:match_map(
            #{
                <<"ProtocolVersion">> => <<"1.1">>,
                <<"TransactionID">> => TransactionID,
                <<"SenderID">> => <<"0xC00053">>,
                <<"ReceiverID">> => hpr_http_roaming_utils:binary_to_hexstring(?NET_ID_ACTILITY),
                <<"MessageType">> => <<"XmitDataAns">>,
                <<"Result">> => #{
                    <<"ResultCode">> => <<"Success">>
                },
                <<"DLFreq1">> => DownlinkFreq
            },
            jsx:decode(Resp)
        )
    of
        true -> ok;
        {false, Reason} -> ct:fail({http_response, Reason})
    end,

    ok = gateway_expect_downlink(fun(PacketDown) ->
        ?assertEqual(DownlinkPayload, hpr_packet_down:payload(PacketDown)),
        ?assertEqual(
            hpr_http_roaming_utils:uint32(DownlinkTimestamp + (RXDelay * 1000000)),
            hpr_packet_down:rx1_timestamp(PacketDown)
        ),
        ?assertEqual(DownlinkFreq, hpr_packet_down:rx1_frequency(PacketDown) / 1000000),
        ?assertEqual(DownlinkDatr, hpr_packet_down:rx1_datarate(PacketDown)),
        ok
    end),
    ok.

uplink_test_route(DevEUI, AppEUI, FlowType) ->
    RouteMap = #{
        net_id => ?NET_ID_ACTILITY,
        devaddr_ranges => [],
        euis => [
            #{
                dev_eui => DevEUI,
                app_eui => AppEUI
            }
        ],
        server => #{
            host => <<"127.0.0.1">>,
            port => 3002,
            protocol => {http_roaming, #{flow_type => FlowType}}
        }
    },
    Route = hpr_route:new(RouteMap),
    hpr_config:insert_route(Route).

downlink_test_route() ->
    RouteMap = #{
        net_id => ?NET_ID_ACTILITY,
        devaddr_ranges => [],
        euis => [],
        server => #{
            host => <<"127.0.0.1">>,
            port => 3002,
            protocol => {http_roaming, #{flow_type => sync}}
        }
    },
    Route = hpr_route:new(RouteMap),
    hpr_config:insert_route(Route).

http_async_uplink_join_test(_Config) ->
    {ok, _Pid} = hpr_http_roaming_sup:start_link(),
    %%
    %% Forwarder : HPR
    %% Roamer    : partner-lns
    %%
    ok = start_forwarder_listener(),
    ok = start_roamer_listener(),

    %% 1. Get a gateway to send from
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    DevEUIBin = <<"AABBCCDDEEFF0011">>,
    DevEUI = erlang:binary_to_integer(DevEUIBin, 16),
    AppEUI = erlang:binary_to_integer(<<"1122334455667788">>, 16),

    SendPacketFun = fun() ->
        GatewayTime = erlang:system_time(millisecond),
        PacketUp = test_utils:frame_packet_join(
            PubKeyBin,
            SigFun,
            DevEUI,
            AppEUI,
            #{timestamp => GatewayTime}
        ),
        ok = hpr_routing:handle_packet(PacketUp),
        {ok, PacketUp, GatewayTime}
    end,

    %% 2. load Roamer into the config
    uplink_test_route(DevEUI, AppEUI, async),

    %% 3. send packet
    {ok, PacketUp, GatewayTime} = SendPacketFun(),
    Region = hpr_packet_up:region(PacketUp),
    PacketTime = hpr_packet_up:timestamp(PacketUp),

    %% 4. Roamer receive http uplink
    {ok, #{<<"TransactionID">> := TransactionID, <<"ULMetaData">> := #{<<"FNSULToken">> := Token}}} = roamer_expect_uplink_data(
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => fun erlang:is_binary/1,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => hpr_http_roaming_utils:binary_to_hexstring(
                hpr_packet_up:payload(PacketUp)
            ),
            <<"ULMetaData">> => #{
                <<"DevEUI">> => <<"0x", DevEUIBin/binary>>,
                <<"DataRate">> => hpr_lorawan:datarate_to_index(
                    Region,
                    hpr_packet_up:datarate(PacketUp)
                ),
                <<"ULFreq">> => hpr_packet_up:frequency_mhz(PacketUp),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => hpr_http_roaming_utils:format_time(GatewayTime),

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
                        <<"ID">> => hpr_http_roaming_utils:binary_to_hexstring(
                            hpr_utils:pubkeybin_to_mac(PubKeyBin)
                        )
                    }
                ]
            }
        }
    ),

    ?assertMatch(
        {ok, TransactionID, 'US915', PacketTime, <<"127.0.0.1:3002/uplink">>, async},
        hpr_http_roaming:parse_uplink_token(Token)
    ),

    %% 5. Forwarder receive 200 response
    ok = forwarder_expect_response(200),

    %% 6. Forwarder receive http downlink
    {ok, _Data} = forwarder_expect_downlink_data(#{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"TransactionID">> => TransactionID,
        <<"SenderID">> => ?NET_ID_ACTILITY_BIN,
        <<"ReceiverID">> => <<"0xC00053">>,
        <<"MessageType">> => <<"PRStartAns">>,
        <<"Result">> => #{
            <<"ResultCode">> => <<"Success">>
        },
        <<"PHYPayload">> => hpr_http_roaming_utils:binary_to_hexstring(<<"join_accept_payload">>),
        <<"DevEUI">> => <<"0x", DevEUIBin/binary>>,
        <<"DLMetaData">> => #{
            <<"DataRate1">> => fun erlang:is_integer/1,
            <<"FNSULToken">> => Token,
            <<"Lifetime">> => 0,
            <<"DLFreq1">> => hpr_packet_up:frequency_mhz(PacketUp)
        }
    }),
    %% 7. Roamer receive 200 response
    ok = roamer_expect_response(200),

    %% 8. Gateway receive downlink
    ok = gateway_expect_downlink(fun(PacketDown) ->
        ?assertEqual('SF9BW125', hpr_packet_down:rx1_datarate(PacketDown)),
        ok
    end),

    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

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
%% using `hpr_http_roaming_downlink_handler' as the handler.
%%
%% Tests using the HTTP protocol start 2 Elli listeners.
%%
%% A forwarding listener :: (fns) Downlink Handler
%% A roaming listener    :: (sns) Uplink Handler as roaming partner
%%
%% The normal downlink listener is started, but ignored.
%%
%% The downlink handler in this file delegates to `hpr_http_roaming_downlink_handler' while
%% sending extra messages to the test running so the production code doesn't
%% need to know about the tests.
%% ------------------------------------------------------------------
handle('POST', [<<"downlink">>], Req, Args) ->
    Forward = maps:get(forward, Args),
    Body = elli_request:body(Req),
    #{
        <<"DLMetaData">> := #{<<"FNSULToken">> := Token}
    } = Decoded = jsx:decode(Body),

    FlowType = flow_type_from(Token),
    case FlowType of
        async ->
            Forward ! {http_downlink_data, Body},
            Res = hpr_http_roaming_downlink_handler:handle(Req, Args),
            ct:pal("Downlink handler resp: ~p", [Res]),
            Forward ! {http_downlink_data_response, 200},
            {200, [], <<>>};
        sync ->
            ct:pal("sync handling downlink:~n~p", [Decoded]),
            Response = hpr_http_roaming_downlink_handler:handle(Req, Args),

            %% Response = {200, [], jsx:encode(ResponseBody)},
            Forward ! {http_msg, Body, Req, Response},
            Response
    end;
handle('POST', [<<"uplink">>], Req, Args) ->
    Forward = maps:get(forward, Args),
    Body = elli_request:body(Req),
    #{
        <<"ULMetaData">> := #{<<"FNSULToken">> := Token}
    } = jsx:decode(Body),

    ResponseBody =
        case maps:get(response, Args, undefined) of
            undefined ->
                make_response_body(jsx:decode(Body));
            Resp ->
                ct:pal("Using canned response: ~p", [Resp]),
                Resp
        end,

    FlowType = flow_type_from(Token),
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

-spec flow_type_from(UplinkToken :: binary()) -> sync | async.
flow_type_from(UplinkToken) ->
    {ok, _TransactionID, _Region, _PacketTime, _DestURLBin, FlowType} =
        hpr_http_roaming:parse_uplink_token(UplinkToken),
    FlowType.

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
        'PHYPayload' => hpr_http_roaming_utils:binary_to_hexstring(<<"join_accept_payload">>),
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
        {callback, ?MODULE},
        {callback_args, maps:merge(#{forward => self()}, CallbackArgs)},
        {port, maps:get(port, Options, 3002)},
        {min_acceptors, 1}
    ]),
    ok.

start_downlink_listener() ->
    {ok, _ElliPid} = elli:start_link([
        {callback, ?MODULE},
        {callback_args, #{forward => self()}},
        {port, 3003},
        {min_acceptors, 1}
    ]),
    ok.

start_forwarder_listener() ->
    start_downlink_listener().

start_roamer_listener() ->
    start_uplink_listener().

gateway_expect_downlink(ExpectFn) ->
    receive
        {http_reply, PacketDown} ->
            ExpectFn(PacketDown)
    after 1000 -> ct:fail(gateway_expect_downlink_timeout)
    end.

-spec http_rcv() -> {ok, any()}.
http_rcv() ->
    receive
        {http_msg, Payload, Request, {StatusCode, [], RespBody}} ->
            {ok, jsx:decode(Payload), Request, {StatusCode, jsx:decode(RespBody)}}
    after 2500 -> ct:fail(http_msg_timeout)
    end.

-spec http_rcv(map()) -> {ok, any(), any()}.
http_rcv(Expected) ->
    {ok, Got, Request, Response} = http_rcv(),
    case test_utils:match_map(Expected, Got) of
        true ->
            {ok, Got, Request, Response};
        {false, Reason} ->
            ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
            ct:fail({http_rcv, Reason})
    end.

roamer_expect_uplink_data(Expected) ->
    {ok, Got} = roamer_expect_uplink_data(),
    case test_utils:match_map(Expected, Got) of
        true ->
            {ok, Got};
        {false, Reason} ->
            ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
            ct:fail({roamer_expect_uplink_data, Reason})
    end.

roamer_expect_uplink_data() ->
    receive
        http_uplink_data -> ct:fail({http_uplink_data_err, no_payload});
        {http_uplink_data, Payload} -> {ok, jsx:decode(Payload)}
    after 1000 -> ct:fail(http_uplink_data_timeout)
    end.

forwarder_expect_response(Code) ->
    receive
        {http_uplink_data_response, Code} ->
            ok;
        {http_uplink_data_response, OtherCode} ->
            ct:fail({http_uplink_data_response_err, [{expected, Code}, {got, OtherCode}]})
    after 1000 -> ct:fail(http_uplink_data_200_response_timeout)
    end.

forwarder_expect_downlink_data(Expected) ->
    {ok, Got} = forwarder_expect_downlink_data(),
    case test_utils:match_map(Expected, Got) of
        true ->
            {ok, Got};
        {false, Reason} ->
            ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
            ct:fail({forwarder_expect_downlink_data, Reason})
    end.

forwarder_expect_downlink_data() ->
    receive
        http_downlink_data -> ct:fail({http_downlink_data, no_payload});
        {http_downlink_data_error, Err} -> ct:fail(Err);
        {http_downlink_data, Payload} -> {ok, jsx:decode(Payload)}
    after 1000 -> ct:fail(http_downlink_data_timeout)
    end.

roamer_expect_response(Code) ->
    receive
        {http_downlink_data_response, Code} ->
            ok;
        {http_downlink_data_response, OtherCode} ->
            ct:fail({http_downlink_data_response_err, [{expected, Code}, {got, OtherCode}]})
    after 1000 -> ct:fail(http_downlink_data_200_response_timeout)
    end.
