-module(hpr_packet_down).

-include("../autogen/packet_router_pb.hrl").

-export([
    payload/1,
    rx1_timestamp/1,
    rx1_frequency/1,
    rx1_datarate/1,
    rx2_frequency/1,
    rx2_datarate/1,
    gateway/1,
    is_immediate/1,
    window/1,
    window/3
]).

-export([
    new_imme_downlink/4,
    new_downlink/5,
    new_downlink/6
]).

-type packet() :: packet_router_pb:packet_router_packet_down_v1_pb().
-type downlink_packet() :: hpr_packet_down:packet().

-export_type([
    packet/0,
    downlink_packet/0
]).

-spec payload(PacketDown :: packet()) -> iodata() | undefined.
payload(PacketDown) ->
    PacketDown#packet_router_packet_down_v1_pb.payload.

-spec rx1_timestamp(PacketDown :: packet()) -> non_neg_integer() | undefined.
rx1_timestamp(PacketDown) ->
    PacketDown#packet_router_packet_down_v1_pb.rx1#window_v1_pb.timestamp.

-spec rx1_frequency(PacketDown :: packet()) ->
    Frequency :: non_neg_integer() | undefined.
rx1_frequency(PacketDown) ->
    PacketDown#packet_router_packet_down_v1_pb.rx1#window_v1_pb.frequency.

-spec rx1_datarate(PacketDown :: packet()) -> atom() | integer() | undefined.
rx1_datarate(PacketDown) ->
    PacketDown#packet_router_packet_down_v1_pb.rx1#window_v1_pb.datarate.

-spec rx2_frequency(PacketDown :: packet()) ->
    Frequency :: non_neg_integer() | undefined.
rx2_frequency(PacketDown) ->
    PacketDown#packet_router_packet_down_v1_pb.rx2#window_v1_pb.frequency.

-spec rx2_datarate(PacketDown :: packet()) -> atom() | integer() | undefined.
rx2_datarate(PacketDown) ->
    PacketDown#packet_router_packet_down_v1_pb.rx2#window_v1_pb.datarate.

-spec gateway(PacketDown :: packet()) -> iodata() | undefined.
gateway(PacketDown) ->
    PacketDown#packet_router_packet_down_v1_pb.gateway.

-spec is_immediate(PacketDown :: packet()) -> boolean().
is_immediate(PacketDown) ->
    PacketDown#packet_router_packet_down_v1_pb.rx1#window_v1_pb.immediate.

-spec window
    (undefined) -> undefined;
    (packet_router_pb:window_v1_pb()) -> packet_router_pb:window_v1_pb();
    (map()) -> packet_router_pb:window_v1_pb().
window(undefined) ->
    undefined;
window(#window_v1_pb{} = Window) ->
    Window;
window(WindowMap) when erlang:is_map(WindowMap) ->
    Template = #window_v1_pb{},
    #window_v1_pb{
        timestamp = maps:get(timestamp, WindowMap, Template#window_v1_pb.timestamp),
        frequency = maps:get(frequency, WindowMap, Template#window_v1_pb.frequency),
        datarate = maps:get(datarate, WindowMap, Template#window_v1_pb.datarate),
        immediate = maps:get(immediate, WindowMap, Template#window_v1_pb.immediate)
    }.

-spec window(non_neg_integer(), 'undefined' | non_neg_integer(), atom()) ->
    packet_router_pb:window_v1_pb().
window(TS, FrequencyHz, DataRate) ->
    #window_v1_pb{
        timestamp = TS,
        %% Protobuf encoding requires that the frequency is an integer, rather
        %% than a float in exponential notation
        frequency = round(FrequencyHz),
        datarate = DataRate,
        immediate = false
    }.

-spec new_imme_downlink(
    Payload :: binary(),
    FrequencyHz :: non_neg_integer(),
    DataRate :: atom() | number(),
    Gateway :: binary()
) -> downlink_packet().
new_imme_downlink(Payload, FrequencyHz, DataRate, Gateway) ->
    #packet_router_packet_down_v1_pb{
        payload = Payload,
        rx1 = #window_v1_pb{
            timestamp = 0,
            frequency = round(FrequencyHz),
            datarate = DataRate,
            immediate = true
        },
        rx2 = undefined,
        gateway = Gateway
    }.

-spec new_downlink(
    Payload :: binary(),
    Timestamp :: non_neg_integer(),
    Frequency :: atom() | number(),
    DataRate :: atom() | integer(),
    Gateway :: binary()
) -> downlink_packet().
new_downlink(Payload, Timestamp, FrequencyHz, DataRate, Gateway) ->
    new_downlink(Payload, Timestamp, FrequencyHz, DataRate, Gateway, undefined).

-spec new_downlink(
    Payload :: binary(),
    Timestamp :: non_neg_integer(),
    Frequency :: atom() | number(),
    DataRate :: atom() | integer(),
    Gateway :: binary(),
    Rx2 :: packet_router_pb:window_v1_pb() | undefined
) -> downlink_packet().
new_downlink(Payload, Timestamp, FrequencyHz, DataRate, Gateway, Rx2) ->
    #packet_router_packet_down_v1_pb{
        payload = Payload,
        rx1 = window(Timestamp, FrequencyHz, DataRate),
        rx2 = window(Rx2),
        gateway = Gateway
    }.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-define(FAKE_TIMESTAMP, 1).
