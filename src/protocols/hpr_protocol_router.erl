-module(hpr_protocol_router).

-export([send/3]).

-spec send(
    Packet :: hpr_packet_up:packet(),
    HandlerPid :: grpcbox_stream:t(),
    Routes :: hpr_route:route()
) -> ok | {error, any()}.
send(_Packet, _HandlerPid, _Route) ->
    %% TODO: Do unary call the GRPC router service here
    ok.
