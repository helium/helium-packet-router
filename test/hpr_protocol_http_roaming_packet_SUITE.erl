%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs
%%% @doc
%%%
%%% @end
%%% Created : 06. Oct 2022 2:11 PM
%%%-------------------------------------------------------------------
-module(hpr_protocol_http_roaming_packet_SUITE).
-author("jonathanruttenberg").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    http_sync_uplink_join_test/1,
    http_sync_downlink_test/1,
    http_async_uplink_join_test/1,
    http_async_downlink_test/1,
    http_uplink_packet_no_roaming_agreement_test/1,
    http_uplink_packet_test/1,
    uplink_with_gateway_location_test/1,
    http_class_c_downlink_test/1,
    http_multiple_gateways_test/1,
    http_multiple_joins_same_dest_test/1,
    http_multiple_gateways_single_shot_test/1,
    http_overlapping_devaddr_test/1,
    http_uplink_packet_late_test/1,
    http_auth_header_test/1
]).

%% Elli callback functions
-export([
    handle/2,
    handle_event/3
]).

-include("../src/grpc/autogen/downlink_pb.hrl").
-include_lib("eunit/include/eunit.hrl").

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
-define(DEVADDR_ACTILITY, 16#04abcdef).
-define(DEVADDR_ACTILITY_BIN, <<"0x04ABCDEF">>).

% pp_utils:hex_to_binary(<<"45000042">>)
-define(DEVADDR_COMCAST, 16#45000042).
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
        http_sync_downlink_test,
        http_async_uplink_join_test,
        http_async_downlink_test,
        http_uplink_packet_no_roaming_agreement_test,
        http_uplink_packet_test,
        uplink_with_gateway_location_test,
        http_class_c_downlink_test,
        http_multiple_gateways_test,
        http_multiple_joins_same_dest_test,
        http_multiple_gateways_single_shot_test,
        http_overlapping_devaddr_test,
        http_auth_header_test
    ].

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
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    ok = start_uplink_listener(),

    DevEUIBin = <<"00BBCCDDEEFF0011">>,
    DevEUI = erlang:binary_to_integer(DevEUIBin, 16),
    AppEUI = erlang:binary_to_integer(<<"1122334455667788">>, 16),

    ok = hpr_packet_router_service:register(PubKeyBin),

    SendPacketFun = fun() ->
        GatewayTime = erlang:system_time(millisecond),
        PacketUp = test_utils:join_packet_up(#{
            gateway => PubKeyBin,
            dev_eui => DevEUI,
            app_eui => AppEUI,
            sig_fun => SigFun,
            timestamp => GatewayTime
        }),

        ok = hpr_routing:handle_packet(PacketUp, #{gateway => PubKeyBin}),
        {ok, PacketUp, GatewayTime}
    end,

    join_test_route(DevEUI, AppEUI, sync, <<"route1">>),

    lager:debug(
        [
            {devaddr, ets:tab2list(hpr_route_devaddr_ranges_ets)},
            {eui, ets:tab2list(hpr_route_eui_pairs_ets)}
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
    } = http_rcv(
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => hpr_utils:sender_nsid(),
            <<"ReceiverNSID">> => <<"test-join-receiver-id">>,
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
                <<"RecvTime">> => formatted_timestamp_within_one_second(
                    hpr_http_roaming_utils:format_time(GatewayTime)
                ),

                <<"FNSULToken">> => fun erlang:is_binary/1,
                <<"GWCnt">> => 1,
                <<"GWInfo">> => [
                    #{
                        <<"RFRegion">> => erlang:atom_to_binary(Region),
                        <<"RSSI">> => hpr_packet_up:rssi(PacketUp),
                        <<"SNR">> => hpr_packet_up:snr(PacketUp),
                        <<"DLAllowed">> => true,
                        <<"GWID">> => hpr_http_roaming_utils:binary_to_hexstring(
                            hpr_utils:pubkeybin_to_mac(PubKeyBin)
                        )
                    }
                ]
            }
        }
    ),

    ?assertMatch(
        {ok, PubKeyBin, 'US915', PacketTime, "route1"},
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
                <<"SenderNSID">> => <<"test-join-receiver-id">>,
                <<"ReceiverNSID">> => hpr_utils:sender_nsid(),
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

    %% 5. Expect a PRStartNotif to the lns
    {ok, _, _, _} = http_rcv(#{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"MessageType">> => <<"PRStartNotif">>,
        <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
        <<"ReceiverNSID">> => <<"test-join-receiver-id">>,
        <<"SenderID">> => <<"0xC00053">>,
        <<"SenderNSID">> => hpr_utils:sender_nsid(),
        <<"TransactionID">> => TransactionID,
        <<"Result">> => #{<<"ResultCode">> => <<"Success">>}
    }),

    ok.

http_sync_downlink_test(_Config) ->
    ok = start_forwarder_listener(),

    #{public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    DownlinkPayload = <<"downlink_payload">>,
    DownlinkTimestamp = erlang:system_time(millisecond),
    DownlinkFreq = 915.0,
    DownlinkDatr = 'SF10BW125',
    TransactionID = 23,

    Token = hpr_http_roaming:make_uplink_token(PubKeyBin, 'US915', DownlinkTimestamp, "1"),
    RXDelay = 1,

    DownlinkBody = downlink_test_body(TransactionID, DownlinkPayload, Token, PubKeyBin),

    %% NOTE: We need to insert the transaction and handler here because we're
    %% only simulating downlinks. In a normal flow, these details would be
    %% filled during the uplink process.
    ok = hpr_packet_router_service:register(PubKeyBin),

    downlink_test_route(sync),

    {ok, 200, _Headers, _Resp} = hackney:post(
        <<"http://127.0.0.1:3003/downlink">>,
        [{<<"Host">>, <<"localhost">>}],
        jsx:encode(DownlinkBody),
        [with_body]
    ),

    %% TODO: sync mode is to-be-removed
    %% case
    %%     test_utils:match_map(
    %%         #{
    %%             <<"ProtocolVersion">> => <<"1.1">>,
    %%             <<"TransactionID">> => TransactionID,
    %%             <<"SenderID">> => <<"0xC00053">>,
    %%             <<"ReceiverID">> => hpr_http_roaming_utils:hexstring(?NET_ID_ACTILITY),
    %%             <<"MessageType">> => <<"XmitDataAns">>,
    %%             <<"Result">> => #{
    %%                 <<"ResultCode">> => <<"Success">>
    %%             },
    %%             <<"DLFreq1">> => DownlinkFreq
    %%         },
    %%         jsx:decode(Resp)
    %%     )
    %% of
    %%     true -> ok;
    %%     {false, Reason} -> ct:fail({http_response, Reason})
    %% end,

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

