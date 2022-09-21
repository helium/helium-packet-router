-module(hpr_protocol_router).

-export([send/4]).

-spec send(
    Packet :: hpr_packet_up:packet(),
    HandlerPid :: grpcbox_stream:t(),
    Routes :: hpr_route:route(),
    RoutingInfo :: hpr_routing:routing_info()
) -> ok | {error, any()}.
send(_Packet, _HandlerPid, _Route, _RoutingInfo) ->
    %% TODO: Do unary call the GRPC router service here
    ok.
