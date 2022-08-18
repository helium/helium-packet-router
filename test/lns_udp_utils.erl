%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs Inc.
%%% @doc
%%%
%%% @end
%%% Created : 22. Jul 2022 3:12 PM
%%%-------------------------------------------------------------------
-module(lns_udp_utils).
-author("jonathanruttenberg").

-include("semtech_udp.hrl").

%% API
-export([handle_udp/4]).

handle_udp(
    IP,
    Port,
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_DATA:8/integer-unsigned, MAC:8/binary,
        BinJSX/binary>>,
    #lns_udp_state{custom_state = CustomState, handle_push_data_fun = HandlePushDataFun} = _State
) ->
    Map = jsx:decode(BinJSX),
    GWMPValues = #{
        map => Map,
        token => Token,
        mac => MAC
    },

    HandlePushDataFun(GWMPValues, CustomState, IP, Port),
    ok;
handle_udp(
    IP,
    Port,
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_DATA:8/integer-unsigned, MAC:8/binary>>,
    #lns_udp_state{custom_state = CustomState, handle_pull_data_fun = HandlePullDataFun} = _State
) ->
    GWMPValues = #{
        map => undefined,
        token => Token,
        mac => MAC
    },
    HandlePullDataFun(GWMPValues, CustomState, IP, Port),
    ok;
handle_udp(
    IP,
    Port,
    <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?TX_ACK:8/integer-unsigned, MAC:8/binary,
        BinJSX/binary>>,
    #lns_udp_state{custom_state = CustomState, handle_tx_ack_fun = HandleTXAckFun} = _State
) ->
    Map = jsx:decode(BinJSX),
    GWMPValues = #{
        map => Map,
        token => Token,
        mac => MAC
    },
    HandleTXAckFun(GWMPValues, CustomState, IP, Port),
    ok;
handle_udp(
    _IP,
    _Port,
    _UnknownUDPPacket,
    _State
) ->
    lager:warning("got an unkown udp packet: ~p  from ~p", [_UnknownUDPPacket, {_IP, _Port}]),
    ok.
