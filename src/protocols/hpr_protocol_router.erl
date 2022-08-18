-module(hpr_protocol_router).

-include("grpc/autogen/server/packet_router_pb.hrl").
-include("grpc/autogen/client/router_pb.hrl").

% TODO: should be in a common include file
-define(JOIN_REQUEST, 2#000).

-export([send/3]).

-spec send(
    Packet :: hpr_packet_up:packet(),
    HandlerPid :: pid(),
    Route :: hpr_route:route()
) -> ok | {error, any()}.
send(Packet, _HandlerPid, Route) ->
    StateChannelMsg = blockchain_state_channel_message_v1(Route, Packet),
    wrap_grpc_response(helium_router_client:route(StateChannelMsg)).

% translate hpr_packet_up:packet into blockchain_state_channel_message_v1
-spec blockchain_state_channel_message_v1(
    hpr_route:route(), hpr_packet_up:packet()
) ->
    router_pb:blockchain_state_channel_message_v1_pb().
blockchain_state_channel_message_v1(Route, HprPacketUp) ->
    % Decompose uplink message
    #packet_router_packet_up_v1_pb{
        payload = Payload,
        timestamp = Timestamp,
        signal_strength = SignalStrength,
        frequency = Frequency,
        datarate = DataRate,
        snr = SNR,
        region = Region,
        hold_time = HoldTime,
        hotspot = Hotspot,
        signature = Signature
    } = HprPacketUp,
    #packet_router_route_v1_pb{
        % net_id = NetId,
        % devaddr_ranges = DevaddrRanges,
        % euis = EUIs,
        % lns = LNS,
        % protocol = Protocol,
        oui = OUI
    } = Route,

    % construct blockchain_state_channel_message_v1_pb
    RoutingInformation = routing_information(Payload),
    Packet = #packet_pb{
        % Defaults:
        % type = longfi,
        % rx2_window = undefined
        oui = OUI,
        payload = Payload,
        timestamp = Timestamp,
        signal_strength = SignalStrength,
        frequency = Frequency,
        datarate = DataRate,
        snr = SNR,
        routing = RoutingInformation
    },
    StateChannelPacket = #blockchain_state_channel_packet_v1_pb{
        packet = Packet,
        hotspot = Hotspot,
        signature = Signature,
        region = Region,
        hold_time = HoldTime
    },
    #blockchain_state_channel_message_v1_pb{msg = {packet, StateChannelPacket}}.

-spec wrap_grpc_response
    ({ok, router_pb:blockchain_state_channel_message_v1_pb(), grpcbox:metadata()}) -> ok;
    ({error, Error}) -> {error, Error};
    (grpcbox_stream:grpc_error_response()) ->
        {error, grpcbox_stream:grpc_error_response()}.
wrap_grpc_response({ok, _, _}) -> ok;
wrap_grpc_response({error, _} = ErrorTuple) -> ErrorTuple;
wrap_grpc_response({grpc_error, _} = GrpcError) -> {error, GrpcError}.

-spec routing_information(binary()) -> router_pb:routing_information().
routing_information(
    <<?JOIN_REQUEST:3, _:5, AppEUI:64/integer-unsigned-little, DevEUI:64/integer-unsigned-little,
        _/binary>>
) ->
    EUI = #eui_pb{deveui = DevEUI, appeui = AppEUI},
    #routing_information_pb{data = {eui, EUI}};
routing_information(<<_FType:3, _:5, DevAddr:32/integer-unsigned-little, _/binary>>) ->
    #routing_information_pb{data = {devaddr, DevAddr}}.