http_async_uplink_join_test(_Config) ->
    %%
    %% Forwarder : HPR
    %% Roamer    : partner-lns
    %%
    ok = start_forwarder_listener(),
    ok = start_roamer_listener(#{callback_args => #{flow_type => async}}),

    %% 1. Get a gateway to send from
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    DevEUIBin = <<"AABBCCDDEEFF0011">>,
    DevEUI = erlang:binary_to_integer(DevEUIBin, 16),
    AppEUI = erlang:binary_to_integer(<<"1122334455667788">>, 16),

    ok = hpr_packet_router_service:register(PubKeyBin),

    SendPacketFun = fun() ->
        GatewayTime = erlang:system_time(millisecond),
        PacketUp = test_utils:join_packet_up(#{
            gateway => PubKeyBin,
            dev_eui => DevEUI,
            app_eui => AppEUI,
            sig_fun => SigFun,
            timestamp => GatewayTime
        }),
        ok = hpr_routing:handle_packet(PacketUp, #{gateway => PubKeyBin}),
        {ok, PacketUp, GatewayTime}
    end,

    %% 2. load Roamer into the config
    join_test_route(DevEUI, AppEUI, async, <<"route1">>, #{
        auth_header => <<"expected auth header">>
    }),

    %% 3. send packet
    {ok, PacketUp, GatewayTime} = SendPacketFun(),
    Region = hpr_packet_up:region(PacketUp),
    PacketTime = hpr_packet_up:timestamp(PacketUp),

    %% 4. Roamer receive http uplink
    {ok,
        #{
            <<"TransactionID">> := TransactionID,
            <<"ULMetaData">> := #{<<"FNSULToken">> := Token}
        },
        Headers1} = roamer_expect_uplink_data(
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => hpr_utils:sender_nsid(),
            <<"ReceiverNSID">> => <<"test-join-receiver-id">>,
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
                <<"RecvTime">> => formatted_timestamp_within_one_second(
                    hpr_http_roaming_utils:format_time(GatewayTime)
                ),

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
                        <<"GWID">> => hpr_http_roaming_utils:binary_to_hexstring(
                            hpr_utils:pubkeybin_to_mac(PubKeyBin)
                        )
                    }
                ]
            }
        }
    ),
    ?assertEqual(<<"expected auth header">>, proplists:get_value(<<"Authorization">>, Headers1)),

    ?assertMatch(
        {ok, PubKeyBin, 'US915', PacketTime, "route1"},
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
        <<"SenderNSID">> => <<"test-join-receiver-id">>,
        <<"ReceiverNSID">> => hpr_utils:sender_nsid(),
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

    %% 9. Expect a PRStartNotif to the lns
    {ok, _Got, Headers2} = roamer_expect_uplink_data(#{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"MessageType">> => <<"PRStartNotif">>,
        <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
        <<"ReceiverNSID">> => <<"test-join-receiver-id">>,
        <<"SenderID">> => <<"0xC00053">>,
        <<"SenderNSID">> => hpr_utils:sender_nsid(),
        <<"TransactionID">> => TransactionID,
        <<"Result">> => #{<<"ResultCode">> => <<"Success">>}
    }),

    ?assertEqual(<<"expected auth header">>, proplists:get_value(<<"Authorization">>, Headers2)),

    ok.

http_async_downlink_test(_Config) ->
    %%
    %% Forwarder : packet-purchaser
    %% Roamer    : partner-lns
    %%
    ok = start_forwarder_listener(),
    ok = start_roamer_listener(#{callback_args => #{flow_type => async}}),

    %% 1. Get a gateway to send from
    #{public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% 2. insert response handler
    TransactionID = 23,
    ok = hpr_packet_router_service:register(PubKeyBin),

    %%    insert route
    downlink_test_route(async),

    %% 3. send downlink
    DownlinkPayload = <<"downlink_payload">>,
    DownlinkTimestamp = erlang:system_time(millisecond),
    DownlinkFreq = 915.0,
    DownlinkDatr = 'SF10BW125',

    Token = hpr_http_roaming:make_uplink_token(PubKeyBin, 'US915', DownlinkTimestamp, "1"),
    RXDelay = 1,

    DownlinkBody = downlink_test_body(TransactionID, DownlinkPayload, Token, PubKeyBin),

    _ = hackney:post(
        <<"http://127.0.0.1:3003/downlink">>,
        [{<<"Host">>, <<"localhost">>}],
        jsx:encode(DownlinkBody),
        [with_body]
    ),

    %% 4. forwarder receive http downlink
    {ok, #{<<"TransactionID">> := TransactionID}} = forwarder_expect_downlink_data(#{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"SenderID">> => hpr_http_roaming_utils:hexstring(?NET_ID_ACTILITY),
        <<"ReceiverID">> => <<"0xC00053">>,
        <<"SenderNSID">> => <<"downlink-test-body-sender-nsid">>,
        <<"ReceiverNSID">> => hpr_utils:sender_nsid(),
        <<"TransactionID">> => TransactionID,
        <<"MessageType">> => <<"XmitDataReq">>,
        <<"PHYPayload">> => hpr_http_roaming_utils:binary_to_hexstring(DownlinkPayload),
        <<"DLMetaData">> => #{
            <<"DevEUI">> => <<"0xaabbffccfeeff001">>,
            <<"DLFreq1">> => DownlinkFreq,
            <<"DataRate1">> => 0,
            <<"RXDelay1">> => RXDelay,
            <<"FNSULToken">> => Token,
            <<"GWInfo">> => [
                #{<<"ULToken">> => libp2p_crypto:bin_to_b58(PubKeyBin)}
            ],
            <<"ClassMode">> => <<"A">>,
            <<"HiPriorityFlag">> => false
        }
    }),

    %% 5. roamer expect 200 response
    ok = roamer_expect_response(200),

    %% 6. roamer receives http downlink ack (xmitdata_ans)
    {ok, _Data, _Headers} = roamer_expect_uplink_data(#{
        <<"DLFreq1">> => DownlinkFreq,
        <<"MessageType">> => <<"XmitDataAns">>,
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"ReceiverID">> => hpr_http_roaming_utils:hexstring(?NET_ID_ACTILITY),
        <<"SenderID">> => <<"0xC00053">>,
        <<"SenderNSID">> => hpr_utils:sender_nsid(),
        <<"ReceiverNSID">> => <<"downlink-test-body-sender-nsid">>,
        <<"Result">> => #{<<"ResultCode">> => <<"Success">>},
        <<"TransactionID">> => TransactionID
    }),

    %% 7. forwarder expects 200 response
    ok = forwarder_expect_response(200),

    %% 8. gateway receives downlink
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

