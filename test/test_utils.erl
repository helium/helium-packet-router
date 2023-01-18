-module(test_utils).

-export([
    init_per_testcase/2,
    end_per_testcase/2,
    join_packet_up/1,
    uplink_packet_up/1,
    wait_until/1, wait_until/3,
    match_map/2
]).

-include("hpr.hrl").

-define(JOIN_REQ, 2#000).
-define(JOIN_ACCEPT, 2#001).
-define(CONFIRMED_UP, 2#100).
-define(UNCONFIRMED_UP, 2#010).
-define(CONFIRMED_DOWN, 2#101).
-define(UNCONFIRMED_DOWN, 2#011).
-define(RFU, 2#110).
-define(PRIORITY, 2#111).

-define(CONFIG_SERVICE_PORT, 8085).

init_per_testcase(TestCase, Config) ->
    Suite = proplists:get_value(suite, proplists:get_value(tc_group_properties, Config)),
    BaseDir = filename:join([Suite, TestCase]),
    KeyFilePath = filename:join([BaseDir, "hpr.key"]),
    ok = application:set_env(hpr, key, KeyFilePath, [{persistent, true}]),

    ct:pal("BaseDir ~p", [BaseDir]),

    FormatStr = [
        "[",
        date,
        " ",
        time,
        "] ",
        pid,
        " [",
        severity,
        "] [",
        {module, ""},
        {function, [":", function], ""},
        {line, [":", line], ""},
        "] ",
        message,
        "\n",
        metadata,
        "\n\n"
    ],
    ok = application:set_env(lager, log_root, BaseDir),
    case os:getenv("CT_LAGER", "NONE") of
        "DEBUG" ->
            ok = application:set_env(
                lager,
                handlers,
                [
                    {lager_console_backend, [
                        {level, debug},
                        {formatter_config, FormatStr}
                    ]},
                    {lager_file_backend, [
                        {file, "hpr.log"},
                        {level, debug},
                        {formatter_config, FormatStr}
                    ]}
                ]
            );
        _ ->
            ok = application:set_env(
                lager,
                handlers,
                [
                    {lager_file_backend, [
                        {file, "hpr.log"},
                        {level, debug},
                        {formatter_config, FormatStr}
                    ]}
                ]
            )
    end,
    _ = application:ensure_all_started(lager),

    %% Startup a config service test server (look at ct.config)
    _ = application:ensure_all_started(grpcbox),

    %% Setup route worker
    FilePath = filename:join([BaseDir, "route_worker.backup"]),
    application:set_env(
        hpr,
        iot_config_service,
        #{
            transport => http,
            host => "localhost",
            port => ?CONFIG_SERVICE_PORT,
            route => #{
                file_backup_path => FilePath
            }
        },
        [{persistent, true}]
    ),

    application:ensure_all_started(?APP),

    ok = test_utils:wait_until(
        fun() ->
            {state, Stream, _File, _Backoff} = sys:get_state(hpr_route_stream_worker),
            Stream =/= undefined andalso
                erlang:is_pid(erlang:whereis(hpr_test_iot_config_service_route))
        end,
        20,
        500
    ),
    ok = test_utils:wait_until(
        fun() ->
            {state, Stream, _Backoff} = sys:get_state(hpr_skf_stream_worker),
            Stream =/= undefined andalso
                erlang:is_pid(erlang:whereis(hpr_test_iot_config_service_skf))
        end,
        20,
        500
    ),

    [{router_worker_file_backup_path, FilePath} | Config].

end_per_testcase(_TestCase, Config) ->
    application:stop(?APP),
    application:stop(throttle),
    application:stop(lager),
    application:stop(grpcbox),
    Config.

-spec join_packet_up(
    Opts :: map()
) -> hpr_packet_up:packet().
join_packet_up(Opts0) ->
    DevNonce = maps:get(dev_nonce, Opts0, crypto:strong_rand_bytes(2)),
    AppKey = maps:get(app_key, Opts0, crypto:strong_rand_bytes(16)),
    MType = ?JOIN_REQ,
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
    PacketUp = hpr_packet_up:test_new(Opts1),
    SigFun = maps:get(sig_fun, Opts0, fun(_) -> <<"signature">> end),
    hpr_packet_up:sign(PacketUp, SigFun).

-spec uplink_packet_up(
    Opts :: map()
) -> hpr_packet_up:packet().
uplink_packet_up(Opts0) ->
    MType = maps:get(mtype, Opts0, ?UNCONFIRMED_UP),
    MHDRRFU = 0,
    Major = 0,
    DevAddr = maps:get(devaddr, Opts0, 16#00000000),
    ADR = 0,
    ADRACKReq = 0,
    ACK = 0,
    RFU = 0,
    FCnt = maps:get(fcnt, Opts0, 1),
    FOptsBin = <<>>,
    FOptsLen = erlang:byte_size(FOptsBin),
    Port = 0,
    Body = maps:get(data, Opts0, <<"data">>),
    AppSessionKey = maps:get(
        app_session_key,
        Opts0,
        crypto:strong_rand_bytes(16)
    ),
    Data = reverse(
        cipher(Body, AppSessionKey, MType band 1, DevAddr, FCnt)
    ),
    Payload0 =
        <<MType:3, MHDRRFU:3, Major:2, DevAddr:32/little-unsigned-integer, ADR:1, ADRACKReq:1,
            ACK:1, RFU:1, FOptsLen:4, FCnt:16/little-unsigned-integer, FOptsBin:FOptsLen/binary,
            Port:8/integer, Data/binary>>,
    B0 = b0(MType band 1, DevAddr, FCnt, erlang:byte_size(Payload0)),
    NwkSessionKey = maps:get(
        nwk_session_key,
        Opts0,
        crypto:strong_rand_bytes(16)
    ),
    MIC = crypto:macN(cmac, aes_128_cbc, NwkSessionKey, <<B0/binary, Payload0/binary>>, 4),

    Payload = <<Payload0/binary, MIC:4/binary>>,
    Opts1 = maps:put(payload, maps:get(payload, Opts0, Payload), Opts0),
    PacketUp = hpr_packet_up:test_new(Opts1),
    SigFun = maps:get(sig_fun, Opts0, fun(_) -> <<"signature">> end),
    hpr_packet_up:sign(PacketUp, SigFun).

-spec match_map(map(), any()) -> true | {false, term()}.
match_map(Expected, Got) when is_map(Got) ->
    ESize = maps:size(Expected),
    GSize = maps:size(Got),
    case ESize == GSize of
        false ->
            Flavor =
                case ESize > GSize of
                    true -> {missing_keys, maps:keys(Expected) -- maps:keys(Got)};
                    false -> {extra_keys, maps:keys(Got) -- maps:keys(Expected)}
                end,
            {false, {size_mismatch, {expected, ESize}, {got, GSize}, Flavor}};
        true ->
            maps:fold(
                fun
                    (_K, _V, {false, _} = Acc) ->
                        Acc;
                    (K, V, true) when is_function(V) ->
                        case V(maps:get(K, Got, undefined)) of
                            true ->
                                true;
                            false ->
                                {false, {value_predicate_failed, K, maps:get(K, Got, undefined)}}
                        end;
                    (K, '_', true) ->
                        case maps:is_key(K, Got) of
                            true -> true;
                            false -> {false, {missing_key, K}}
                        end;
                    (K, V, true) when is_map(V) ->
                        match_map(V, maps:get(K, Got, #{}));
                    (K, V0, true) when is_list(V0) ->
                        V1 = lists:zip(lists:seq(1, erlang:length(V0)), lists:sort(V0)),
                        G0 = maps:get(K, Got, []),
                        G1 = lists:zip(lists:seq(1, erlang:length(G0)), lists:sort(G0)),
                        match_map(maps:from_list(V1), maps:from_list(G1));
                    (K, V, true) ->
                        case maps:get(K, Got, undefined) of
                            V -> true;
                            _ -> {false, {value_mismatch, K, V, maps:get(K, Got, undefined)}}
                        end
                end,
                true,
                Expected
            )
    end;
match_map(_Expected, _Got) ->
    {false, not_map}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
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
    Bin = <<DevAddr:32/integer-unsigned-big>>,
    <<16#01, 0, 0, 0, 0, Dir, Bin:4/binary, FCnt:32/little-unsigned-integer, 0, I>>.

-spec binxor(binary(), binary(), binary()) -> binary().
binxor(<<>>, <<>>, Acc) ->
    Acc;
binxor(<<A, RestA/binary>>, <<B, RestB/binary>>, Acc) ->
    binxor(RestA, RestB, <<(A bxor B), Acc/binary>>).

-spec b0(integer(), integer(), integer(), integer()) -> binary().
b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0, 0, 0, 0, Dir, DevAddr:32/little-unsigned-integer, FCnt:32/little-unsigned-integer,
        0, Len>>.

wait_until(Fun) ->
    wait_until(Fun, 100, 100).

wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        {fail, _Reason} = Fail ->
            Fail;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry - 1, Delay)
    end.
