-module(hpr_utils).

-include("hpr.hrl").

-define(HPR_PUBKEY_BIN, hpr_pubkey_bin).
-define(HPR_SENDER_NSID, hpr_sender_nsid).
-define(HPR_B58, hpr_b58).
-define(HPR_SIG_FUN, hpr_sig_fun).

-export([
    gateway_name/1,
    gateway_mac/1,
    int_to_hex_string/1,
    bin_to_hex_string/1,
    hex_to_bin/1,
    pubkeybin_to_mac/1,
    net_id_display/1,
    trace/2,
    stop_trace/1,
    pmap/2, pmap/3,
    %%
    load_key/1,
    pubkey_bin/0,
    sig_fun/0,
    sender_nsid/0,
    b58/0
]).

-type trace() :: gateway | devaddr | app_eui | dev_eui.

-spec load_key(KeyFileName :: string()) -> ok.
load_key(KeyFileName) ->
    {PubKey, SigFun} =
        Key =
        case libp2p_crypto:load_keys(KeyFileName) of
            {ok, #{secret := PrivKey, public := PubKey0}} ->
                {PubKey0, libp2p_crypto:mk_sig_fun(PrivKey)};
            {error, enoent} ->
                KeyMap =
                    #{secret := PrivKey, public := PubKey0} = libp2p_crypto:generate_keys(
                        ed25519
                    ),
                ok = libp2p_crypto:save_keys(KeyMap, KeyFileName),
                {PubKey0, libp2p_crypto:mk_sig_fun(PrivKey)}
        end,

    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
    ok = persistent_term:put(?HPR_PUBKEY_BIN, PubKeyBin),

    %% Keep as binary for http protocol jsx encoding/decoding
    SenderNSID =
        case application:get_env(hpr, http_roaming_sender_nsid, erlang:list_to_binary(B58)) of
            <<"">> -> erlang:list_to_binary(B58);
            Val -> Val
        end,
    ok = persistent_term:put(?HPR_SENDER_NSID, SenderNSID),

    ok = persistent_term:put(?HPR_B58, B58),
    ok = persistent_term:put(?HPR_SIG_FUN, SigFun),
    ok = persistent_term:put(?HPR_KEY, Key).

-spec pubkey_bin() -> libp2p_crypto:pubkey_bin().
pubkey_bin() ->
    persistent_term:get(?HPR_PUBKEY_BIN, undefined).

-spec sig_fun() -> libp2p_crypto:sig_fun().
sig_fun() ->
    persistent_term:get(?HPR_SIG_FUN, undefined).

-spec sender_nsid() -> string().
sender_nsid() ->
    persistent_term:get(?HPR_SENDER_NSID, undefined).

-spec b58() -> binary().
b58() ->
    persistent_term:get(?HPR_B58, undefined).

-spec gateway_name(PubKeyBin :: libp2p_crypto:pubkey_bin() | string()) -> string().
gateway_name(PubKeyBin) when is_binary(PubKeyBin) ->
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
    gateway_name(B58);
gateway_name(B58) when is_list(B58) ->
    {ok, Name} = erl_angry_purple_tiger:animal_name(B58),
    Name.

-spec gateway_mac(PubKeyBin :: libp2p_crypto:pubkey_bin()) -> string().
gateway_mac(PubKeyBin) ->
    erlang:binary_to_list(binary:encode_hex(pubkeybin_to_mac(PubKeyBin))).

-spec int_to_hex_string(Integer :: integer()) -> string().
int_to_hex_string(Integer) ->
    binary:bin_to_list(erlang:integer_to_binary(Integer, 16)).

-spec bin_to_hex_string(binary()) -> string().
bin_to_hex_string(Bin) ->
    binary:bin_to_list(binary:encode_hex(Bin)).

-spec hex_to_bin(binary() | string()) -> binary().
hex_to_bin(Hex) when is_list(Hex) ->
    ?MODULE:hex_to_bin(binary:list_to_bin(Hex));
hex_to_bin(Hex) when is_binary(Hex) ->
    binary:decode_hex(Hex).

-spec pubkeybin_to_mac(binary()) -> binary().
pubkeybin_to_mac(PubKeyBin) ->
    <<(xxhash:hash64(PubKeyBin)):64/unsigned-integer>>.

-spec net_id_display(non_neg_integer()) -> string().
net_id_display(Num) ->
    string:right(erlang:integer_to_list(Num, 16), 6, $0).

