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
    Protocol = protocol_from(Route),
    WorkerKey = worker_key_from(PacketUp, Protocol),
    PubKeyBin = hpr_packet_up:gateway(PacketUp),
    %% start worker
    case
        hpr_http_roaming_sup:maybe_start_worker(#{
            key => WorkerKey, protocol => Protocol, net_id => hpr_route:net_id(Route)
        })
    of
        {error, Reason} = Err ->
            lager:error(
                "failed to start http connector for ~s: ~p",
                [hpr_utils:gateway_name(PubKeyBin), Reason]
            ),
            Err;
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
