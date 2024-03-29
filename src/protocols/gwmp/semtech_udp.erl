%%%-------------------------------------------------------------------
%% @doc
%% == Semtech basic communication protocol between Lora gateway and server ==
%% See https://github.com/Lora-net/packet_forwarder/blob/master/PROTOCOL.TXT
%% @end
%%%-------------------------------------------------------------------
-module(semtech_udp).

-include("semtech_udp.hrl").

-export([
    push_data/3, push_data/4,
    push_ack/1,
    pull_data/2,
    pull_ack/1,
    pull_resp/2,
    tx_ack/2, tx_ack/3,
    token/0,
    token/1,
    mac/1,
    identifier/1,
    identifier_to_atom/1,
    json_data/1
]).

%%%-------------------------------------------------------------------
%% @doc
%% That packet type is used by the gateway mainly to forward the RF packets
%% received, and associated metadata, to the server.
%% @end
%%%-------------------------------------------------------------------
-spec push_data(
    Token :: binary(),
    MAC :: binary(),
    RXPK :: map()
) -> binary().
push_data(Token, MAC, RXPK) ->
    BinJSX = jsx:encode(#{rxpk => [RXPK]}),
    <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PUSH_DATA:8/integer-unsigned, MAC:8/binary,
        BinJSX/binary>>.

-spec push_data(
    Token :: binary(),
    MAC :: binary(),
    RXPK :: map(),
    Stat :: map()
) -> binary().
push_data(Token, MAC, RXPK, Stat) ->
    BinJSX = jsx:encode(#{rxpk => [RXPK], stat => Stat}),
    <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PUSH_DATA:8/integer-unsigned, MAC:8/binary,
        BinJSX/binary>>.

%%%-------------------------------------------------------------------
%% @doc
%% That packet type is used by the server to acknowledge immediately all the
%% PUSH_DATA packets received.
%% @end
%%%-------------------------------------------------------------------
-spec push_ack(Token :: binary()) -> binary().
push_ack(Token) ->
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_ACK:8/integer-unsigned>>.

%%%-------------------------------------------------------------------
%% @doc
%% That packet type is used by the gateway to poll data from the server.
%% @end
%%%-------------------------------------------------------------------
-spec pull_data(Token :: binary(), MAC :: binary()) -> binary().
pull_data(Token, MAC) ->
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_DATA:8/integer-unsigned, MAC:8/binary>>.

%%%-------------------------------------------------------------------
%% @doc
%% That packet type is used by the server to confirm that the network route is
%% open and that the server can send PULL_RESP packets at any time.
%% @end
%%%-------------------------------------------------------------------
-spec pull_ack(Token :: binary()) -> binary().
pull_ack(Token) ->
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_ACK:8/integer-unsigned>>.

%%%-------------------------------------------------------------------
%% @doc
%% That packet type is used by the server to send RF packets and associated
%% metadata that will have to be emitted by the gateway.
%% @end
%%%-------------------------------------------------------------------
-spec pull_resp(
    Token :: binary(),
    Map :: map()
) -> binary().
pull_resp(Token, Map) ->
    BinJSX = jsx:encode(#{txpk => Map}),
    <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PULL_RESP:8/integer-unsigned, BinJSX/binary>>.

%%%-------------------------------------------------------------------
%% @doc
%% That packet type is used by the gateway to send a feedback to the server
%% to inform if a downlink request has been accepted or rejected by the gateway.
%% The datagram may optionally contain a JSON string to give more details on
%% acknowledge. If no JSON is present (empty string), this means than no error
%% occurred.
%% @end
%%%-------------------------------------------------------------------
-spec tx_ack(
    Token :: binary(),
    MAC :: binary()
) -> binary().
tx_ack(Token, MAC) ->
    tx_ack(Token, MAC, ?TX_ACK_ERROR_NONE).

-spec tx_ack(
    Token :: binary(),
    MAC :: binary(),
    Error :: binary()
) -> binary().
tx_ack(Token, MAC, Error) ->
    Map = #{error => Error},
    BinJSX = jsx:encode(#{txpk_ack => Map}),
    <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?TX_ACK:8/integer-unsigned, MAC:8/binary,
        BinJSX/binary>>.

-spec token() -> binary().
token() ->
    crypto:strong_rand_bytes(2).

-spec token(binary()) -> binary().
token(<<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, _/binary>>) ->
    Token.

-spec mac(binary()) -> binary().
mac(
    <<?PROTOCOL_2:8/integer-unsigned, _Token:2/binary, ?PULL_DATA:8/integer-unsigned, MAC:8/binary>>
) ->
    MAC.

-spec identifier(binary()) -> integer().
identifier(
    <<?PROTOCOL_2:8/integer-unsigned, _Token:2/binary, Identifier:8/integer-unsigned, _/binary>>
) ->
    Identifier.

-spec identifier_to_atom(non_neg_integer()) -> atom().
identifier_to_atom(?PUSH_DATA) ->
    push_data;
identifier_to_atom(?PUSH_ACK) ->
    push_ack;
identifier_to_atom(?PULL_DATA) ->
    pull_data;
identifier_to_atom(?PULL_RESP) ->
    pull_resp;
identifier_to_atom(?PULL_ACK) ->
    pull_ack;
identifier_to_atom(?TX_ACK) ->
    tx_ack.

-spec json_data(
    binary()
) -> map().
json_data(
    <<?PROTOCOL_2:8/integer-unsigned, _Token:2/binary, ?PUSH_DATA:8/integer-unsigned, _MAC:8/binary,
        BinJSX/binary>>
) ->
    jsx:decode(BinJSX, [return_maps]);
json_data(
    <<?PROTOCOL_2:8/integer-unsigned, _Token:2/binary, ?PULL_RESP:8/integer-unsigned,
        BinJSX/binary>>
) ->
    jsx:decode(BinJSX, [return_maps]);
json_data(
    <<?PROTOCOL_2:8/integer-unsigned, _Token:2/binary, ?TX_ACK:8/integer-unsigned, _MAC:8/binary,
        BinJSX/binary>>
) ->
    jsx:decode(BinJSX, [return_maps]).

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

push_data_test() ->
    Token0 = token(),
    MAC0 = crypto:strong_rand_bytes(8),
    Tmst = erlang:system_time(millisecond),
    Payload = <<"payload">>,
    RXPK = #{
        time => iso8601:format(
            calendar:system_time_to_universal_time(Tmst, millisecond)
        ),
        tmst => Tmst,
        freq => 915.2,
        rfch => 0,
        modu => <<"LORA">>,
        datr => <<"datr">>,
        rssi => -80.0,
        lsnr => -10,
        size => erlang:byte_size(Payload),
        data => base64:encode(Payload)
    },
    PushData0 = push_data(Token0, MAC0, RXPK),
    <<?PROTOCOL_2:8/integer-unsigned, Token1:2/binary, Id:8/integer-unsigned, MAC1:8/binary,
        BinJSX0/binary>> = PushData0,
    ?assertEqual(Token1, Token0),
    ?assertEqual(?PUSH_DATA, Id),
    ?assertEqual(MAC0, MAC1),
    ?assertEqual(
        #{
            <<"rxpk">> => [
                #{
                    <<"time">> => iso8601:format(
                        calendar:system_time_to_universal_time(Tmst, millisecond)
                    ),
                    <<"tmst">> => Tmst,
                    <<"freq">> => 915.2,
                    <<"rfch">> => 0,
                    <<"modu">> => <<"LORA">>,
                    <<"datr">> => <<"datr">>,
                    <<"rssi">> => -80.0,
                    <<"lsnr">> => -10,
                    <<"size">> => erlang:byte_size(Payload),
                    <<"data">> => base64:encode(Payload)
                }
            ]
        },
        jsx:decode(BinJSX0, [return_maps])
    ),
    STAT = #{
        regi => 'US_915',
        inde => 123456,
        lati => -121,
        long => 37,
        pubk => "pubkey_b58"
    },
    PushData1 = push_data(Token0, MAC0, RXPK, STAT),
    <<?PROTOCOL_2:8/integer-unsigned, Token1:2/binary, Id:8/integer-unsigned, MAC1:8/binary,
        BinJSX1/binary>> = PushData1,
    ?assertEqual(Token1, Token0),
    ?assertEqual(?PUSH_DATA, Id),
    ?assertEqual(MAC0, MAC1),
    ?assertEqual(
        #{
            <<"rxpk">> => [
                #{
                    <<"time">> => iso8601:format(
                        calendar:system_time_to_universal_time(Tmst, millisecond)
                    ),
                    <<"tmst">> => Tmst,
                    <<"freq">> => 915.2,
                    <<"rfch">> => 0,
                    <<"modu">> => <<"LORA">>,
                    <<"datr">> => <<"datr">>,
                    <<"rssi">> => -80.0,
                    <<"lsnr">> => -10,
                    <<"size">> => erlang:byte_size(Payload),
                    <<"data">> => base64:encode(Payload)
                }
            ],
            <<"stat">> => #{
                <<"regi">> => <<"US_915">>,
                <<"inde">> => 123456,
                <<"lati">> => -121,
                <<"long">> => 37,
                <<"pubk">> => "pubkey_b58"
            }
        },
        jsx:decode(BinJSX1, [return_maps])
    ),
    ok.