-spec trace(Type :: trace(), Data :: string()) -> string().
trace(Type, Data) ->
    FileName = "traces/" ++ Data ++ ".log",
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
    {ok, _} = lager:trace_file(FileName, [{Type, Data}], debug, [
        {formatter_config, FormatStr}
    ]),
    _ = erlang:spawn(fun() ->
        Timeout = application:get_env(hpr, trace_timeout, 240),
        lager:debug([{Type, Data}], "will stop trace in ~pmin", [Timeout]),
        timer:sleep(timer:minutes(Timeout)),
        ?MODULE:stop_trace(Data)
    end),
    FileName.

-spec stop_trace(Data :: string()) -> ok.
stop_trace(Data) ->
    DeviceTraces = get_device_traces(Data),
    lists:foreach(
        fun({F, M, L}) ->
            ok = lager:stop_trace(F, M, L)
        end,
        DeviceTraces
    ),
    ok.

pmap(F, L) ->
    Width = validation_width(),
    pmap(F, L, Width).

pmap(F, L, Width) ->
    Parent = self(),
    Len = erlang:length(L),
    Min = erlang:floor(Len / Width),
    Rem = Len rem Width,
    Lengths = lists:duplicate(Rem, Min + 1) ++ lists:duplicate(Width - Rem, Min),
    OL = partition_list(L, Lengths, []),
    St = lists:foldl(
        fun
            ([], N) ->
                N;
            (IL, N) ->
                erlang:spawn_opt(
                    fun() ->
                        Parent ! {pmap, N, lists:map(F, IL)}
                    end,
                    [{fullsweep_after, 0}]
                ),
                N + 1
        end,
        0,
        OL
    ),
    L2 = [
        receive
            {pmap, N, R} -> {N, R}
        end
     || _ <- lists:seq(1, St)
    ],
    {_, L3} = lists:unzip(lists:keysort(1, L2)),
    lists:flatten(L3).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

partition_list([], [], Acc) ->
    lists:reverse(Acc);
partition_list(L, [0 | T], Acc) ->
    partition_list(L, T, Acc);
partition_list(L, [H | T], Acc) ->
    {Take, Rest} = lists:split(H, L),
    partition_list(Rest, T, [Take | Acc]).

validation_width() ->
    Ct = erlang:system_info(schedulers_online),
    erlang:max(2, erlang:ceil(Ct / 2) + 1).

-spec get_device_traces(Data :: string()) ->
    list({{lager_file_backend, string()}, list(), atom()}).
get_device_traces(Data) ->
    Sinks = lists:sort(lager:list_all_sinks()),
    Traces = lists:foldl(
        fun(S, Acc) ->
            {_Level, Traces} = lager_config:get({S, loglevel}),
            Acc ++ lists:map(fun(T) -> {S, T} end, Traces)
        end,
        [],
        Sinks
    ),
    lists:filtermap(
        fun(Trace) ->
            {_Sink, {{_All, Meta}, Level, Backend}} = Trace,
            case Backend of
                {lager_file_backend, File} ->
                    case
                        binary:match(binary:list_to_bin(File), binary:list_to_bin(Data)) =/= nomatch
                    of
                        false ->
                            false;
                        true ->
                            LevelName =
                                case Level of
                                    {mask, Mask} ->
                                        case lager_util:mask_to_levels(Mask) of
                                            [] -> none;
                                            Levels -> hd(Levels)
                                        end;
                                    Num ->
                                        lager_util:num_to_level(Num)
                                end,
                            {true, {Backend, Meta, LevelName}}
                    end;
                _ ->
                    false
            end
        end,
        Traces
    ).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

trace_test() ->
    application:ensure_all_started(lager),
    application:set_env(lager, log_root, "log"),

    Gateway = "happy-yellow-bird",
    _ = trace(gateway, Gateway),
    ?assert([] =/= get_device_traces(Gateway)),

    [{{Backend, _}, MD, Lvl}] = get_device_traces(Gateway),
    ?assertEqual(lager_file_backend, Backend),
    ?assertEqual([{gateway, '=', Gateway}], MD),
    ?assertEqual(debug, Lvl),

    ok = stop_trace(Gateway),
    ?assertEqual([], get_device_traces(Gateway)),

    application:stop(lager),
    ok.

-endif.