http_uplink_packet_no_roaming_agreement_test(_Config) ->
    %% When receiving a response that there is no roaming agreement for a NetID,
    %% we should stop purchasing for that NetID.
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    ok = start_uplink_listener(#{
        callback_args => #{
            response => #{
                <<"SenderID">> => <<"000002">>,
                <<"ReceiverID">> => <<"C00053">>,
                <<"ProtocolVersion">> => <<"1.1">>,
                <<"TransactionID">> => 601913476,
                <<"MessageType">> => <<"PRStartAns">>,
                <<"Result">> => #{
                    <<"ResultCode">> => <<"NoRoamingAgreement">>,
                    <<"Description">> => <<"There is no roaming agreement between the operators">>
                }
            }
        }
    }),

    ok = hpr_packet_router_service:register(PubKeyBin),

    SendPacketFun = fun(DevAddr, FrameCount) ->
        GatewayTime = erlang:system_time(millisecond),
        PacketUp = test_utils:uplink_packet_up(#{
            gateway => PubKeyBin,
            devaddr => DevAddr,
            fcnt => FrameCount,
            sig_fun => SigFun,
            timestamp => GatewayTime
        }),
        ok = hpr_routing:handle_packet(PacketUp, #{gateway => PubKeyBin}),
        {ok, PacketUp, GatewayTime}
    end,

    uplink_test_route(),
    lager:debug("routes by devaddr: ~p", [ets:tab2list(hpr_route_devaddr_ranges_ets)]),

    {ok, PacketUp, GatewayTime} = SendPacketFun(?DEVADDR_ACTILITY, 0),
    Payload = hpr_packet_up:payload(PacketUp),
    Region = hpr_packet_up:region(PacketUp),
    PacketTime = hpr_packet_up:timestamp(PacketUp),

    %% First packet is purchased and sent to Roamer
    {
        ok,
        #{<<"ULMetaData">> := #{<<"FNSULToken">> := Token}},
        _Request,
        {200, _RespBody}
    } = http_rcv(
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => hpr_utils:sender_nsid(),
            <<"ReceiverNSID">> => <<"test-uplink-receiver-id">>,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => hpr_http_roaming_utils:binary_to_hexstring(Payload),
            <<"ULMetaData">> => #{
                <<"DevAddr">> => ?DEVADDR_ACTILITY_BIN,
                <<"DataRate">> => hpr_lorawan:datarate_to_index(
                    Region,
                    hpr_packet_up:datarate(PacketUp)
                ),
                <<"ULFreq">> => hpr_packet_up:frequency_mhz(PacketUp),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => formatted_timestamp_within_one_second(
                    hpr_http_roaming_utils:format_time(GatewayTime)
                ),

                <<"FNSULToken">> => fun erlang:is_binary/1,
                <<"GWCnt">> => 1,
                <<"GWInfo">> => [
                    #{
                        <<"RFRegion">> => erlang:atom_to_binary(Region),
                        <<"RSSI">> => hpr_packet_up:rssi(PacketUp),
                        <<"SNR">> => hpr_packet_up:snr(PacketUp),
                        <<"DLAllowed">> => true,
                        <<"GWID">> => hpr_http_roaming_utils:binary_to_hexstring(
                            hpr_utils:pubkeybin_to_mac(PubKeyBin)
                        )
                    }
                ]
            }
        }
    ),

    ?assertMatch(
        {ok, PubKeyBin, 'US915', PacketTime, "route1"},
        hpr_http_roaming:parse_uplink_token(Token)
    ),

    timer:sleep(500),
    %% Second packet is not forwarded
    {ok, _PacketUp, _GatewayTime} = SendPacketFun(?DEVADDR_ACTILITY, 1),
    ok = not_http_rcv(1000),

    ok.

http_uplink_packet_test(_Config) ->
    %% One Gateway is going to be sending all the packets.
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    ok = start_uplink_listener(),

    SendPacketFun = fun(DevAddr) ->
        GatewayTime = erlang:system_time(millisecond),
        PacketUp = test_utils:uplink_packet_up(#{
            gateway => PubKeyBin,
            devaddr => DevAddr,
            fcnt => 0,
            sig_fun => SigFun,
            timestamp => GatewayTime
        }),
        ok = hpr_routing:handle_packet(PacketUp, #{gateway => PubKeyBin}),
        {ok, PacketUp, GatewayTime}
    end,

    uplink_test_route(),

    {ok, PacketUp, GatewayTime} = SendPacketFun(?DEVADDR_ACTILITY),
    Payload = hpr_packet_up:payload(PacketUp),
    Region = hpr_packet_up:region(PacketUp),
    PacketTime = hpr_packet_up:timestamp(PacketUp),

    {
        ok,
        #{<<"ULMetaData">> := #{<<"FNSULToken">> := Token}},
        _Request,
        {200, _RespBody}
    } = http_rcv(
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => hpr_utils:sender_nsid(),
            <<"ReceiverNSID">> => <<"test-uplink-receiver-id">>,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => hpr_http_roaming_utils:binary_to_hexstring(Payload),
            <<"ULMetaData">> => #{
                <<"DevAddr">> => ?DEVADDR_ACTILITY_BIN,
                <<"DataRate">> => hpr_lorawan:datarate_to_index(
                    Region,
                    hpr_packet_up:datarate(PacketUp)
                ),
                <<"ULFreq">> => hpr_packet_up:frequency_mhz(PacketUp),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => formatted_timestamp_within_one_second(
                    hpr_http_roaming_utils:format_time(GatewayTime)
                ),

                <<"FNSULToken">> => fun erlang:is_binary/1,
                <<"GWCnt">> => 1,
                <<"GWInfo">> => [
                    #{
                        <<"RFRegion">> => erlang:atom_to_binary(Region),
                        <<"RSSI">> => hpr_packet_up:rssi(PacketUp),
                        <<"SNR">> => hpr_packet_up:snr(PacketUp),
                        <<"DLAllowed">> => true,
                        <<"GWID">> => hpr_http_roaming_utils:binary_to_hexstring(
                            hpr_utils:pubkeybin_to_mac(PubKeyBin)
                        )
                    }
                ]
            }
        }
    ),

    ?assertMatch(
        {ok, PubKeyBin, 'US915', PacketTime, "route1"},
        hpr_http_roaming:parse_uplink_token(Token)
    ),

    ok.

