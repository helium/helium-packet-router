-module(hpr_packet_report).

-include("../autogen/packet_router_pb.hrl").

-export([
    new/2, new/4,
    gateway_tmst/1,
    oui/1,
    net_id/1,
    rssi/1,
    frequency/1,
    datarate/1,
    snr/1,
    region/1,
    gateway/1,
    payload_hash/1,
    payload_size/1,
    free/1,
    type/1,
    received_timestamp/1,
    encode/1,
    decode/1
]).

-ifdef(TEST).

-export([
    test_new/1
]).

-endif.

-type packet_report() :: #packet_router_packet_report_v1_pb{}.

-export_type([packet_report/0]).

-spec new(hpr_packet_up:packet(), hpr_route:route()) -> packet_report().
new(Packet, Route) ->
    ?MODULE:new(Packet, Route, false, erlang:system_time(millisecond)).

-spec new(
    Packet :: hpr_packet_up:packet(),
    Route :: hpr_route:route(),
    IsFree :: boolean(),
    ReceivedTime :: non_neg_integer()
) -> packet_report().
new(Packet, Route, IsFree, ReceivedTime) ->
    PacketType =
        case hpr_packet_up:type(Packet) of
            {join_req, _} -> join;
            {uplink, _} -> uplink
        end,
    #packet_router_packet_report_v1_pb{
        gateway_tmst = hpr_packet_up:timestamp(Packet),
        oui = hpr_route:oui(Route),
        net_id = hpr_route:net_id(Route),
        rssi = hpr_packet_up:rssi(Packet),
        frequency = hpr_packet_up:frequency(Packet),
        datarate = hpr_packet_up:datarate(Packet),
        snr = hpr_packet_up:snr(Packet),
        region = hpr_packet_up:region(Packet),
        gateway = hpr_packet_up:gateway(Packet),
        payload_hash = hpr_packet_up:phash(Packet),
        payload_size = erlang:byte_size(hpr_packet_up:payload(Packet)),
        free = IsFree,
        type = PacketType,
        received_timestamp = ReceivedTime
    }.

-spec gateway_tmst(PacketReport :: packet_report()) -> non_neg_integer() | undefined.
gateway_tmst(PacketReport) ->
    PacketReport#packet_router_packet_report_v1_pb.gateway_tmst.

-spec oui(Packet :: packet_report()) -> non_neg_integer() | undefined.
oui(PacketReport) ->
    PacketReport#packet_router_packet_report_v1_pb.oui.

-spec net_id(RouteReport :: packet_report()) -> non_neg_integer() | undefined.
net_id(RouteReport) ->
    RouteReport#packet_router_packet_report_v1_pb.net_id.

-spec rssi(Packet :: packet_report()) -> non_neg_integer() | undefined.
rssi(PacketReport) ->
    PacketReport#packet_router_packet_report_v1_pb.rssi.

-spec frequency(Packet :: packet_report()) -> non_neg_integer() | undefined.
frequency(PacketReport) ->
    PacketReport#packet_router_packet_report_v1_pb.frequency.

-spec datarate(PacketReport :: packet_report()) -> atom().
datarate(PacketReport) ->
    PacketReport#packet_router_packet_report_v1_pb.datarate.

-spec snr(PacketReport :: packet_report()) -> float().
snr(PacketReport) ->
    PacketReport#packet_router_packet_report_v1_pb.snr.

-spec region(PacketReport :: packet_report()) -> atom().
region(PacketReport) ->
    PacketReport#packet_router_packet_report_v1_pb.region.

-spec gateway(PacketReport :: packet_report()) -> binary().
gateway(PacketReport) ->
    PacketReport#packet_router_packet_report_v1_pb.gateway.

-spec payload_hash(PacketReport :: packet_report()) -> iodata() | undefined.
payload_hash(PacketReport) ->
    PacketReport#packet_router_packet_report_v1_pb.payload_hash.

-spec payload_size(PacketReport :: packet_report()) -> non_neg_integer() | undefined.
payload_size(PacketReport) ->
    PacketReport#packet_router_packet_report_v1_pb.payload_size.

-spec free(PacketReport :: packet_report()) -> boolean() | undefined.
free(PacketReport) ->
    PacketReport#packet_router_packet_report_v1_pb.free.

-spec type(PacketReport :: packet_report()) -> join | uplink | undefined.
type(PacketReport) ->
    PacketReport#packet_router_packet_report_v1_pb.type.

