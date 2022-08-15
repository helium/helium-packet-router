%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 19. Jul 2022 5:37 PM
%%%-------------------------------------------------------------------
-module(gwmp_metrics).
-author("jonathanruttenberg").

-define(METRICS_GWMP_COUNT, "gwmp_counter").
-define(PACKET_PURCHASER_PREFIX, "packet_purchaser_").

%% erlfmt-ignore
-define(VALID_NET_IDS, sets:from_list(
  lists:seq(16#000000, 16#0000FF) ++
    lists:seq(16#600000, 16#6000FF) ++
    lists:seq(16#C00000, 16#C000FF) ++
    lists:seq(16#E00000, 16#E000FF)
)).

%% API
-export([push_ack/2, clean_net_id/1, pull_ack/2, push_ack_missed/2, pull_ack_missed/2]).

-spec push_ack(Prefix :: string(), ID :: non_neg_integer() | binary()) -> ok.
push_ack(?PACKET_PURCHASER_PREFIX, NetID) ->
    Name = build_name(?PACKET_PURCHASER_PREFIX, ?METRICS_GWMP_COUNT),
    prometheus_counter:inc(Name, [clean_net_id(NetID), push_ack, hit]);
push_ack(_Prefix, _ID) ->
    ok.

-spec pull_ack(Prefix :: string(), ID :: non_neg_integer() | binary()) -> ok.
pull_ack(?PACKET_PURCHASER_PREFIX, NetID) ->
    Name = build_name(?PACKET_PURCHASER_PREFIX, ?METRICS_GWMP_COUNT),
    prometheus_counter:inc(Name, [gwmp_metrics:clean_net_id(NetID), pull_ack, hit]);
pull_ack(_Prefix, _ID) ->
    ok.

-spec push_ack_missed(Prefix :: string(), ID :: non_neg_integer() | binary()) -> ok.
push_ack_missed(?PACKET_PURCHASER_PREFIX, NetID) ->
    Name = build_name(?PACKET_PURCHASER_PREFIX, ?METRICS_GWMP_COUNT),
    prometheus_counter:inc(Name, [gwmp_metrics:clean_net_id(NetID), push_ack, miss]);
push_ack_missed(_Prefix, _ID) ->
    ok.

-spec pull_ack_missed(Prefix :: string(), ID :: non_neg_integer() | binary()) -> ok.
pull_ack_missed(?PACKET_PURCHASER_PREFIX, NetID) ->
    Name = build_name(?PACKET_PURCHASER_PREFIX, ?METRICS_GWMP_COUNT),
    prometheus_counter:inc(Name, [gwmp_metrics:clean_net_id(NetID), pull_ack, miss]);
pull_ack_missed(_Prefix, _ID) ->
    ok.

build_name(Prefix, Body) ->
    list_to_atom(Prefix ++ Body).

-spec clean_net_id(non_neg_integer()) -> unofficial_net_id | non_neg_integer().
clean_net_id(NetID) ->
    case sets:is_element(NetID, ?VALID_NET_IDS) of
        true -> NetID;
        false -> unofficial_net_id
    end.