uplink_with_gateway_location_test(_Config) ->
    %% One Gateway is going to be sending all the packets.
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    IndexString = "8828308281fffff",
    ok = hpr_test_ics_gateway_service:register_gateway_location(
        PubKeyBin,
        IndexString
    ),

    %% Trigger an update location and wait until the location has been fetched
    ok = test_utils:wait_until(fun() ->
        case hpr_gateway_location:get(PubKeyBin) of
            {ok, _, _, _} ->
                true;
            Other ->
                {false, Other}
        end
    end),

    ok = start_uplink_listener(),

    SendPacketFun = fun(DevAddr) ->
        GatewayTime = erlang:system_time(millisecond),
        PacketUp = test_utils:uplink_packet_up(#{
            gateway => PubKeyBin,
            devaddr => DevAddr,
            fcnt => 0,
            sig_fun => SigFun,
            timestamp => GatewayTime
        }),
        ok = hpr_routing:handle_packet(PacketUp, #{gateway => PubKeyBin}),
        {ok, PacketUp, GatewayTime}
    end,

    uplink_test_route(),

    {ok, PacketUp, GatewayTime} = SendPacketFun(?DEVADDR_ACTILITY),
    Payload = hpr_packet_up:payload(PacketUp),
    Region = hpr_packet_up:region(PacketUp),
    PacketTime = hpr_packet_up:timestamp(PacketUp),
    ExpectedIndex = h3:from_string(IndexString),
    {ExpectedLat, ExpectedLong} = h3:to_geo(ExpectedIndex),
    {
        ok,
        #{<<"ULMetaData">> := #{<<"FNSULToken">> := Token}},
        _Request,
        {200, _RespBody}
    } = http_rcv(
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => hpr_utils:sender_nsid(),
            <<"ReceiverNSID">> => <<"test-uplink-receiver-id">>,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => hpr_http_roaming_utils:binary_to_hexstring(Payload),
            <<"ULMetaData">> => #{
                <<"DevAddr">> => ?DEVADDR_ACTILITY_BIN,
                <<"DataRate">> => hpr_lorawan:datarate_to_index(
                    Region,
                    hpr_packet_up:datarate(PacketUp)
                ),
                <<"ULFreq">> => hpr_packet_up:frequency_mhz(PacketUp),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => formatted_timestamp_within_one_second(
                    hpr_http_roaming_utils:format_time(GatewayTime)
                ),

                <<"FNSULToken">> => fun erlang:is_binary/1,
                <<"GWCnt">> => 1,
                <<"GWInfo">> => [
                    #{
                        <<"RFRegion">> => erlang:atom_to_binary(Region),
                        <<"RSSI">> => hpr_packet_up:rssi(PacketUp),
                        <<"SNR">> => hpr_packet_up:snr(PacketUp),
                        <<"Lat">> => ExpectedLat,
                        <<"Lon">> => ExpectedLong,
                        <<"DLAllowed">> => true,
                        <<"GWID">> => hpr_http_roaming_utils:binary_to_hexstring(
                            hpr_utils:pubkeybin_to_mac(PubKeyBin)
                        )
                    }
                ]
            }
        }
    ),

    ?assertMatch(
        {ok, PubKeyBin, 'US915', PacketTime, "route1"},
        hpr_http_roaming:parse_uplink_token(Token)
    ),

    ok.

http_class_c_downlink_test(_Config) ->
    %%
    %% Forwarder : HPR
    %% Roamer    : partner-lns
    %%
    ok = start_forwarder_listener(),
    ok = start_roamer_listener(#{callback_args => #{flow_type => async}}),

    #{public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% 1. insert handler and config
    TransactionID = 2176,
    ok = hpr_packet_router_service:register(PubKeyBin),
    downlink_test_route(async),

    %% 2. send downlink
    DownlinkPayload = <<"downlink_payload">>,
    DownlinkTimestamp = erlang:system_time(millisecond),
    DownlinkFreq = 915.0,
    DownlinkDatr = 'SF10BW125',

    Token = hpr_http_roaming:make_uplink_token(PubKeyBin, 'US915', DownlinkTimestamp, "1"),
    RXDelay = 0,

    DownlinkBody = #{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"MessageType">> => <<"XmitDataReq">>,
        <<"ReceiverID">> => <<"0xC00053">>,
        <<"SenderID">> => ?NET_ID_ACTILITY_BIN,
        <<"SenderNSID">> => <<"test-class-c-receiver-nsid">>,
        <<"ReceiverNSID">> => hpr_utils:sender_nsid(),
        <<"DLMetaData">> => #{
            <<"ClassMode">> => <<"C">>,
            <<"DLFreq2">> => DownlinkFreq,
            <<"DataRate2">> => 0,
            <<"DevEUI">> => <<"0xaabbffccfeeff001">>,
            <<"FNSULToken">> => Token,
            <<"HiPriorityFlag">> => false,
            <<"RXDelay1">> => 0
        },
        <<"PHYPayload">> => hpr_http_roaming_utils:binary_to_hexstring(DownlinkPayload),
        <<"TransactionID">> => TransactionID
    },

    _ = hackney:post(
        <<"http://127.0.0.1:3003/downlink">>,
        [{<<"Host">>, <<"localhost">>}],
        jsx:encode(DownlinkBody),
        [with_body]
    ),

    %% 3. forwarder receive http downlink
    {ok, #{<<"TransactionID">> := TransactionID}} = forwarder_expect_downlink_data(#{
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"SenderID">> => hpr_http_roaming_utils:hexstring(?NET_ID_ACTILITY),
        <<"ReceiverID">> => <<"0xC00053">>,
        <<"ReceiverNSID">> => hpr_utils:sender_nsid(),
        <<"SenderNSID">> => <<"test-class-c-receiver-nsid">>,
        <<"TransactionID">> => TransactionID,
        <<"MessageType">> => <<"XmitDataReq">>,
        <<"PHYPayload">> => hpr_http_roaming_utils:binary_to_hexstring(DownlinkPayload),
        <<"DLMetaData">> => #{
            <<"DevEUI">> => <<"0xaabbffccfeeff001">>,
            <<"DLFreq2">> => DownlinkFreq,
            <<"DataRate2">> => 0,
            <<"RXDelay1">> => RXDelay,
            <<"FNSULToken">> => Token,
            <<"ClassMode">> => <<"C">>,
            <<"HiPriorityFlag">> => false
        }
    }),

    %% 4. roamer expect 200 response
    ok = roamer_expect_response(200),

    %% 5. roamer receives http downlink ack (xmitdata_ans)
    {ok, _Data, _Headers} = roamer_expect_uplink_data(#{
        <<"DLFreq2">> => DownlinkFreq,
        <<"MessageType">> => <<"XmitDataAns">>,
        <<"ProtocolVersion">> => <<"1.1">>,
        <<"ReceiverID">> => hpr_http_roaming_utils:hexstring(?NET_ID_ACTILITY),
        <<"SenderID">> => <<"0xC00053">>,
        <<"ReceiverNSID">> => <<"test-class-c-receiver-nsid">>,
        <<"SenderNSID">> => hpr_utils:sender_nsid(),
        <<"Result">> => #{<<"ResultCode">> => <<"Success">>},
        <<"TransactionID">> => TransactionID
    }),

    %% 6. forwarder expects 200 response
    ok = forwarder_expect_response(200),

    %% 7. gateway receive downlink
    ok = gateway_expect_downlink(fun(PacketDown) ->
        ?assertEqual(DownlinkPayload, hpr_packet_down:payload(PacketDown)),
        ?assertEqual(0, hpr_packet_down:rx1_timestamp(PacketDown)),
        ?assert(hpr_packet_down:is_immediate(PacketDown)),
        ?assertEqual(DownlinkFreq, hpr_packet_down:rx1_frequency(PacketDown) / 1000000),
        ?assertEqual(DownlinkDatr, hpr_packet_down:rx1_datarate(PacketDown)),
        ok
    end),

    ok.

