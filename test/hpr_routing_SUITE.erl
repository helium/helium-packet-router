-module(hpr_routing_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    join_req_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("helium_proto/include/packet_router_pb.hrl").
-include("hpr.hrl").

-define(JOIN_REQUEST, 2#000).
-define(UNCONFIRMED_UP, 2#010).
-define(CONFIRMED_UP, 2#100).

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
        join_req_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(_TestCase, Config) ->
    ok = application:set_env(?APP, base_dir, "data/hpr"),
    application:ensure_all_started(?APP),
    Config.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, Config) ->
    application:stop(?APP),
    Config.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

join_req_test(_Config) ->
    Self = self(),

    PacketBadSig = #packet_router_packet_up_v1_pb{
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
    },
    ?assertEqual({error, bad_signature}, hpr_routing:handle_packet(PacketBadSig, Self)),
    receive
        {error, bad_signature} -> ok;
        Other0 -> ct:fail(Other0)
    after 100 ->
        ct:fail("bad_signature, timeout")
    end,

    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Hotspot = libp2p_crypto:pubkey_to_bin(PubKey),

    PacketUpInvalid0 = #packet_router_packet_up_v1_pb{
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
    },
    PacketUpInvalid1 = PacketUpInvalid0#packet_router_packet_up_v1_pb{hotspot = Hotspot},
    PacketUpInvalidEncoded = hpr_packet_up:encode(PacketUpInvalid1#packet_router_packet_up_v1_pb{
        signature = <<>>
    }),
    PacketUpInvalidSigned = PacketUpInvalid1#packet_router_packet_up_v1_pb{
        signature = SigFun(PacketUpInvalidEncoded)
    },
    ?assertEqual(
        {error, invalid_packet_type}, hpr_routing:handle_packet(PacketUpInvalidSigned, Self)
    ),
    receive
        {error, invalid_packet_type} -> ok;
        Other1 -> ct:fail(Other1)
    after 100 ->
        ct:fail("invalid_packet_type, timeout")
    end,

    DevNonce = crypto:strong_rand_bytes(2),
    AppKey = crypto:strong_rand_bytes(16),
    MType = ?JOIN_REQUEST,
    MHDRRFU = 0,
    Major = 0,
    AppEUI = 1,
    DevEUI = 2,
    JoinPayload0 =
        <<MType:3, MHDRRFU:3, Major:2, AppEUI:64/integer-unsigned-little,
            DevEUI:64/integer-unsigned-little, DevNonce:2/binary>>,
    MIC = crypto:macN(cmac, aes_128_cbc, AppKey, JoinPayload0, 4),
    JoinPayload1 = <<JoinPayload0/binary, MIC:4/binary>>,

    PacketUpValid0 = #packet_router_packet_up_v1_pb{
        payload = JoinPayload1,
        timestamp = 0,
        signal_strength = 1.0,
        frequency = 2.0,
        datarate = [],
        snr = 3.0,
        region = 'US915',
        hold_time = 4,
        hotspot = <<"hotspot">>,
        signature = <<"signature">>
    },
    PacketUpValid1 = PacketUpValid0#packet_router_packet_up_v1_pb{hotspot = Hotspot},
    PacketUpValidEncoded = hpr_packet_up:encode(PacketUpValid1#packet_router_packet_up_v1_pb{
        signature = <<>>
    }),
    PacketUpValidSigned = PacketUpValid1#packet_router_packet_up_v1_pb{
        signature = SigFun(PacketUpValidEncoded)
    },
    ?assertEqual(ok, hpr_routing:handle_packet(PacketUpValidSigned, Self)),

    ok.
