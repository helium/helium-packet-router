-module(hpr_packet_report).

-include("../grpc/autogen/server/packet_router_pb.hrl").

-export([
    gateway_timestamp_ms/1,
    oui/1,
    net_id/1,
    rssi/1,
    frequency/1,
    datarate/1,
    snr/1,
    region/1,
    gateway/1,
    payload_hash/1,
    encode/1,
    decode/1,
    to_record/1
]).

-ifdef(TEST).

-export([
    new/1
]).

-endif.

-type packet_report() :: #packet_router_packet_report_v1_pb{}.

-export_type([packet_report/0]).

-spec gateway_timestamp_ms(PacketReport :: packet_report()) -> non_neg_integer() | undefined.
gateway_timestamp_ms(PacketReport) ->
    PacketReport#packet_router_packet_report_v1_pb.gateway_timestamp_ms.

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

-spec encode(PacketReport :: packet_report()) -> binary().
encode(#packet_router_packet_report_v1_pb{} = PacketReport) ->
    packet_router_pb:encode_msg(PacketReport).

-spec decode(BinaryReport :: binary()) -> packet_report().
decode(BinaryReport) ->
    packet_router_pb:decode_msg(BinaryReport, packet_router_packet_report_v1_pb).

-spec to_record(map()) -> packet_report().
to_record(ReportMap) ->
    Template = #packet_router_packet_report_v1_pb{},
    #packet_router_packet_report_v1_pb{
        gateway_timestamp_ms = maps:get(
            gateway_timestamp_ms,
            ReportMap,
            Template#packet_router_packet_report_v1_pb.gateway_timestamp_ms
        ),
        oui = maps:get(oui, ReportMap, Template#packet_router_packet_report_v1_pb.oui),
        net_id = maps:get(net_id, ReportMap, Template#packet_router_packet_report_v1_pb.net_id),
        rssi = maps:get(rssi, ReportMap, Template#packet_router_packet_report_v1_pb.rssi),
        frequency = maps:get(
            frequency, ReportMap, Template#packet_router_packet_report_v1_pb.frequency
        ),
        snr = maps:get(snr, ReportMap, Template#packet_router_packet_report_v1_pb.snr),
        datarate = maps:get(
            datarate, ReportMap, Template#packet_router_packet_report_v1_pb.datarate
        ),
        region = maps:get(region, ReportMap, Template#packet_router_packet_report_v1_pb.region),
        gateway = maps:get(gateway, ReportMap, Template#packet_router_packet_report_v1_pb.gateway),
        payload_hash = maps:get(
            payload_hash, ReportMap, Template#packet_router_packet_report_v1_pb.payload_hash
        )
    }.

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec new(Opts :: map()) -> packet_report().
new(Opts) ->
    #packet_router_packet_report_v1_pb{
        gateway_timestamp_ms = maps:get(
            gateway_timestamp_ms, Opts, erlang:system_time(millisecond)
        ),
        oui = maps:get(oui, Opts, 1),
        net_id = maps:get(net_id, Opts, 0),
        rssi = maps:get(rssi, Opts, 35),
        frequency = maps:get(frequency, Opts, 904_300_000),
        snr = maps:get(snr, Opts, 7.0),
        datarate = maps:get(datarate, Opts, 'SF7BW125'),
        region = maps:get(region, Opts, 'US915'),
        gateway = maps:get(gateway, Opts, <<"gateway">>),
        payload_hash = hpr_packet_up:phash(hpr_packet_up:new(#{}))
    }.

-endif.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

gateway_timestamp_ms_test() ->
    Now = erlang:system_time(millisecond),
    PacketReport = ?MODULE:new(#{gateway_timestamp_ms => Now}),
    ?assertEqual(Now, gateway_timestamp_ms(PacketReport)),
    ok.

oui_test() ->
    PacketReport = ?MODULE:new(#{}),
    ?assertEqual(1, oui(PacketReport)),
    ok.

net_id_test() ->
    PacketReport = ?MODULE:new(#{}),
    ?assertEqual(0, net_id(PacketReport)),
    ok.

rssi_test() ->
    PacketReport = ?MODULE:new(#{}),
    ?assertEqual(35, rssi(PacketReport)),
    ok.

frequency_test() ->
    PacketReport = ?MODULE:new(#{}),
    ?assertEqual(904_300_000, frequency(PacketReport)),
    ok.

snr_test() ->
    PacketReport = ?MODULE:new(#{}),
    ?assertEqual(7.0, snr(PacketReport)),
    ok.

datarate_test() ->
    PacketReport = ?MODULE:new(#{}),
    ?assertEqual('SF7BW125', datarate(PacketReport)),
    ok.

region_test() ->
    PacketReport = ?MODULE:new(#{}),
    ?assertEqual('US915', region(PacketReport)),
    ok.

gateway_test() ->
    PacketReport = ?MODULE:new(#{}),
    ?assertEqual(<<"gateway">>, gateway(PacketReport)),
    ok.

encode_decode_test() ->
    PacketReport = ?MODULE:new(#{frequency => 904_000_000}),
    ?assertEqual(PacketReport, decode(encode(PacketReport))),
    ok.

to_record_test() ->
    ?assertEqual(#packet_router_packet_report_v1_pb{}, ?MODULE:to_record(#{})),

    Now = erlang:system_time(millisecond),
    ?assertEqual(
        ?MODULE:new(#{gateway_timestamp_ms => Now}),
        ?MODULE:to_record(#{
            gateway_timestamp_ms => Now,
            oui => 1,
            net_id => 0,
            rssi => 35,
            frequency => 904_300_000,
            datarate => 'SF7BW125',
            snr => 7.0,
            region => 'US915',
            gateway => <<"gateway">>,
            payload_hash => hpr_packet_up:phash(hpr_packet_up:new(#{}))
        })
    ).

-endif.