-define(FAKE_FREQUENCY, 2).
-define(FAKE_DATARATE, 'SF12BW125').
-define(FAKE_PAYLOAD, <<"fake payload">>).
-define(FAKE_GATEWAY, <<"fake gateway">>).

payload_test() ->
    PacketDown = fake_downlink(),
    ?assertEqual(?FAKE_PAYLOAD, payload(PacketDown)).

rx1_timestamp_test() ->
    PacketDown = fake_downlink(),
    ?assertEqual(?FAKE_TIMESTAMP, rx1_timestamp(PacketDown)).

rx1_frequency_test() ->
    PacketDown = fake_downlink(),
    ?assertEqual(?FAKE_FREQUENCY, rx1_frequency(PacketDown)).

rx1_datarate_test() ->
    PacketDown = fake_downlink(),
    ?assertEqual(?FAKE_DATARATE, rx1_datarate(PacketDown)).

rx2_frequency_test() ->
    PacketDown = fake_downlink(),
    ?assertEqual(?FAKE_FREQUENCY, rx2_frequency(PacketDown)).

rx2_datarate_test() ->
    PacketDown = fake_downlink(),
    ?assertEqual(?FAKE_DATARATE, rx2_datarate(PacketDown)).

gateway_test() ->
    PacketDown = fake_downlink(),
    ?assertEqual(?FAKE_GATEWAY, gateway(PacketDown)).

window_test() ->
    ?assertEqual(undefined, window(undefined)),
    ?assertEqual(#window_v1_pb{}, window(#{})),
    ?assertEqual(ok, packet_router_pb:verify_msg(window(fake_window()), window_v1_pb)),
    ?assertEqual(ok, packet_router_pb:verify_msg(window(#{}), window_v1_pb)).

new_downlink_test() ->
    PacketDown = new_downlink(
        ?FAKE_PAYLOAD,
        ?FAKE_TIMESTAMP,
        ?FAKE_FREQUENCY,
        ?FAKE_DATARATE,
        ?FAKE_GATEWAY,
        window(fake_window())
    ),
    ?assertEqual(
        #packet_router_packet_down_v1_pb{
            payload = ?FAKE_PAYLOAD,
            rx1 = #window_v1_pb{
                timestamp = ?FAKE_TIMESTAMP,
                frequency = ?FAKE_FREQUENCY,
                datarate = ?FAKE_DATARATE
            },
            rx2 = #window_v1_pb{
                timestamp = ?FAKE_TIMESTAMP,
                frequency = ?FAKE_FREQUENCY,
                datarate = ?FAKE_DATARATE
            },
            gateway = ?FAKE_GATEWAY
        },
        PacketDown
    ).

%%  A frequency specified in exponential form is expected to break the encoding
%% because of the way protobuf converts integers to binary.
encoding_test() ->
    ?assertError(
        badarith,
        packet_router_pb:encode_msg(
            {packet_router_packet_down_v1_pb,
                <<32, 120, 27, 32, 121, 54, 203, 110, 31, 45, 232, 6, 197, 16, 15, 132, 203, 12,
                    255, 166, 46, 81, 160, 71, 139, 27, 16, 13, 91, 244, 192, 244, 69>>,
                {window_v1_pb, 3188801119, 9.257e8, 'SF10BW500', false},
                {window_v1_pb, 3189801119, 9.233e8, 'SF12BW500', false}, <<"gateway">>}
        )
    ).

%% ------------------------------------------------------------------
% EUnit private functions
%% ------------------------------------------------------------------

fake_window() ->
    Window = ?MODULE:window(#{
        timestamp => ?FAKE_TIMESTAMP,
        frequency => ?FAKE_FREQUENCY,
        datarate => ?FAKE_DATARATE
    }),
    ?assertEqual(ok, packet_router_pb:verify_msg(Window, window_v1_pb)),
    Window.

fake_downlink() ->
    new_downlink(
        ?FAKE_PAYLOAD,
        ?FAKE_TIMESTAMP,
        ?FAKE_FREQUENCY,
        ?FAKE_DATARATE,
        ?FAKE_GATEWAY,
        window(fake_window())
    ).

-endif.