push_ack_test() ->
    Token = token(),
    PushAck = push_ack(Token),
    ?assertEqual(
        <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_ACK:8/integer-unsigned>>,
        PushAck
    ),
    ok.

pull_data_test() ->
    Token = token(),
    MAC = crypto:strong_rand_bytes(8),
    PullData = pull_data(Token, MAC),
    ?assertEqual(
        <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_DATA:8/integer-unsigned,
            MAC:8/binary>>,
        PullData
    ),
    ok.

pull_ack_test() ->
    Token = token(),
    PushAck = pull_ack(Token),
    ?assertEqual(
        <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_ACK:8/integer-unsigned>>,
        PushAck
    ),
    ok.

pull_resp_test() ->
    Token0 = token(),
    Map0 = #{
        imme => true,
        freq => 864.1235,
        rfch => 0,
        powe => 14,
        modu => <<"LORA">>,
        datr => <<"SF11BW125">>,
        codr => <<"4/6">>,
        ipol => false,
        size => 32,
        data => <<"H3P3N2i9qc4yt7rK7ldqoeCVJGBybzPY5h1Dd7P7p8v">>
    },
    PullResp = pull_resp(Token0, Map0),
    <<?PROTOCOL_2:8/integer-unsigned, Token1:2/binary, Id:8/integer-unsigned, BinJSX/binary>> =
        PullResp,
    ?assertEqual(Token1, Token0),
    ?assertEqual(?PULL_RESP, Id),
    ?assertEqual(
        #{
            <<"txpk">> => #{
                <<"imme">> => true,
                <<"freq">> => 864.1235,
                <<"rfch">> => 0,
                <<"powe">> => 14,
                <<"modu">> => <<"LORA">>,
                <<"datr">> => <<"SF11BW125">>,
                <<"codr">> => <<"4/6">>,
                <<"ipol">> => false,
                <<"size">> => 32,
                <<"data">> => <<"H3P3N2i9qc4yt7rK7ldqoeCVJGBybzPY5h1Dd7P7p8v">>
            }
        },
        jsx:decode(BinJSX, [return_maps])
    ),
    ok.