http_multiple_gateways_test(_Config) ->
    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ed25519),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    #{secret := PrivKey2, public := PubKey2} = libp2p_crypto:generate_keys(ed25519),
    SigFun2 = libp2p_crypto:mk_sig_fun(PrivKey2),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),

    ok = start_uplink_listener(),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),

    SendPacketFun = fun(PubKeyBin, DevAddr, RSSI, SigFun) ->
        GatewayTime = erlang:system_time(millisecond),
        PacketUp = test_utils:uplink_packet_up(#{
            gateway => PubKeyBin,
            devaddr => DevAddr,
            fcnt => 0,
            rssi => RSSI,
            sig_fun => SigFun,
            timestamp => GatewayTime,
            app_session_key => AppSessionKey,
            nwk_session_key => NwkSessionKey
        }),
        ok = hpr_routing:handle_packet(PacketUp, #{gateway => PubKeyBin}),
        {ok, PacketUp, GatewayTime}
    end,

    uplink_test_route(),

    {ok, PacketUp1, GatewayTime1} = SendPacketFun(PubKeyBin1, ?DEVADDR_ACTILITY, -25, SigFun1),

    %% Sleep to ensure packets have different timing information
    timer:sleep(10),

    {ok, PacketUp2, _GatewayTime2} = SendPacketFun(PubKeyBin2, ?DEVADDR_ACTILITY, -30, SigFun2),

    PacketTime1 = hpr_packet_up:timestamp(PacketUp1),
    Region = hpr_packet_up:region(PacketUp1),

    {
        ok,
        #{<<"ULMetaData">> := #{<<"FNSULToken">> := Token}},
        _Request,
        {200, _RespBody}
    } =
        http_rcv(#{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => hpr_utils:sender_nsid(),
            <<"ReceiverNSID">> => <<"test-uplink-receiver-id">>,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => hpr_http_roaming_utils:binary_to_hexstring(
                hpr_packet_up:payload(PacketUp1)
            ),
            <<"ULMetaData">> => #{
                <<"DevAddr">> => ?DEVADDR_ACTILITY_BIN,
                <<"DataRate">> => hpr_lorawan:datarate_to_index(
                    Region,
                    hpr_packet_up:datarate(PacketUp1)
                ),
                <<"ULFreq">> => hpr_packet_up:frequency_mhz(PacketUp1),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => formatted_timestamp_within_one_second(
                    hpr_http_roaming_utils:format_time(GatewayTime1)
                ),

                <<"FNSULToken">> => fun erlang:is_binary/1,
                <<"GWCnt">> => 2,
                <<"GWInfo">> => [
                    #{
                        <<"GWID">> => hpr_http_roaming_utils:binary_to_hexstring(
                            hpr_utils:pubkeybin_to_mac(PubKeyBin1)
                        ),
                        <<"RFRegion">> => erlang:atom_to_binary(Region),
                        <<"RSSI">> => hpr_packet_up:rssi(PacketUp1),
                        <<"SNR">> => hpr_packet_up:snr(PacketUp1),
                        <<"DLAllowed">> => true
                    },
                    #{
                        <<"GWID">> => hpr_http_roaming_utils:binary_to_hexstring(
                            hpr_utils:pubkeybin_to_mac(PubKeyBin2)
                        ),
                        <<"RFRegion">> => erlang:atom_to_binary(Region),
                        <<"RSSI">> => hpr_packet_up:rssi(PacketUp2),
                        <<"SNR">> => hpr_packet_up:snr(PacketUp2),
                        <<"DLAllowed">> => true
                    }
                ]
            }
        }),

    %% Gateway with better RSSI should be chosen
    ?assertMatch(
        {ok, PubKeyBin1, 'US915', PacketTime1, "route1"},
        hpr_http_roaming:parse_uplink_token(Token)
    ),

    ok.

http_multiple_joins_same_dest_test(_Config) ->
    DevEUI1 = 1,
    AppEUI1 = 16#200000001,

    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    GatewayTime = erlang:system_time(millisecond),
    PacketUp = test_utils:join_packet_up(#{
        gateway => PubKeyBin,
        dev_eui => DevEUI1,
        app_eui => AppEUI1,
        sig_fun => SigFun,
        timestamp => GatewayTime
    }),

    join_test_route(DevEUI1, AppEUI1, sync, <<"route1">>, #{net_id => ?NET_ID_ACTILITY}),
    join_test_route(DevEUI1, AppEUI1, sync, <<"route2">>, #{net_id => ?NET_ID_ORANGE}),

    ok = start_uplink_listener(#{port => 3002, callback_args => #{forward => self()}}),

    ok = hpr_routing:handle_packet(PacketUp, #{gateway => PubKeyBin}),

    HttpReceivePRStartReq = fun HTTPRECEIVEPRSTARTREQ() ->
        case http_rcv() of
            {ok, #{<<"MessageType">> := <<"PRStartReq">>} = Req, _, _} -> Req;
            {ok, #{}, _, _} -> HTTPRECEIVEPRSTARTREQ()
        end
    end,

    #{<<"ReceiverID">> := ReceiverOne} = HttpReceivePRStartReq(),
    #{<<"ReceiverID">> := ReceiverTwo} = HttpReceivePRStartReq(),

    ok = not_http_rcv(250),

    ?assertNotEqual(ReceiverOne, ReceiverTwo),

    ok.

http_multiple_gateways_single_shot_test(_Config) ->
    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ed25519),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    #{secret := PrivKey2, public := PubKey2} = libp2p_crypto:generate_keys(ed25519),
    SigFun2 = libp2p_crypto:mk_sig_fun(PrivKey2),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),

    ok = start_uplink_listener(),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),

    SendPacketFun = fun(PubKeyBin, DevAddr, RSSI, SigFun) ->
        GatewayTime = erlang:system_time(millisecond),
        PacketUp = test_utils:uplink_packet_up(#{
            gateway => PubKeyBin,
            devaddr => DevAddr,
            fcnt => 0,
            rssi => RSSI,
            sig_fun => SigFun,
            timestamp => GatewayTime,
            app_session_key => AppSessionKey,
            nwk_session_key => NwkSessionKey
        }),
        ok = hpr_routing:handle_packet(PacketUp, #{gateway => PubKeyBin}),
        {ok, PacketUp, GatewayTime}
    end,
    uplink_test_route(#{dedupe_timeout => 0}),

    {ok, PacketUp1, GatewayTime1} = SendPacketFun(PubKeyBin1, ?DEVADDR_ACTILITY, -25, SigFun1),
    {ok, PacketUp2, _GatewayTime2} = SendPacketFun(PubKeyBin2, ?DEVADDR_ACTILITY, -30, SigFun2),
    Region = hpr_packet_up:region(PacketUp1),

    MakeBaseExpect = fun(GatewayInfo) ->
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => hpr_utils:sender_nsid(),
            <<"ReceiverNSID">> => <<"test-uplink-receiver-id">>,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => hpr_http_roaming_utils:binary_to_hexstring(
                hpr_packet_up:payload(PacketUp1)
            ),
            <<"ULMetaData">> => #{
                <<"DevAddr">> => ?DEVADDR_ACTILITY_BIN,
                <<"DataRate">> => hpr_lorawan:datarate_to_index(
                    Region,
                    hpr_packet_up:datarate(PacketUp1)
                ),
                <<"ULFreq">> => hpr_packet_up:frequency_mhz(PacketUp1),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => formatted_timestamp_within_one_second(
                    hpr_http_roaming_utils:format_time(GatewayTime1)
                ),

                <<"FNSULToken">> => fun erlang:is_binary/1,
                <<"GWCnt">> => 1,
                <<"GWInfo">> => [GatewayInfo]
            }
        }
    end,

    {ok, _Data1, _, {200, _RespBody1}} = http_rcv(
        MakeBaseExpect(#{
            <<"GWID">> => hpr_http_roaming_utils:binary_to_hexstring(
                hpr_utils:pubkeybin_to_mac(PubKeyBin1)
            ),
            <<"RFRegion">> => erlang:atom_to_binary(Region),
            <<"RSSI">> => hpr_packet_up:rssi(PacketUp1),
            <<"SNR">> => hpr_packet_up:snr(PacketUp1),
            <<"DLAllowed">> => true
        })
    ),

    {ok, _Data2, _, {200, _RespBody2}} = http_rcv(
        MakeBaseExpect(#{
            <<"GWID">> => hpr_http_roaming_utils:binary_to_hexstring(
                hpr_utils:pubkeybin_to_mac(PubKeyBin2)
            ),
            <<"RFRegion">> => erlang:atom_to_binary(Region),
            <<"RSSI">> => hpr_packet_up:rssi(PacketUp2),
            <<"SNR">> => hpr_packet_up:snr(PacketUp2),
            <<"DLAllowed">> => true
        })
    ),
    ok.

