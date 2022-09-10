-module(hpr_protocol_router).

-include("grpc/autogen/server/packet_router_pb.hrl").

% TODO: should be in a common include file
-define(JOIN_REQUEST, 2#000).

-export([send/3]).

% ------------------------------------------------------------------------------
% API
% ------------------------------------------------------------------------------

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

% ------------------------------------------------------------------------------
% Private Functions
% ------------------------------------------------------------------------------

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
        datarate => atom_to_binary(DataRate),
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
        datarate := RX1Datarate
    } = Packet,
    #packet_router_packet_down_v1_pb{
        payload = Payload,
        rx1 = #window_v1_pb{
            timestamp = RX1Timestamp,
            frequency = RX1Frequency,
            datarate = hpr_datarate(RX1Datarate)
        },
        rx2 = rx2_window(Packet)
    }.

-spec rx2_window(router_pb:packet_pb()) ->
    undefined | packet_router_pb:window_v1_pb().
rx2_window(#{rx2_window := RX2Window}) ->
    #{
        timestamp := RX2Timestamp,
        frequency := RX2Frequency,
        datarate := RX2Datarate
    } = RX2Window,
    #window_v1_pb{
        timestamp = RX2Timestamp,
        frequency = RX2Frequency,
        datarate = hpr_datarate(RX2Datarate)
    };
rx2_window(_) ->
    undefined.

-spec hpr_datarate(unicode:chardata()) ->
    packet_router_pb:'helium.data_rate'().
hpr_datarate(DataRateString) ->
    % TODO Is there a mapping needed for hpr data_rate to/from router data_rate?
    binary_to_existing_atom(unicode:characters_to_binary(DataRateString)).

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
        ?_test(routing_information_t()),
        ?_test(blockchain_state_channel_message_v1_t()),
        ?_test(packet_router_packet_down_v1_t(rx2_window)),
        ?_test(packet_router_packet_down_v1_t(no_rx2_window)),
        {foreach, fun per_testcase_setup/0, fun per_testcase_cleanup/1, [
            ?_test(send_t1()),
            ?_test(send_t2())
        ]}
    ].

per_testcase_setup() ->
    meck:new(hpr_grpc_client_connection_pool),
    meck:new(grpc_client),
    ok.

per_testcase_cleanup(_) ->
    meck:unload(hpr_grpc_client_connection_pool),
    meck:unload(grpc_client).

routing_information_t() ->
    DevAddr = 1234,
    ?assertEqual(
        % routing_information_pb
        #{data => {devaddr, DevAddr}},
        routing_information(
            <<?JOIN_REQUEST:3, 0:5, DevAddr:32/integer-unsigned-little, "unused">>
        )
    ).

