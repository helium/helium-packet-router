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

-include("../grpc/autogen/server/packet_router_pb.hrl").

-export([send/4]).

-spec send(
    Packet :: hpr_packet_up:packet(),
    Stream :: grpcbox_stream:t(),
    Routes :: hpr_route:route(),
    RoutingInfo :: hpr_routing:routing_info()
) -> ok | {error, any()}.
send(_PacketUp, _Stream, _Route, _RoutingInfo) ->
    todo,
    ok.