http_overlapping_devaddr_test(_Config) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    GatewayTime = erlang:system_time(millisecond),
    PacketUp = test_utils:uplink_packet_up(#{
        gateway => PubKeyBin,
        devaddr => ?DEVADDR_COMCAST,
        fcnt => 0,
        sig_fun => SigFun,
        timestamp => GatewayTime
    }),

    DevAddrRangeSingle = #{
        start_addr => 16#45000042,
        end_addr => 16#45000042
    },
    DevAddrInRange = #{
        start_addr => 16#45000040,
        end_addr => 16#45000044
    },

    %% Overlapping DevAddrs, but going to different endpoints
    uplink_test_route(#{
        id => <<"route1">>,
        net_id => ?NET_ID_COMCAST,
        dedupe_timeout => 50,
        devaddr_ranges => [DevAddrRangeSingle]
    }),
    uplink_test_route(#{
        id => <<"route2">>,
        net_id => ?NET_ID_COMCAST,
        dedupe_timeout => 50,
        devaddr_ranges => [DevAddrInRange],
        port => 3003
    }),

    ok = start_uplink_listener(#{port => 3002}),
    ok = start_uplink_listener(#{port => 3003}),

    ok = hpr_routing:handle_packet(PacketUp, #{gateway => PubKeyBin}),

    {ok, #{<<"ReceiverID">> := ReceiverOne}, _, _} = http_rcv(),
    {ok, #{<<"ReceiverID">> := ReceiverTwo}, _, _} = http_rcv(),
    ok = not_http_rcv(250),

    %% Receiver ID must be the same because DevAddr is explicitly partitioned by
    %% NetID, unlike Join EUI. And we got 2 requests.
    ?assertEqual(ReceiverOne, ReceiverTwo),

    ok.

http_uplink_packet_late_test(_Config) ->
    %% There's a builtin dedupe for http roaming, we want to make sure that
    %% gateways with high hold time don't cause the same packet to be sent again
    %% if they missed the dedupe window.

    ok = start_uplink_listener(),

    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ed25519),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    #{secret := PrivKey2, public := PubKey2} = libp2p_crypto:generate_keys(ed25519),
    SigFun2 = libp2p_crypto:mk_sig_fun(PrivKey2),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),

    SendPacketFun = fun(PubKeyBin, DevAddr, SigFun) ->
        GatewayTime = erlang:system_time(millisecond),
        PacketUp = test_utils:uplink_packet_up(#{
            gateway => PubKeyBin,
            devaddr => DevAddr,
            fcnt => 0,
            sig_fun => SigFun,
            timestamp => GatewayTime
        }),
        ok = hpr_routing:handle_packet(PacketUp, #{gateway => PubKeyBin}),
        {ok, PacketUp, GatewayTime}
    end,

    uplink_test_route(#{dedupe_timeout => 10}),

    {ok, PacketUp1, GatewayTime1} = SendPacketFun(PubKeyBin1, ?DEVADDR_ACTILITY, SigFun1),
    Region = hpr_packet_up:region(PacketUp1),
    PacketTime = hpr_packet_up:timestamp(PacketUp1),

    %% Wait past the timeout before sending another packet
    ok = timer:sleep(100),
    {ok, _, _} = SendPacketFun(PubKeyBin2, ?DEVADDR_ACTILITY, SigFun2),

    {
        ok,
        #{<<"ULMetaData">> := #{<<"FNSULToken">> := Token}},
        _Request,
        {200, _RespBody}
    } = http_rcv(
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
            <<"SenderNSID">> => hpr_utils:sender_nsid(),
            <<"ReceiverNSID">> => <<"test-uplink-receiver-id">>,
            <<"DedupWindowSize">> => fun erlang:is_integer/1,
            <<"TransactionID">> => fun erlang:is_number/1,
            <<"SenderID">> => <<"0xC00053">>,
            <<"ReceiverID">> => ?NET_ID_ACTILITY_BIN,
            <<"MessageType">> => <<"PRStartReq">>,
            <<"PHYPayload">> => hpr_http_roaming_utils:binary_to_hexstring(
                hpr_packet_up:payload(PacketUp1)
            ),
            <<"ULMetaData">> => #{
                <<"DevAddr">> => ?DEVADDR_ACTILITY_BIN,
                <<"DataRate">> => hpr_lorawan:datarate_to_index(
                    Region,
                    hpr_packet_up:datarate(PacketUp1)
                ),
                <<"ULFreq">> => hpr_packet_up:frequency_mhz(PacketUp1),
                <<"RFRegion">> => erlang:atom_to_binary(Region),
                <<"RecvTime">> => formatted_timestamp_within_one_second(
                    hpr_http_roaming_utils:format_time(GatewayTime1)
                ),

                <<"FNSULToken">> => fun erlang:is_binary/1,
                <<"GWCnt">> => 1,
                <<"GWInfo">> => [
                    #{
                        <<"GWID">> => hpr_http_roaming_utils:binary_to_hexstring(
                            hpr_utils:pubkeybin_to_mac(PubKeyBin1)
                        ),
                        <<"RFRegion">> => erlang:atom_to_binary(Region),
                        <<"RSSI">> => hpr_packet_up:rssi(PacketUp1),
                        <<"SNR">> => hpr_packet_up:snr(PacketUp1),
                        <<"DLAllowed">> => true
                    }
                ]
            }
        }
    ),

    ?assertMatch(
        {ok, PubKeyBin1, 'US915', PacketTime, "route1"},
        hpr_http_roaming:parse_uplink_token(Token)
    ),

    %% We should not get another http request for the second packet that missed the window.
    ok = not_http_rcv(timer:seconds(1)),

    ok.

http_auth_header_test(_Config) ->
    %% One Gateway is going to be sending all the packets.
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    ok = start_uplink_listener(),

    DevEUIBin = <<"00BBCCDDEEFF0011">>,
    DevEUI = erlang:binary_to_integer(DevEUIBin, 16),
    AppEUI = erlang:binary_to_integer(<<"1122334455667788">>, 16),

    ok = hpr_packet_router_service:register(PubKeyBin),

    SendPacketFun = fun() ->
        GatewayTime = erlang:system_time(millisecond),
        PacketUp = test_utils:join_packet_up(#{
            gateway => PubKeyBin,
            dev_eui => DevEUI,
            app_eui => AppEUI,
            sig_fun => SigFun,
            timestamp => GatewayTime
        }),

        ok = hpr_routing:handle_packet(PacketUp, #{gateway => PubKeyBin}),
        {ok, PacketUp, GatewayTime}
    end,

    %% ===================================================================
    %% Expect an Auth header in the request

    uplink_test_route(#{
        euis => [#{dev_eui => DevEUI, app_eui => AppEUI}],
        flow_type => sync,
        auth_header => "Basic: testing"
    }),

    %% 1. Send a join uplink
    _ = SendPacketFun(),

    %% 2. Expect a PRStartReq to the lns
    {ok, #{<<"MessageType">> := <<"PRStartReq">>}, Request1, _} = http_rcv(),
    Headers1 = elli_request:headers(Request1),
    ?assertEqual(<<"Basic: testing">>, proplists:get_value(<<"Authorization">>, Headers1)),
    %% 2.1 Expect PRStartNotif to the lns
    {ok, #{<<"MessageType">> := <<"PRStartNotif">>}, Request10, _} = http_rcv(),
    Headers10 = elli_request:headers(Request10),
    ?assertEqual(<<"Basic: testing">>, proplists:get_value(<<"Authorization">>, Headers10)),

    %% ===================================================================
    %% Expect no auth header in the request

    uplink_test_route(#{
        euis => [#{dev_eui => DevEUI, app_eui => AppEUI}],
        flow_type => sync
        %% auth_header => "Basic: testing"
    }),

    %% 1. Send a join uplink
    _ = SendPacketFun(),

    %% 2. Expect a PRStartReq to the lns
    {ok, #{<<"MessageType">> := <<"PRStartReq">>}, Request2, _} = http_rcv(),
    Headers2 = elli_request:headers(Request2),
    ?assertEqual(undefined, proplists:get_value(<<"Authorization">>, Headers2)),
    %% 2.1 Expect PRStartNotif to the lns
    {ok, #{<<"MessageType">> := <<"PRStartNotif">>}, Request20, _} = http_rcv(),
    Headers20 = elli_request:headers(Request20),
    ?assertEqual(undefined, proplists:get_value(<<"Authorization">>, Headers20)),

    ok.

%% ------------------------------------------------------------------
%% Fixture Helpers
%% ------------------------------------------------------------------

join_test_route(DevEUI, AppEUI, FlowType, RouteID) ->
    join_test_route(DevEUI, AppEUI, FlowType, RouteID, #{}).

join_test_route(DevEUI, AppEUI, FlowType, RouteID0, Options) ->
    RouteID =
        case erlang:is_binary(RouteID0) of
            true -> erlang:binary_to_list(RouteID0);
            false -> RouteID0
        end,
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => maps:get(net_id, Options, ?NET_ID_ACTILITY),
        oui => 0,
        server => #{
            host => "127.0.0.1",
            port => 3002,
            protocol =>
                {http_roaming, #{
                    flow_type => FlowType,
                    path => "/uplink",
                    receiver_nsid => "test-join-receiver-id",
                    auth_header => maps:get(auth_header, Options, <<>>)
                }}
        },
        max_copies => 2
    }),
    EUIPair = hpr_eui_pair:test_new(#{
        route_id => RouteID, app_eui => AppEUI, dev_eui => DevEUI
    }),
    ok = hpr_route_storage:insert(Route),
    ok = hpr_eui_pair_storage:insert(EUIPair).

uplink_test_route() ->
    uplink_test_route(#{id => "route1"}).

uplink_test_route(InputMap) ->
    RouteID0 = maps:get(id, InputMap, "route1"),
    RouteID =
        case erlang:is_binary(RouteID0) of
            true -> erlang:binary_to_list(RouteID0);
            false -> RouteID0
        end,
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => maps:get(net_id, InputMap, ?NET_ID_ACTILITY),
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => maps:get(port, InputMap, 3002),
            protocol =>
                {http_roaming, #{
                    flow_type => maps:get(flow_type, InputMap, sync),
                    dedupe_timeout => maps:get(dedupe_timeout, InputMap, 250),
                    path => "/uplink",
                    auth_header => maps:get(auth_header, InputMap, null),
                    receiver_nsid => "test-uplink-receiver-id"
                }}
        },
        max_copies => 2
    }),
    ok = hpr_route_storage:insert(Route),

    EUIPairs = maps:get(euis, InputMap, []),
    ok = lists:foreach(
        fun(Pair) ->
            hpr_eui_pair_storage:insert(hpr_eui_pair:test_new(Pair#{route_id => RouteID}))
        end,
        EUIPairs
    ),

    DevAddrRanges = maps:get(
        devaddr_ranges,
        InputMap,
        [
            #{
                start_addr => 16#04ABCDEF,
                end_addr => 16#04ABCDFF
            }
        ]
    ),
    ok = lists:foreach(
        fun(Range) ->
            hpr_devaddr_range_storage:insert(
                hpr_devaddr_range:test_new(Range#{route_id => RouteID})
            )
        end,
        DevAddrRanges
    ),

    ok.

downlink_test_route(FlowType) ->
    Route = hpr_route:test_new(#{
        id => "1",
        net_id => ?NET_ID_ACTILITY,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 3002,
            protocol => {http_roaming, #{flow_type => FlowType, path => "/uplink"}}
        },
        max_copies => 1
    }),
    ok = hpr_route_storage:insert(Route).

downlink_test_body(TransactionID, DownlinkPayload, Token, PubKeyBin) ->
    DownlinkBody = #{
        'ProtocolVersion' => <<"1.1">>,
        'SenderID' => hpr_http_roaming_utils:hexstring(?NET_ID_ACTILITY),
        'ReceiverID' => <<"0xC00053">>,
        'SenderNSID' => <<"downlink-test-body-sender-nsid">>,
        'ReceiverNSID' => hpr_utils:sender_nsid(),
        'TransactionID' => TransactionID,
        'MessageType' => <<"XmitDataReq">>,
        'PHYPayload' => hpr_http_roaming_utils:binary_to_hexstring(DownlinkPayload),
        'DLMetaData' => #{
            'DevEUI' => <<"0xaabbffccfeeff001">>,
            'DLFreq1' => 915.0,
            'DataRate1' => 0,
            'RXDelay1' => 1,
            'FNSULToken' => Token,
            'GWInfo' => [
                #{'ULToken' => libp2p_crypto:bin_to_b58(PubKeyBin)}
            ],
            'ClassMode' => <<"A">>,
            'HiPriorityFlag' => false
        }
    },
    DownlinkBody.

