%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 17. Sep 2022 10:56 AM
%%%-------------------------------------------------------------------
-module(hpr_roaming_utils).
-author("jonathanruttenberg").

-define(RESPONSE_STREAM_ETS, hpr_http_response_stream_ets).
-include_lib("helium_proto/include/packet_pb.hrl").

%% API
-export([
    hexstring/1,
    binary_to_hexstring/1,
    format_time/1,
    uint32/1,
    hexstring_to_binary/1,
    hexstring_to_int/1,
    hexstring/2,
    hex_to_binary/1,
    make_routing_information_pb/1
]).

-export([
    init_ets/0,
    insert_handler/2,
    delete_handler/1,
    lookup_handler/1
]).

-spec binary_to_hex(binary()) -> binary().
binary_to_hex(ID) ->
    <<<<Y>> || <<X:4>> <= ID, Y <- integer_to_list(X, 16)>>.

-spec binary_to_hexstring(number() | binary()) -> binary().
binary_to_hexstring(ID) when erlang:is_number(ID) ->
    binary_to_hexstring(<<ID:32/integer-unsigned>>);
binary_to_hexstring(ID) ->
    <<"0x", (binary_to_hex(ID))/binary>>.

-spec hexstring(number()) -> binary().
hexstring(Bin) when erlang:is_binary(Bin) ->
    binary_to_hexstring(Bin);
hexstring(Num) when erlang:is_number(Num) ->
    Inter0 = erlang:integer_to_binary(Num, 16),
    Inter1 = string:pad(Inter0, 6, leading, $0),
    Inter = erlang:iolist_to_binary(Inter1),
    <<"0x", Inter/binary>>;
hexstring(Other) ->
    throw({unknown_hexstring_conversion, Other}).

-spec hexstring(non_neg_integer(), non_neg_integer()) -> binary().
hexstring(Bin, Length) when erlang:is_binary(Bin) ->
    Inter0 = binary_to_hex(Bin),
    Inter1 = string:pad(Inter0, Length, leading, $0),
    Inter = erlang:iolist_to_binary(Inter1),
    <<"0x", Inter/binary>>;
hexstring(Num, Length) ->
    Inter0 = erlang:integer_to_binary(Num, 16),
    Inter1 = string:pad(Inter0, Length, leading, $0),
    Inter = erlang:iolist_to_binary(Inter1),
    <<"0x", Inter/binary>>.

format_time(Time) ->
    iso8601:format(calendar:system_time_to_universal_time(Time, millisecond)).

-spec uint32(number()) -> 0..4294967295.
uint32(Num) ->
    Num band 16#FFFF_FFFF.

-spec hexstring_to_binary(binary()) -> binary().
hexstring_to_binary(<<"0x", Bin/binary>>) ->
    hex_to_binary(Bin);
hexstring_to_binary(Bin) when erlang:is_binary(Bin) ->
    hex_to_binary(Bin);
hexstring_to_binary(_Invalid) ->
    throw({invalid_hexstring_binary, _Invalid}).

-spec hexstring_to_int(binary()) -> integer().
hexstring_to_int(<<"0x", Num/binary>>) ->
    erlang:binary_to_integer(Num, 16);
hexstring_to_int(Bin) ->
    erlang:binary_to_integer(Bin, 16).

-spec hex_to_binary(binary()) -> binary().
hex_to_binary(ID) ->
    <<<<Z>> || <<X:8, Y:8>> <= ID, Z <- [erlang:binary_to_integer(<<X, Y>>, 16)]>>.

-spec make_routing_information_pb(hpr_routing:routing_info()) -> #routing_information_pb{}.
make_routing_information_pb({devaddr, DevAddr}) ->
    #routing_information_pb{data = {devaddr, DevAddr}};
make_routing_information_pb({eui, DevEUI, AppEUI}) ->
    #routing_information_pb{data = {eui, #eui_pb{deveui = DevEUI, appeui = AppEUI}}}.

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
    TransactionID :: integer(), ResponseStream :: hpr_router_stream_manager:gateway_stream()
) -> ok.
insert_handler(TransactionID, ResponseStream) ->
    true = ets:insert(?RESPONSE_STREAM_ETS, {TransactionID, ResponseStream}),
    ok.

-spec delete_handler(TransactionID :: integer()) -> ok.
delete_handler(TransactionID) ->
    true = ets:delete(?RESPONSE_STREAM_ETS, TransactionID),
    ok.

-spec lookup_handler(TransactionID :: integer()) ->
    {ok, ResponseStream :: hpr_router_stream_manager:gateway_stream()} | {error, any()}.
lookup_handler(TransactionID) ->
    case ets:lookup(?RESPONSE_STREAM_ETS, TransactionID) of
        [{_, ResponseStream}] -> {ok, ResponseStream};
        [] -> {error, {not_found, TransactionID}}
    end.