blockchain_state_channel_message_v1_t() ->
    % verify no errors in traqnslated packet
    Route = hpr_route:new(1, [], [], lns(), router, 1),
    HprPacketUp = test_utils:join_packet_up(#{}),
    BlockchainStateChannelMessage =
        blockchain_state_channel_message_v1(Route, HprPacketUp),
    _EncodedBlockchainStateChannelMessage =
        router_pb:encode_msg(
            BlockchainStateChannelMessage,
            blockchain_state_channel_message_v1_pb,
            [verify]
        ).

packet_router_packet_down_v1_t(Option) ->
    % verify no errors in traqnslated packet
    Response = blockchain_state_channel_message_response(Option),
    router_pb:verify_msg(Response, blockchain_state_channel_message_v1_pb),
    PacketRouterPacketDown =
        packet_router_packet_down_v1(Response),
    _EncodedPacketRouterPacketDownMessage =
        packet_router_pb:encode_msg(
            PacketRouterPacketDown,
            packet_router_packet_down_v1_pb,
            [verify]
        ).

% send/3: happy path
send_t1() ->
    Owner = self(),
    HprPacketUp = test_utils:join_packet_up(#{}),
    Stream = self(),
    Route = hpr_route:new(1, [], [], lns(), router, 1),
    ReservationRef = make_ref(),
    % random pid
    Connection = self(),
    GrcpClientUnaryResponse = blockchain_state_channel_message_response(),

    meck:expect(
        hpr_grpc_client_connection_pool, reserve, [Owner, lns()], {ok, Connection, ReservationRef}
    ),
    meck:expect(hpr_grpc_client_connection_pool, release, [ReservationRef], ok),
    meck:expect(
        grpc_client,
        unary,
        [
            Connection,
            blockchain_state_channel_message_v1(Route, HprPacketUp),
            router,
            route,
            router_pb,
            []
        ],
        {ok, #{result => GrcpClientUnaryResponse}}
    ),

    ResponseValue = send(HprPacketUp, Stream, Route),

    receive
        {reply, Reply} ->
            ?assertEqual(packet_router_packet_down_v1(GrcpClientUnaryResponse), Reply),
            ok
    after 0 ->
        ?assert(timedout == true)
    end,

    ?assertEqual(ok, ResponseValue),
    ?assertEqual(1, meck:num_calls(hpr_grpc_client_connection_pool, reserve, 2)),
    ?assertEqual(1, meck:num_calls(hpr_grpc_client_connection_pool, release, 1)),
    ?assertEqual(1, meck:num_calls(grpc_client, unary, 6)).

% send/3: grpc_client error
send_t2() ->
    Owner = self(),
    HprPacketUp = test_utils:join_packet_up(#{}),
    Stream = self(),
    Route = hpr_route:new(1, [], [], lns(), router, 1),
    ReservationRef = make_ref(),
    % random pid
    Connection = self(),

    meck:expect(
        hpr_grpc_client_connection_pool, reserve, [Owner, lns()], {ok, Connection, ReservationRef}
    ),
    meck:expect(hpr_grpc_client_connection_pool, release, [ReservationRef], ok),
    meck:expect(
        grpc_client,
        unary,
        [
            Connection,
            blockchain_state_channel_message_v1(Route, HprPacketUp),
            router,
            route,
            router_pb,
            []
        ],
        grpc_client_error_response()
    ),

    ResponseValue = send(HprPacketUp, Stream, Route),

    receive
        {reply, _Reply} ->
            ?assert(unexpected_stream_reply == true)
    after 0 ->
        ok
    end,

    ?assertEqual(grpcbox_grpc_error_response(grpc_client_error_response()), ResponseValue),
    ?assertEqual(1, meck:num_calls(hpr_grpc_client_connection_pool, reserve, 2)),
    ?assertEqual(1, meck:num_calls(hpr_grpc_client_connection_pool, release, 1)),
    ?assertEqual(1, meck:num_calls(grpc_client, unary, 6)).

%% ------------------------------------------------------------------
%% Private Test Functions
%% ------------------------------------------------------------------

host() -> "example-lns.com".
port() -> 4321.
lns() ->
    <<(list_to_binary(host()))/binary, $:, (integer_to_binary(port()))/binary>>.

grpc_client_error_response() ->
    {error, #{
        grpc_status => 1,
        status_message => <<"fake error">>
    }}.

blockchain_state_channel_message_response() ->
    blockchain_state_channel_message_response(rx2_window).

blockchain_state_channel_message_response(Option) ->
    #{
        msg =>
            {response, #{
                accepted => true,
                downlink => packet(Option)
            }}
    }.

packet(rx2_window) ->
    (packet(no_rx2_window))#{
        rx2_window => #{
            timestamp => 1,
            frequency => 1.1,
            datarate => "SF12BW125"
        }
    };
packet(no_rx2_window) ->
    #{
        oui => 1,
        type => lorawan,
        payload => <<"payload">>,
        timestamp => 1,
        signal_strength => 1.1,
        frequency => 1.1,
        datarate => "SF12BW125",
        snr => 1.1,
        routing => #{
            data => {devaddr, 1}
        }
    }.

-endif.