%% ------------------------------------------------------------------
%% Elli Handler
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
    %% NOTE: This function is acting as the downlink handler that is being
    %% written in rust to broadcast messages.
    Forward = maps:get(forward, Args),
    Body = elli_request:body(Req),
    #{
        <<"DLMetaData">> := #{<<"FNSULToken">> := Token}
    } = Decoded = jsx:decode(Body),

    FlowType = flow_type_from(Token),
    case FlowType of
        async ->
            Forward ! {http_downlink_data, Body},

            Downlink = #http_roaming_downlink_v1_pb{data = Body},
            ok = hpr_test_downlink_service_http_roaming:downlink(Downlink),

            Forward ! {http_downlink_data_response, 200},
            {200, [], <<>>};
        sync ->
            ct:pal("sync handling downlink:~n~p", [Decoded]),

            Downlink = #http_roaming_downlink_v1_pb{data = Body},
            ok = hpr_test_downlink_service_http_roaming:downlink(Downlink),

            Forward ! {http_msg, Body, Req, <<>>},
            {200, [], <<>>}
    end;
handle('POST', [<<"uplink">>], Req, Args) ->
    Forward = maps:get(forward, Args),

    Body = elli_request:body(Req),

    DecodedBody = jsx:decode(Body),
    MessageType = message_type_from_uplink(DecodedBody),

    FlowType =
        case MessageType of
            <<"PRStartReq">> ->
                #{
                    <<"ULMetaData">> := #{<<"FNSULToken">> := Token}
                } = DecodedBody,
                flow_type_from(Token);
            _ ->
                maps:get(flow_type, Args, sync)
        end,

    case message_type_from_uplink_ok(MessageType, FlowType) of
        noop ->
            ct:print("nothing to do for message type"),
            Response = {200, [], jsx:encode(#{})},
            Forward ! {http_msg, Body, Req, Response},
            Forward ! {http_uplink_data, Req},
            Forward ! {http_uplink_data_response, 200},
            Response;
        ok ->
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
                    Forward ! {http_uplink_data, Req},
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
            end
    end.

handle_event(_Event, _Data, _Args) ->
    %% uncomment for Elli errors.
    ct:print("Elli Event (~p):~nData~n~p~nArgs~n~p", [_Event, _Data, _Args]),
    ok.

-spec message_type_from_uplink(UplinkBody :: map()) -> binary().
message_type_from_uplink(#{<<"MessageType">> := MessageType}) ->
    MessageType.

-spec message_type_from_uplink_ok(MessageType :: binary(), FlowType :: sync | async) -> ok | noop.
message_type_from_uplink_ok(<<"XmitDataAns">>, sync) ->
    throw(bad_message_type);
message_type_from_uplink_ok(<<"XmitDataAns">>, async) ->
    noop;
message_type_from_uplink_ok(<<"PRStartReq">>, _FlowType) ->
    ok;
message_type_from_uplink_ok(<<"PRStartNotif">>, _FlowType) ->
    noop;
message_type_from_uplink_ok(_MessageType, _FlowType) ->
    throw(bad_message_type).

-spec flow_type_from(UplinkToken :: binary()) -> sync | async.
flow_type_from(UplinkToken) ->
    {ok, _PubKeyBin, _Region, _PacketTime, RouteID} =
        hpr_http_roaming:parse_uplink_token(UplinkToken),
    case hpr_route_storage:lookup(RouteID) of
        {error, not_found} ->
            throw(could_not_find_route_from_token);
        {ok, RouteETS} ->
            Route = hpr_route_ets:route(RouteETS),
            hpr_route:http_roaming_flow_type(Route)
    end.

make_response_body(#{
    <<"ProtocolVersion">> := ProtocolVersion,
    <<"MessageType">> := <<"PRStartReq">>,
    <<"ReceiverID">> := ReceiverID,
    <<"SenderID">> := SenderID,
    <<"ReceiverNSID">> := ReceiverNSID,
    <<"SenderNSID">> := SenderNSID,
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
        'SenderNSID' => ReceiverNSID,
        'ReceiverNSID' => SenderNSID,
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
    <<"ReceiverNSID">> := ReceiverNSID,
    <<"SenderNSID">> := SenderNSID,
    <<"TransactionID">> := TransactionID,
    <<"ULMetaData">> := #{
        <<"DevAddr">> := _
    }
}) ->
    %% Ack to regular uplink
    #{
        'ProtocolVersion' => ProtocolVersion,
        'SenderID' => ReceiverID,
        'ReceiverID' => <<"0xC00053">>,
        'SenderNSID' => ReceiverNSID,
        'ReceiverNSID' => SenderNSID,
        'TransactionID' => TransactionID,
        'MessageType' => <<"PRStartAns">>,
        'Result' => #{'ResultCode' => <<"Success">>},
        %% 11.3.1 Passive Roaming Start
        %% Step 6: stateless fNS operation
        'Lifetime' => 0
    };
