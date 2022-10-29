%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
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

-export([
    init_ets/0,
    insert_handler/2,
    delete_handler/1,
    lookup_handler/1
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

-spec init_ets() -> ok.
init_ets() ->
    ?RESPONSE_STREAM_ETS = ets:new(?RESPONSE_STREAM_ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    ok.

-spec insert_handler(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    ResponseStream :: hpr_http_roaming:gateway_stream()
) -> ok.
insert_handler(PubKeyBin, ResponseStream) ->
    true = ets:insert(?RESPONSE_STREAM_ETS, {PubKeyBin, ResponseStream}),
    ok.

-spec delete_handler(PubKeyBin :: libp2p_crypto:pubkey_bin()) -> ok.
delete_handler(PubKeyBin) ->
    true = ets:delete(?RESPONSE_STREAM_ETS, PubKeyBin),
    ok.

-spec lookup_handler(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    {ok, ResponseStream :: hpr_http_roaming:gateway_stream()} | {error, any()}.
lookup_handler(PubKeyBin) ->
    case ets:lookup(?RESPONSE_STREAM_ETS, PubKeyBin) of
        [{_, ResponseStream}] -> {ok, ResponseStream};
        [] -> {error, {not_found, PubKeyBin}}
    end.
