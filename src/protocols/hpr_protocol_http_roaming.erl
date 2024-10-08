%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs
%%% @doc
%%%
%%% @end
%%% Created : 21. Sep 2022 12:10 PM
%%%-------------------------------------------------------------------
-module(hpr_protocol_http_roaming).
-author("jonathanruttenberg").

-include("hpr_http_roaming.hrl").

-export([send/4]).

-spec send(
    PacketUp :: hpr_packet_up:packet(),
    Route :: hpr_route:route(),
    Timestamp :: non_neg_integer(),
    GatewayLocation :: hpr_gateway_location:loc()
) -> ok | {error, any()}.
send(PacketUp, Route, Timestamp, GatewayLocation) ->
    send(PacketUp, Route, Timestamp, GatewayLocation, 3).

-spec send(
    PacketUp :: hpr_packet_up:packet(),
    Route :: hpr_route:route(),
    Timestamp :: non_neg_integer(),
    GatewayLocation :: hpr_gateway_location:loc(),
    Retry :: non_neg_integer()
) -> ok | {error, any()}.
send(_PacketUp, _Route, _Timestamp, _GatewayLocation, 0) ->
    {error, {roaming_sup_err, max_retries}};
send(PacketUp, Route, Timestamp, GatewayLocation, Retry) ->
    Protocol = protocol_from(Route),
    WorkerKey = worker_key_from(PacketUp, Protocol),
    case
        hpr_http_roaming_sup:maybe_start_worker(#{
            key => WorkerKey, protocol => Protocol, net_id => hpr_route:net_id(Route)
        })
    of
        {error, Reason} ->
            {error, {roaming_sup_err, Reason}};
        % This should only happen when a hotspot connects and spams us with
        % mutliple packets for same LNS
        {ok, undefined} ->
            timer:sleep(2),
            send(PacketUp, Route, Timestamp, GatewayLocation, Retry - 1);
        {ok, WorkerPid} ->
            hpr_http_roaming_worker:handle_packet(WorkerPid, PacketUp, Timestamp, GatewayLocation),
            ok
    end.

-spec worker_key_from(PacketUp :: hpr_packet_up:packet(), Protocol :: #http_protocol{}) ->
    hpr_http_roaming_sup:worker_key().
worker_key_from(PacketUp, Protocol) ->
    Phash = hpr_packet_up:phash(PacketUp),
    {?MODULE, Protocol#http_protocol.route_id, Phash}.

-spec protocol_from(hpr_route:route()) -> hpr_http_roaming_sup:http_protocol().
protocol_from(Route) ->
    FlowType = hpr_route:http_roaming_flow_type(Route),
    DedupeTimeout =
        case hpr_route:http_roaming_dedupe_timeout(Route) of
            undefined -> 250;
            DT -> DT
        end,
    AuthHeader = hpr_route:http_auth_header(Route),
    ReceiverNSID = hpr_route:http_receiver_nsid(Route),
    #http_protocol{
        route_id = hpr_route:id(Route),
        flow_type = FlowType,
        endpoint = hpr_route:lns(Route),
        dedupe_timeout = DedupeTimeout,
        auth_header = AuthHeader,
        receiver_nsid = ReceiverNSID
    }.
