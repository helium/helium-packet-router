%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 21. Sep 2022 12:10 PM
%%%-------------------------------------------------------------------
-module(hpr_http_router).
-author("jonathanruttenberg").

-include("../grpc/autogen/server/config_pb.hrl").
-include("../grpc/autogen/server/packet_router_pb.hrl").

-include("hpr_roaming.hrl").

-export([send/4]).

-spec send(
    Packet :: hpr_packet_up:packet(),
    GatewayStream :: hpr_router_stream_manager:gateway_stream(),
    Route :: hpr_route:route(),
    RoutingInfo :: hpr_routing:routing_info()
) -> ok | {error, any()}.
send(PacketUp, GatewayStream, Route, RoutingInfo) ->
    WorkerKey = worker_key_from(PacketUp, Route),
    PacketType = hpr_routing:routing_info_type(RoutingInfo),
    PubKeyBin = hpr_packet_up:gateway(PacketUp),
    Protocol = protocol_from(Route),

    %%    start worker
    case
        hpr_http_sup:maybe_start_worker(
            WorkerKey,
            #{protocol => Protocol}
        )
    of
        {error, worker_not_started, _} = Err ->
            lager:error(
                [{packet_type, PacketType}],
                "failed to start http connector for ~p: ~p",
                [hpr_utils:gateway_name(PubKeyBin), Err]
            ),
            Err;
        {ok, WorkerPid} ->
            lager:debug(
                [
                    {packet_type, PacketType},
                    {protocol, http}
                ],
                "~s: [routing_info: ~p]",
                [PacketType, RoutingInfo]
            ),
            hpr_http_worker:handle_packet(
                WorkerPid, PacketUp, erlang:system_time(millisecond), GatewayStream, RoutingInfo
            )
    end,

    todo,
    ok.

-spec worker_key_from(hpr_packet_up:binary(), hpr_route:route()) -> hpr_http_sup:worker_key().
worker_key_from(PacketUp, Route) ->
    %%    get phash
    Phash = packet_hash(PacketUp),

    %%    get protocol
    Protocol = protocol_from(Route),
    {Phash, Protocol}.

-spec protocol_from(hpr_route:route()) -> hpr_http_sup:http_protocol().
protocol_from(Route) ->
    Server = hpr_route:server(Route),
    #config_server_v1_pb{host = IP, port = Port} = Server,
    Protocol = hpr_route:protocol(Server),
    {http_roaming, #config_protocol_http_roaming_v1_pb{}} = Protocol,

    %%    return hard-coded values until the roaming protocol is updated
    #http_protocol{
        protocol_version = pv_1_1,
        flow_type = async,
        endpoint = <<IP/binary, <<":">>/binary, (integer_to_binary(Port))/binary>>,
        dedupe_timeout = 250,
        auth_header = null
    }.

-spec packet_hash(hpr_packet_up:packet()) -> binary().
packet_hash(PacketUp) ->
    crypto:hash(sha256, hpr_packet_up:payload(PacketUp)).
