%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs
%%% @doc
%%%
%%% @end
%%% Created : 18. Sep 2022 12:22 PM
%%%-------------------------------------------------------------------
-module(hpr_lorawan).
-author("jonathanruttenberg").

-export([
    index_to_datarate/2,
    datarate_to_index/2,
    match_session_key/2
]).

-type temp_datarate_index() :: non_neg_integer().

-spec index_to_datarate(Region :: atom(), DRIndex :: temp_datarate_index()) -> atom().
index_to_datarate(Region, DRIndex) ->
    Plan = lora_plan:region_to_plan(Region),
    lora_plan:datarate_to_atom(Plan, DRIndex).

-spec datarate_to_index(Region :: atom(), DR :: atom()) -> integer().
datarate_to_index(Region, DR) ->
    Plan = lora_plan:region_to_plan(Region),
    lora_plan:datarate_to_index(Plan, DR).

%%--------------------------------------------------------------------
%% @doc
%%
%% The Frame Counter in a payload uses 16 bits, but the MIC is calculated with a
%% 32 bit version of the Frame Counter. Here we check the MIC, adding up to 3
%% additional bits to the Frame Counter to see if we are dealing with a device
%% with an fcnt over 2^16.
%%
%% @end
%%--------------------------------------------------------------------
%% @doc Which of these session keys authenticates the payload, if any.
%%
%% Takes the whole candidate set rather than one key, so the frame-counter
%% search can be the outer loop. The previous shape -- one key at a time, all 8
%% counter candidates each -- made every *wrong* key cost 8 CMACs, because the
%% search only short-circuits on a match. On a route where one DevAddr carries
%% ~1,000 session keys (a small DevAddr block multiplexed across many devices,
%% which is what SKFs are for) that was ~4,300 CMACs per uplink at ~1.6us each.
%%
%% Inverted, a wrong key costs one CMAC on the first pass, and `b0/2' -- which
%% depends on the payload and counter but not the key -- is built 8 times per
%% packet instead of 8 times per key. Counter candidate 0 is tried first and is
%% correct for any device below 65,536 messages, so in practice the first pass
%% finds it: ~500 CMACs instead of ~4,300.
%%
%% One behavioural note: before, the first key in table order that matched at
%% *any* counter candidate won; now the lowest counter candidate wins across all
%% keys. That differs only if two distinct keys both produce a valid 4-byte MIC
%% for the same payload at different counters (~2e-6 per packet here). Both
%% orders are arbitrary in that case; this one prefers the likelier counter.
-spec match_session_key(Payload :: binary(), Keys :: [binary()]) ->
    {ok, binary()} | false.
match_session_key(Payload, Keys) ->
    ExpectedMIC = mic(Payload),
    FCntLow = fcnt_low(Payload),
    match_fcnt(Payload, Keys, ExpectedMIC, FCntLow, lists:seq(2#000, 2#111)).

-spec match_fcnt(
    Payload :: binary(),
    Keys :: [binary()],
    ExpectedMIC :: binary(),
    FCntLow :: non_neg_integer(),
    HighBitCandidates :: [non_neg_integer()]
) -> {ok, binary()} | false.
match_fcnt(_Payload, _Keys, _ExpectedMIC, _FCntLow, []) ->
    false;
match_fcnt(Payload, Keys, ExpectedMIC, FCntLow, [HighBits | Rest]) ->
    FCnt = binary:decode_unsigned(
        <<FCntLow:16/integer-unsigned-little, HighBits:16/integer-unsigned-little>>,
        little
    ),
    B0 = b0(Payload, FCnt),
    case match_keys(B0, ExpectedMIC, Keys) of
        {ok, _} = OK -> OK;
        false -> match_fcnt(Payload, Keys, ExpectedMIC, FCntLow, Rest)
    end.

-spec match_keys(B0 :: binary(), ExpectedMIC :: binary(), Keys :: [binary()]) ->
    {ok, binary()} | false.
match_keys(_B0, _ExpectedMIC, []) ->
    false;
match_keys(B0, ExpectedMIC, [Key | Keys]) ->
    case crypto:macN(cmac, aes_128_cbc, Key, B0, 4) of
        ExpectedMIC -> {ok, Key};
        _ -> match_keys(B0, ExpectedMIC, Keys)
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec mic(Payload :: binary()) -> binary().
mic(Payload) ->
    PayloadSize = byte_size(Payload),
    Part = {PayloadSize, -4},
    MIC = binary:part(Payload, Part),
    MIC.

-spec b0(Payload :: binary(), FCnt :: non_neg_integer()) -> binary().
b0(Payload, FCnt) ->
    <<MType:3, _:5, DevAddr:4/binary, _:4, FOptsLen:4, _:16, _FOpts:FOptsLen/binary, _/binary>> =
        Payload,
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload) - 4}),
    <<
        (b0(
            MType band 1,
            <<DevAddr:4/binary>>,
            FCnt,
            erlang:byte_size(Msg)
        ))/binary,
        Msg/binary
    >>.

-spec b0(integer(), binary(), integer(), integer()) -> binary().
b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0, 0, 0, 0, Dir, DevAddr:4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

-spec fcnt_low(Payload :: binary()) -> non_neg_integer().
fcnt_low(Payload) ->
    <<_Mhdr:1/binary, _DevAddr:4/binary, _FCtrl:1/binary, FCntLow:16/integer-unsigned-little,
        _/binary>> = Payload,
    FCntLow.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

match_session_key_test() ->
    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),
    PacketUp = test_utils:uplink_packet_up(#{
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey
    }),
    Payload = hpr_packet_up:payload(PacketUp),
    Decoys = [crypto:strong_rand_bytes(16) || _ <- lists:seq(1, 50)],

    ?assertEqual({ok, NwkSessionKey}, ?MODULE:match_session_key(Payload, [NwkSessionKey])),
    ?assertEqual(false, ?MODULE:match_session_key(Payload, Decoys)),
    ?assertEqual(false, ?MODULE:match_session_key(Payload, [])),

    %% Found wherever it sits in the candidate set -- the real route has ~1,000
    %% candidates per DevAddr, so position must not matter.
    ?assertEqual(
        {ok, NwkSessionKey}, ?MODULE:match_session_key(Payload, [NwkSessionKey | Decoys])
    ),
    ?assertEqual(
        {ok, NwkSessionKey}, ?MODULE:match_session_key(Payload, Decoys ++ [NwkSessionKey])
    ),
    {Front, Back} = lists:split(25, Decoys),
    ?assertEqual(
        {ok, NwkSessionKey},
        ?MODULE:match_session_key(Payload, Front ++ [NwkSessionKey] ++ Back)
    ),
    ok.

%% The frame-counter high-bit search is what the loop inversion reorders, so a
%% payload whose counter has overflowed 16 bits has to still be found -- and
%% still be found when it is not the only candidate.
match_session_key_overflow_fcnt_test() ->
    %% Valid frame count for this payload is 197,444
    Payload =
        <<64, 143, 1, 0, 72, 0, 68, 3, 1, 107, 147, 204, 92, 31, 53, 22, 254, 104, 129, 196, 14, 73,
            57, 180, 67, 70, 109, 93, 137, 45, 173, 198, 24, 151, 136, 175, 126, 159, 139, 153, 11,
            69, 209, 224, 164, 240, 78, 109, 116, 196, 41, 138, 113, 244, 180, 164, 241, 235, 133,
            107, 148, 40, 82, 15, 90, 131, 171, 65, 219, 243, 33, 5, 94, 9, 109, 123, 9, 210, 192,
            197, 158, 68, 159, 209, 235, 187, 62, 226, 106, 22, 156, 233, 59, 226, 189, 61, 129,
            179, 25, 227, 75, 146, 69, 46, 185, 99, 24, 69, 171, 111, 164, 223, 178, 177, 45, 237,
            233, 156, 126, 249, 1, 208, 204, 167, 230, 52, 33, 238, 211, 119, 186, 76, 194, 82, 92,
            236, 6, 215>>,

    SessionKey = <<236, 133, 99, 189, 240, 193, 99, 222, 40, 78, 176, 12, 120, 166, 83, 214>>,
    Decoys = [crypto:strong_rand_bytes(16) || _ <- lists:seq(1, 50)],
    ?assertEqual({ok, SessionKey}, ?MODULE:match_session_key(Payload, [SessionKey])),
    ?assertEqual(
        {ok, SessionKey}, ?MODULE:match_session_key(Payload, Decoys ++ [SessionKey | Decoys])
    ),
    ?assertEqual(false, ?MODULE:match_session_key(Payload, Decoys)).

-endif.