tx_ack_test() ->
    Token0 = token(),
    MAC0 = crypto:strong_rand_bytes(8),
    TxnAck = tx_ack(Token0, MAC0),
    <<?PROTOCOL_2:8/integer-unsigned, Token1:2/binary, Id:8/integer-unsigned, MAC1:8/binary,
        BinJSX/binary>> =
        TxnAck,
    ?assertEqual(Token0, Token1),
    ?assertEqual(?TX_ACK, Id),
    ?assertEqual(MAC0, MAC1),
    ?assertEqual(
        #{
            <<"txpk_ack">> => #{
                <<"error">> => ?TX_ACK_ERROR_NONE
            }
        },
        jsx:decode(BinJSX, [return_maps])
    ),
    ok.

token_test() ->
    Token = token(),
    ?assertEqual(2, erlang:byte_size(Token)),
    ?assertEqual(Token, token(push_data(Token, crypto:strong_rand_bytes(8), #{}))),
    ?assertEqual(Token, token(push_ack(Token))),
    ?assertEqual(Token, token(pull_data(Token, crypto:strong_rand_bytes(8)))),
    ?assertEqual(Token, token(pull_ack(Token))),
    ?assertEqual(Token, token(pull_resp(Token, #{}))),
    ?assertEqual(Token, token(tx_ack(Token, crypto:strong_rand_bytes(8)))),
    ?assertException(error, function_clause, token(<<"some unknown stuff">>)),
    ok.

identifier_test() ->
    Token = token(),
    ?assertEqual(?PUSH_DATA, identifier(push_data(Token, crypto:strong_rand_bytes(8), #{}))),
    ?assertEqual(?PUSH_ACK, identifier(push_ack(Token))),
    ?assertEqual(?PULL_DATA, identifier(pull_data(Token, crypto:strong_rand_bytes(8)))),
    ?assertEqual(?PULL_ACK, identifier(pull_ack(Token))),
    ?assertEqual(?PULL_RESP, identifier(pull_resp(Token, #{}))),
    ?assertEqual(?TX_ACK, identifier(tx_ack(Token, crypto:strong_rand_bytes(8)))),
    ?assertException(error, function_clause, token(<<"some unknown stuff">>)),
    ok.

identifier_to_atom_test() ->
    ?assertEqual(push_data, identifier_to_atom(?PUSH_DATA)),
    ?assertEqual(push_ack, identifier_to_atom(?PUSH_ACK)),
    ?assertEqual(pull_data, identifier_to_atom(?PULL_DATA)),
    ?assertEqual(pull_resp, identifier_to_atom(?PULL_RESP)),
    ?assertEqual(pull_ack, identifier_to_atom(?PULL_ACK)),
    ?assertEqual(tx_ack, identifier_to_atom(?TX_ACK)),
    ok.

json_data_test() ->
    Token = token(),
    ?assertEqual(
        #{<<"rxpk">> => [#{}]},
        json_data(push_data(Token, crypto:strong_rand_bytes(8), #{}))
    ),
    ?assertEqual(#{<<"txpk">> => #{}}, json_data(pull_resp(Token, #{}))),
    ?assertEqual(
        #{<<"txpk_ack">> => #{<<"error">> => <<"NONE">>}},
        json_data(tx_ack(Token, crypto:strong_rand_bytes(8)))
    ),
    ok.

-endif.