make_response_body(#{<<"MessageType">> := <<"PRStartReq">>} = PRStartReq) ->
    ExpectedKeys = [
        <<"ProtocolVersion">>,
        <<"MessageType">>,
        <<"ReceiverID">>,
        <<"SenderID">>,
        <<"ReceiverNSID">>,
        <<"SenderNSID">>,
        <<"TransactionID">>,
        <<"ULMetaData">>
    ],
    MissingKeys = ExpectedKeys -- maps:keys(PRStartReq),
    throw({pr_start_req_missing_keys, MissingKeys}).

%% ------------------------------------------------------------------
%% Helpers
%% ------------------------------------------------------------------

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

start_roamer_listener(Options) ->
    start_uplink_listener(Options).

gateway_expect_downlink(ExpectFn) ->
    receive
        {packet_down, PacketDown} ->
            ExpectFn(PacketDown)
    after 1000 -> ct:fail(gateway_expect_packet_down_timeout)
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

-spec not_http_rcv(Delay :: integer()) -> ok.
not_http_rcv(Delay) ->
    receive
        {http_msg, _, _} ->
            ct:fail(expected_no_more_http)
    after Delay -> ok
    end.

roamer_expect_uplink_data(Expected) ->
    {ok, Got, Headers} = roamer_expect_uplink_data(),
    case test_utils:match_map(Expected, Got) of
        true ->
            {ok, Got, Headers};
        {false, Reason} ->
            ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
            ct:fail({roamer_expect_uplink_data, Reason})
    end.

roamer_expect_uplink_data() ->
    receive
        {http_uplink_data, Request} ->
            {ok, jsx:decode(elli_request:body(Request)), elli_request:headers(Request)}
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

%% RecvTime is the time the server receives the packet by second granularity.
%% The time from when the packet was constructed in a test to when it's
%% processed may cross the second barrier, leading to inconsistent tests.
%% Downlinks are not calculated from that timestamp, so we want to make sure
%% they're at least within a second of each other.
-spec formatted_timestamp_within_one_second(string()) -> fun((string()) -> boolean()).
formatted_timestamp_within_one_second(Expected) ->
    fun(Incoming) ->
        case Expected == Incoming of
            true ->
                true;
            false ->
                {{_, _, _}, {_, _, Sec1}} = iso8601:parse(Expected),
                {{_, _, _}, {_, _, Sec2}} = iso8601:parse(Incoming),
                erlang:abs(Sec1 - Sec2) =< 1
        end
    end.
