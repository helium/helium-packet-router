-module(test_utils).

-export([
    init_per_testcase/2,
    end_per_testcase/2,
    join_packet_up/1,
    uplink_packet_up/1
]).

-include("hpr.hrl").

-define(JOIN_REQUEST, 2#000).
-define(UNCONFIRMED_UP, 2#010).
-define(CONFIRMED_UP, 2#100).

init_per_testcase(TestCase, Config) ->
    %% Setup base directory
    BaseDir = erlang:atom_to_list(TestCase) ++ "_data",
    ok = application:set_env(?APP, base_dir, BaseDir),

    %% Start HPR
    application:ensure_all_started(?APP),

    Config.

end_per_testcase(_TestCase, Config) ->
    application:stop(?APP),
    Config.

-spec join_packet_up(
    Opts :: map()
) -> hpr_packet_up:packet().
join_packet_up(Opts0) ->
    DevNonce = maps:get(dev_nonce, Opts0, crypto:strong_rand_bytes(2)),
    AppKey = maps:get(dev_nonce, Opts0, crypto:strong_rand_bytes(16)),
    MType = ?JOIN_REQUEST,
    MHDRRFU = 0,
    Major = 0,
    AppEUI = maps:get(app_eui, Opts0, 1),
    DevEUI = maps:get(dev_eui, Opts0, 1),
    JoinPayload0 =
        <<MType:3, MHDRRFU:3, Major:2, AppEUI:64/integer-unsigned-little,
            DevEUI:64/integer-unsigned-little, DevNonce:2/binary>>,
    MIC = crypto:macN(cmac, aes_128_cbc, AppKey, JoinPayload0, 4),
    JoinPayload1 = <<JoinPayload0/binary, MIC:4/binary>>,
    Opts1 = maps:put(payload, maps:get(payload, Opts0, JoinPayload1), Opts0),
    PacketUp = hpr_packet_up:new(Opts1),
    SigFun = maps:get(sig_fun, Opts0, fun(_) -> <<"signature">> end),
    hpr_packet_up:sign(PacketUp, SigFun).

-spec uplink_packet_up(
    Opts :: map()
) -> hpr_packet_up:packet().
uplink_packet_up(Opts0) ->
    MType = ?UNCONFIRMED_UP,
    MHDRRFU = 0,
    Major = 0,
    DevAddr = maps:get(devaddr, Opts0, 16#00000000),
    ADR = 0,
    ADRACKReq = 0,
    ACK = 0,
    RFU = 0,
    FCntLow = 1,
    FOptsBin = <<>>,
    FOptsLen = erlang:byte_size(FOptsBin),
    Port = 0,
    Data = <<"dataandmic">>,
    Payload =
        <<MType:3, MHDRRFU:3, Major:2, DevAddr:32/integer-unsigned-little, ADR:1, ADRACKReq:1,
            ACK:1, RFU:1, FOptsLen:4, FCntLow:16/little-unsigned-integer, FOptsBin:FOptsLen/binary,
            Port:8/integer, Data/binary>>,
    Opts1 = maps:put(payload, maps:get(payload, Opts0, Payload), Opts0),
    PacketUp = hpr_packet_up:new(Opts1),
    SigFun = maps:get(sig_fun, Opts0, fun(_) -> <<"signature">> end),
    hpr_packet_up:sign(PacketUp, SigFun).