%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs
%%% @doc
%%%
%%% @end
%%% Created : 05. Oct 2022 11:31 AM
%%%-------------------------------------------------------------------
-module(hpr_protocol_http_roaming_SUITE).
-author("jonathanruttenberg").

-include("../src/grpc/autogen/server/packet_router_pb.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    rx1_timestamp_test/1,
    rx1_downlink_test/1,
    rx2_downlink_test/1,
    chirpstack_join_accept_test/1,
    class_c_downlink_test/1
]).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        rx1_timestamp_test,
        rx1_downlink_test,
        rx2_downlink_test,
        chirpstack_join_accept_test,
        class_c_downlink_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(_TestCase, Config) ->
    ok = hpr_http_roaming_utils:init_ets(),
    Config.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

class_c_downlink_test(_Config) ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    Self = self(),
    hpr_http_roaming_utils:insert_handler(PubKeyBin, Self),

    Token = hpr_http_roaming:make_uplink_token(
        PubKeyBin,
        'US915',
        erlang:system_time(millisecond),
        <<"www.example.com">>,
        sync
    ),

    Input = #{
        <<"ProtocolVersion">> => <<"1.1">>,
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

    ?assertMatch({downlink, #{}, {Self, _}, _Dest}, hpr_http_roaming:handle_message(Input)),

    ok.

chirpstack_join_accept_test(_Config) ->
    TransactionID = 473719436,
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    hpr_http_roaming_utils:insert_handler(PubKeyBin, self()),

    Token = hpr_http_roaming:make_uplink_token(
        PubKeyBin,
        'US915',
        erlang:system_time(millisecond),
        <<"www.example.com">>,
        sync
    ),

    A = #{
        <<"ProtocolVersion">> => <<"1.1">>,
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
    Self = self(),
    ?assertMatch({join_accept, {Self, _}}, hpr_http_roaming:handle_message(A)),

    ok.

rx1_timestamp_test(_Config) ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    ok = hpr_http_roaming_utils:insert_handler(PubKeyBin, self()),

    PacketTime = 0,
    Token = hpr_http_roaming:make_uplink_token(
        PubKeyBin,
        'US915',
        PacketTime,
        <<"www.example.com">>,
        sync
    ),

    MakeInput = fun(RXDelay) ->
        #{
            <<"ProtocolVersion">> => <<"1.1">>,
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
            {downlink, _, {_, DownlinkPacket}, _} = hpr_http_roaming:handle_xmitdata_req(Input),
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

rx1_downlink_test(_Config) ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    ok = hpr_http_roaming_utils:insert_handler(PubKeyBin, self()),

    Payload = <<"0x60c04e26e020000000a754ba934840c3bc120989b532ee4613e06e3dd5d95d9d1ceb9e20b1f2">>,
    RXDelay = 2,
    FrequencyMhz = 925.1,
    DataRate = 10,

    Token = hpr_http_roaming:make_uplink_token(
        PubKeyBin,
        'US915',
        erlang:system_time(millisecond),
        <<"www.example.com">>,
        sync
    ),

    Input = #{
        <<"ProtocolVersion">> => <<"1.1">>,
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

    {downlink, _Output, {Pid, DownlinkPacket}, _Dest} = hpr_http_roaming:handle_xmitdata_req(
        Input
    ),
    ?assertEqual(Pid, self()),

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

rx2_downlink_test(_Config) ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    ok = hpr_http_roaming_utils:insert_handler(PubKeyBin, self()),

    Token = hpr_http_roaming:make_uplink_token(
        PubKeyBin,
        'US915',
        erlang:system_time(millisecond),
        <<"www.example.com">>,
        sync
    ),

    Input = #{
        <<"ProtocolVersion">> => <<"1.1">>,
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

    {downlink, _Output, {Pid, DownlinkPacket}, _Dest} = hpr_http_roaming:handle_xmitdata_req(
        Input
    ),
    ?assertEqual(Pid, self()),

    DatarateFromDownlinkPacket =
        hpr_packet_down:rx2_datarate(DownlinkPacket),

    ?assertEqual(
        hpr_lorawan:index_to_datarate('US915', 8),
        DatarateFromDownlinkPacket
    ),

    FrequencyFromDownlinkPacket = hpr_packet_down:rx2_frequency(DownlinkPacket),
    ?assertMatch({A, B} when A == B, {923_300_000, FrequencyFromDownlinkPacket}),
    ok.
