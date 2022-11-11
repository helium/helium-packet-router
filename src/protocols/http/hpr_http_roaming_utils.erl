%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs
%%% @doc
%%%
%%% @end
%%% Created : 17. Sep 2022 10:56 AM
%%%-------------------------------------------------------------------
-module(hpr_http_roaming_utils).
-author("jonathanruttenberg").

-define(RESPONSE_STREAM_ETS, hpr_http_response_stream_ets).

%% API
-export([
    hexstring/1,
    binary_to_hexstring/1,
    format_time/1,
    uint32/1,
    hexstring_to_binary/1,
    hexstring_to_int/1,
    hexstring/2
]).

-spec binary_to_hexstring(binary()) -> binary().
binary_to_hexstring(ID) ->
    <<"0x", (binary:encode_hex(ID))/binary>>.

-spec hexstring(number() | binary()) -> binary().
hexstring(Bin) when erlang:is_binary(Bin) ->
    binary_to_hexstring(Bin);
hexstring(Num) when erlang:is_number(Num) ->
    hexstring(Num, 6);
hexstring(Other) ->
    throw({unknown_hexstring_conversion, Other}).

-spec hexstring(non_neg_integer(), non_neg_integer()) -> binary().
hexstring(Bin, Length) when erlang:is_binary(Bin) ->
    Inter0 = binary:encode_hex(Bin),
    Inter1 = string:pad(Inter0, Length, leading, $0),
    erlang:iolist_to_binary([<<"0x">>, Inter1]);
hexstring(Num, Length) ->
    Inter0 = erlang:integer_to_binary(Num, 16),
    Inter1 = string:pad(Inter0, Length, leading, $0),
    erlang:iolist_to_binary([<<"0x">>, Inter1]).

-spec format_time(integer()) -> binary().
format_time(Time) ->
    iso8601:format(calendar:system_time_to_universal_time(Time, millisecond)).

-spec uint32(number()) -> 0..4294967295.
uint32(Num) ->
    Num band 16#FFFF_FFFF.

-spec hexstring_to_binary(binary()) -> binary().
hexstring_to_binary(<<"0x", Bin/binary>>) ->
    binary:decode_hex(Bin);
hexstring_to_binary(Bin) when erlang:is_binary(Bin) ->
    binary:decode_hex(Bin);
hexstring_to_binary(_Invalid) ->
    throw({invalid_hexstring_binary, _Invalid}).

-spec hexstring_to_int(binary()) -> integer().
hexstring_to_int(<<"0x", Num/binary>>) ->
    erlang:binary_to_integer(Num, 16);
hexstring_to_int(Bin) ->
    erlang:binary_to_integer(Bin, 16).

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

hexstring_test() ->
    Number = 7,
    EncodedNumber = <<"0x000007">>,
    ResultNumber = hexstring(Number),
    ?assertEqual(EncodedNumber, ResultNumber),

    Binary = <<"f">>,
    EncodedBinary = <<"0x66">>,
    ResultBinary = hexstring(Binary),
    ?assertEqual(EncodedBinary, ResultBinary),

    NotSupported = [1, 5],
    ?assertThrow({unknown_hexstring_conversion, _}, hexstring(NotSupported)).

binary_to_hexstring_test() ->
    Binary = <<"join_accept_payload">>,
    EncodedBinary = <<"0x6A6F696E5F6163636570745F7061796C6F6164">>,
    ?assertEqual(EncodedBinary, binary_to_hexstring(Binary)).

format_time_test() ->
    Now = 1667507573316,
    Formatted = <<"2022-11-03T20:32:53Z">>,

    ?assertEqual(Formatted, format_time(Now)).

uint32_test() ->
    ?assertEqual(16#ffffffff, uint32(16#1ffffffff)).

hexstring_to_binary_test() ->
    ZeroX = <<"0x66">>,
    DecodedBinary = <<"f">>,

    EncodedBinary = <<"0x6A6F696E5F6163636570745F7061796C6F6164">>,
    Binary = <<"join_accept_payload">>,

    NotSupported = [1, 5],

    ?assertEqual(DecodedBinary, hexstring_to_binary(ZeroX)),

    ?assertEqual(Binary, hexstring_to_binary(EncodedBinary)),

    ?assertThrow({invalid_hexstring_binary, _}, hexstring_to_binary(NotSupported)).

hexstring_to_int_test() ->
    ZeroX = <<"0x66">>,
    ZXInt = 16#66,

    Encoded = <<"66">>,
    Integer = ZXInt,

    ?assertEqual(ZXInt, hexstring_to_int(ZeroX)),

    ?assertEqual(Integer, hexstring_to_int(Encoded)).

hexstring_2_test() ->
    DevEUI = 0,
    Encoded = <<"0x0000000000000000">>,
    ?assertEqual(Encoded, hexstring(DevEUI, 16)).

-endif.
