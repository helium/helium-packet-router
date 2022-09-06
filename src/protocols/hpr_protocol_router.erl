-module(hpr_protocol_router).

-include("grpc/autogen/server/packet_router_pb.hrl").

% TODO: should be in a common include file
-define(JOIN_REQUEST, 2#000).

-export([send/3]).

-spec send(
    Packet :: hpr_packet_up:packet(),
    Stream :: pid(),
    Route :: hpr_route:route()
) -> hpr_routing:hr_routing_response().
send(Packet, Stream, Route) ->
    LNS = Route#packet_router_route_v1_pb.lns,
    StateChannelMsg = blockchain_state_channel_message_v1(Route, Packet),
    {ok, Connection, ReservationRef} =
        hpr_grpc_client_connection_pool:reserve(self(), LNS),
    try
        BlockchainStateChannelMessageResponse = grpc_client:unary(
            Connection,
            StateChannelMsg,
            router,
            route,
            router_pb,
            []
        ),
        handle_router_response(Stream, BlockchainStateChannelMessageResponse)
    after
        hpr_grpc_client_connection_pool:release(ReservationRef)
    end.

% translate hpr_packet_up:packet into blockchain_state_channel_message_v1
-spec blockchain_state_channel_message_v1(
    hpr_route:route(), hpr_packet_up:packet()
) ->
    router_pb:blockchain_state_channel_message_v1_pb().
blockchain_state_channel_message_v1(Route, HprPacketUp) ->
    % Decompose uplink message
    #packet_router_packet_up_v1_pb{
        % signature = Signature
        payload = Payload,
        timestamp = Timestamp,
        rssi = SignalStrength,
        frequency_mhz = Frequency,
        datarate = DataRate,
        snr = SNR,
        region = Region,
        hold_time = HoldTime,
        gateway = Gateway
    } = HprPacketUp,

    % construct blockchain_state_channel_message_v1_pb
    RoutingInformation = routing_information(Payload),
    % packet_pb
    Packet = #{
        % Defaults:
        % type = longfi,
        % rx2_window = undefined
        oui => hpr_route:oui(Route),
        payload => Payload,
        timestamp => Timestamp,
        signal_strength => SignalStrength,
        frequency => Frequency,
        datarate => DataRate,
        snr => SNR,
        routing => RoutingInformation
    },
    % blockchain_state_channel_packet_v1_pb
    StateChannelPacket = #{
        packet => Packet,
        hotspot => Gateway,
        signature => <<>>,
        region => Region,
        hold_time => HoldTime
    },
    % blockchain_state_channel_message_v1_pb
    #{msg => {packet, StateChannelPacket}}.

-spec handle_router_response(pid(), grpc_client:unary_response()) ->
    hpr_routing:hpr_routing_response().
handle_router_response(_Stream, {error, _} = GrpcClientErrorResponse) ->
    % translate error from grpc_client to grpcbox
    grpcbox_grpc_error_response(GrpcClientErrorResponse);
handle_router_response(Stream, {ok, Response}) ->
    #{result := Message} = Response,
    PacketDown = packet_router_packet_down_v1(Message),
    Stream ! {reply, PacketDown},
    ok.

-spec grpcbox_grpc_error_response(grpc_client:unary_response()) ->
    {error, grpcbox_stream:grpc_error_response()}.
grpcbox_grpc_error_response(GrpcClientUnaryResponse) ->
    {error, #{
        grpc_status := GrpcStatus,
        status_message := StatusMessage
    }} = GrpcClientUnaryResponse,
    {error, {grpc_error, {GrpcStatus, StatusMessage}}}.

-spec packet_router_packet_down_v1(router_pb:blockchain_state_channel_message_v1_pb()) ->
    packet_router_db:packet_router_packet_down_v1_pb().
packet_router_packet_down_v1(BlockchainStateChannelMessage) ->
    % blockchain_state_channel_message_v1_pb
    #{
        msg := {response, StateChannelResponse}
    } = BlockchainStateChannelMessage,
    % blockchain_state_channel_response_v1_pb
    #{
        downlink := Packet
    } = StateChannelResponse,
    % packet_pb
    #{
        payload := Payload,
        timestamp := RX1Timestamp,
        frequency := RX1Frequency,
        datarate := RX1Datarate,
        rx2_window := RX2Window
    } = Packet,
    % window_pb
    #{
        timestamp := RX2Timestamp,
        frequency := RX2Frequency,
        datarate := RX2Datarate
    } = RX2Window,
    #packet_router_packet_down_v1_pb{
        payload = Payload,
        rx1 = #window_v1_pb{
            timestamp = RX1Timestamp,
            frequency = RX1Frequency,
            datarate = RX1Datarate
        },
        rx2 = #window_v1_pb{
            timestamp = RX2Timestamp,
            frequency = RX2Frequency,
            datarate = RX2Datarate
        }
    }.

-spec routing_information(binary()) -> router_pb:routing_information().
routing_information(
    <<?JOIN_REQUEST:3, _:5, AppEUI:64/integer-unsigned-little, DevEUI:64/integer-unsigned-little,
        _/binary>>
) ->
    % eui_pb
    EUI = #{deveui => DevEUI, appeui => AppEUI},
    % routing_information_pb
    #{data => {eui, EUI}};
routing_information(<<_FType:3, _:5, DevAddr:32/integer-unsigned-little, _/binary>>) ->
    % routing_information_pb{data = {devaddr, DevAddr}}.
    #{data => {devaddr, DevAddr}}.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

basic_test_() ->
    [
        ?_test(routing_information_t())
    ].

routing_information_t() ->
    DevAddr = 1234,
    ?assertEqual(
        % routing_information_pb
        #{data => {devaddr, DevAddr}},
        routing_information(
            <<?JOIN_REQUEST:3, 0:5, DevAddr:32/integer-unsigned-little, "unused">>
        )
    ).

-endif.
