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
    key_matches_mic/2
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

-spec key_matches_mic(Key :: binary(), Payload :: binary()) -> boolean().
key_matches_mic(Key, Payload) ->
    ExpectedMIC = mic(Payload),
    FCnt = fcnt_low(Payload),
    B0 = b0(Payload, FCnt),
    ComputedMIC = crypto:macN(cmac, aes_128_cbc, Key, B0, 4),
    ComputedMIC =:= ExpectedMIC.

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

key_matches_mic_test() ->
    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),
    PacketUp = test_utils:uplink_packet_up(#{
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey
    }),
    Payload = hpr_packet_up:payload(PacketUp),
    ?assert(?MODULE:key_matches_mic(NwkSessionKey, Payload)),
    ?assertNot(?MODULE:key_matches_mic(crypto:strong_rand_bytes(16), Payload)),
    ok.

-endif.
