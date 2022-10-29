%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 21. Sep 2022 12:10 PM
%%%-------------------------------------------------------------------
-module(hpr_protocol_http_roaming).
-author("jonathanruttenberg").

-include("hpr_http_roaming.hrl").

-export([send/3]).

-spec send(
    PacketUp :: hpr_packet_up:packet(),
    GatewayStream :: hpr_http_roaming:gateway_stream(),
    Route :: hpr_route:route()
) -> ok | {error, any()}.
send(PacketUp, GatewayStream, Route) ->
    WorkerKey = worker_key_from(PacketUp, Route),
    PubKeyBin = hpr_packet_up:gateway(PacketUp),
    Protocol = protocol_from(Route),

    %%    start worker
    case
        hpr_http_roaming_sup:maybe_start_worker(
            WorkerKey,
            #{protocol => Protocol, net_id => hpr_route:net_id(Route)}
        )
    of
        {error, worker_not_started, _} = Err ->
            lager:error(
                "failed to start http connector for ~p: ~p",
                [hpr_utils:gateway_name(PubKeyBin), Err]
            ),
            {error, worker_not_started};
        {ok, WorkerPid} ->
            GatewayTime = hpr_packet_up:timestamp(PacketUp),
            hpr_http_roaming_worker:handle_packet(
                WorkerPid, PacketUp, GatewayTime, GatewayStream
            ),
            ok
    end.

-spec worker_key_from(hpr_packet_up:packet(), hpr_route:route()) ->
    hpr_http_roaming_sup:worker_key().
worker_key_from(PacketUp, Route) ->
    %%    get phash
    Phash = hpr_packet_up:phash(PacketUp),
    NetId = hpr_route:net_id(Route),

    %%    get protocol
    Protocol = protocol_from(Route),
    {Phash, Protocol, NetId}.

-spec protocol_from(hpr_route:route()) -> hpr_http_roaming_sup:http_protocol().
protocol_from(Route) ->
    FlowType = hpr_route:http_roaming_flow_type(Route),
    DedupeTimeout =
        case hpr_route:http_roaming_dedupe_timeout(Route) of
            undefined -> 250;
            DT -> DT
        end,

    #http_protocol{
        flow_type = FlowType,
        endpoint = hpr_route:lns(Route),
        dedupe_timeout = DedupeTimeout,
        auth_header = null
    }.