-spec received_timestamp(PacketReport :: packet_report()) -> non_neg_integer() | undefined.
received_timestamp(PacketReport) ->
    PacketReport#packet_router_packet_report_v1_pb.received_timestamp.

-spec encode(PacketReport :: packet_report()) -> binary().
encode(#packet_router_packet_report_v1_pb{} = PacketReport) ->
    packet_router_pb:encode_msg(PacketReport).

-spec decode(BinaryReport :: binary()) -> packet_report().
decode(BinaryReport) ->
    packet_router_pb:decode_msg(BinaryReport, packet_router_packet_report_v1_pb).

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec test_new(Opts :: map()) -> packet_report().
test_new(Opts) ->
    PacketUp = maps:get(packet, Opts, hpr_packet_up:test_new(#{})),
    #packet_router_packet_report_v1_pb{
        gateway_tmst = maps:get(
            gateway_tmst, Opts, erlang:system_time(millisecond)
        ),
        oui = maps:get(oui, Opts, 1),
        net_id = maps:get(net_id, Opts, 0),
        rssi = maps:get(rssi, Opts, 35),
        frequency = maps:get(frequency, Opts, 904_300_000),
        snr = maps:get(snr, Opts, 7.0),
        datarate = maps:get(datarate, Opts, 'SF7BW125'),
        region = maps:get(region, Opts, 'US915'),
        gateway = maps:get(gateway, Opts, <<"gateway">>),
        payload_hash = hpr_packet_up:phash(PacketUp),
        payload_size = erlang:byte_size(hpr_packet_up:payload(PacketUp)),
        free = maps:get(free, Opts, false),
        type = maps:get(type, Opts, join),
        received_timestamp = maps:get(received_timestamp, Opts, erlang:system_time(millisecond))
    }.

-endif.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

gateway_tmst_test() ->
    Now = erlang:system_time(millisecond),
    PacketReport = test_new(#{gateway_tmst => Now}),
    ?assertEqual(Now, gateway_tmst(PacketReport)),
    ok.

oui_test() ->
    PacketReport = test_new(#{}),
    ?assertEqual(1, oui(PacketReport)),
    ok.

net_id_test() ->
    PacketReport = test_new(#{}),
    ?assertEqual(0, net_id(PacketReport)),
    ok.

rssi_test() ->
    PacketReport = test_new(#{}),
    ?assertEqual(35, rssi(PacketReport)),
    ok.

frequency_test() ->
    PacketReport = test_new(#{}),
    ?assertEqual(904_300_000, frequency(PacketReport)),
    ok.

snr_test() ->
    PacketReport = test_new(#{}),
    ?assertEqual(7.0, snr(PacketReport)),
    ok.

datarate_test() ->
    PacketReport = test_new(#{}),
    ?assertEqual('SF7BW125', datarate(PacketReport)),
    ok.

region_test() ->
    PacketReport = test_new(#{}),
    ?assertEqual('US915', region(PacketReport)),
    ok.

gateway_test() ->
    PacketReport = test_new(#{}),
    ?assertEqual(<<"gateway">>, gateway(PacketReport)),
    ok.

encode_decode_test() ->
    PacketReport = test_new(#{frequency => 904_000_000}),
    ?assertEqual(PacketReport, decode(encode(PacketReport))),
    ok.

new_test() ->
    Now = erlang:system_time(millisecond),
    Payload = test_utils:join_payload(#{}),
    PHash = crypto:hash(sha256, Payload),
    PSize = erlang:byte_size(Payload),
    TestPacket = hpr_packet_up:test_new(#{
        payload => Payload,
        timestamp => Now,
        rssi => 35,
        frequency => 904_300_000,
        datarate => 'SF7BW125',
        snr => 7.0,
        region => 'US915',
        gateway => <<"gateway">>
    }),
    TestRoute = hpr_route:test_new(#{
        id => "1",
        oui => 1,
        net_id => 0,
        devaddr_ranges => [],
        euis => [],
        server => #{host => "example.com", port => 8080, protocol => undefined},
        max_copies => 1,
        nonce => 1
    }),
    ?assertEqual(
        test_new(#{
            packet => TestPacket,
            gateway_tmst => Now,
            received_timestamp => Now,
            payload_hash => PHash,
            payload_size => PSize
        }),
        ?MODULE:new(TestPacket, TestRoute, false, Now)
    ).

-endif.
