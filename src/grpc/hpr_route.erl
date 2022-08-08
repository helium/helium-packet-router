-module(hpr_route).

-include_lib("helium_proto/include/packet_router_pb.hrl").

-export([
    new/6,
    net_id/1,
    devaddr_ranges/1,
    euis/1,
    lns/1,
    protocol/1,
    oui/1
]).

-type route() :: #packet_router_route_v1_pb{}.

-export_type([route/0]).

-spec new(
    NetID :: non_neg_integer(),
    DevAddrRanges :: [{non_neg_integer(), non_neg_integer()}],
    EUIs :: [{non_neg_integer(), non_neg_integer()}],
    LNS :: binary(),
    Protocol :: gwmp | http,
    OUI :: non_neg_integer()
) -> route().
new(NetID, DevAddrRanges, EUIs, LNS, Protocol, OUI) ->
    #packet_router_route_v1_pb{
        net_id = NetID,
        devaddr_ranges = [
            #packet_router_route_devaddr_range_v1_pb{start = Start, 'end' = End}
         || {Start, End} <- DevAddrRanges
        ],
        euis = [
            #packet_router_route_eui_v1_pb{app_eui = AppEUI, dev_eui = DevEUI}
         || {AppEUI, DevEUI} <- EUIs
        ],
        lns = LNS,
        protocol = Protocol,
        oui = OUI
    }.

-spec net_id(Route :: route()) -> non_neg_integer().
net_id(Route) ->
    Route#packet_router_route_v1_pb.net_id.

-spec devaddr_ranges(Route :: route()) -> [{non_neg_integer(), non_neg_integer()}].
devaddr_ranges(Route) ->
    [
        {Start, End}
     || #packet_router_route_devaddr_range_v1_pb{start = Start, 'end' = End} <-
            Route#packet_router_route_v1_pb.devaddr_ranges
    ].

-spec euis(Route :: route()) -> [{non_neg_integer(), non_neg_integer()}].
euis(Route) ->
    [
        {AppEUI, DevEUI}
     || #packet_router_route_eui_v1_pb{app_eui = AppEUI, dev_eui = DevEUI} <-
            Route#packet_router_route_v1_pb.euis
    ].

-spec lns(Route :: route()) -> binary().
lns(Route) ->
    Route#packet_router_route_v1_pb.lns.

-spec protocol(Route :: route()) -> atom().
protocol(Route) ->
    Route#packet_router_route_v1_pb.protocol.

-spec oui(Route :: route()) -> non_neg_integer().
oui(Route) ->
    Route#packet_router_route_v1_pb.oui.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

new_test() ->
    Route = #packet_router_route_v1_pb{
        net_id = 1,
        devaddr_ranges = [
            #packet_router_route_devaddr_range_v1_pb{start = 1, 'end' = 10},
            #packet_router_route_devaddr_range_v1_pb{start = 11, 'end' = 20}
        ],
        euis = [
            #packet_router_route_eui_v1_pb{app_eui = 1, dev_eui = 1},
            #packet_router_route_eui_v1_pb{app_eui = 2, dev_eui = 0}
        ],
        lns = <<"lsn.lora.com>">>,
        protocol = gwmp,
        oui = 10
    },
    ?assertEqual(
        Route, new(1, [{1, 10}, {11, 20}], [{1, 1}, {2, 0}], <<"lsn.lora.com>">>, gwmp, 10)
    ),
    ok.

net_id_test() ->
    Route = new(1, [{1, 10}, {11, 20}], [{1, 1}, {2, 0}], <<"lsn.lora.com>">>, gwmp, 10),
    ?assertEqual(1, net_id(Route)),
    ok.

devaddr_ranges_test() ->
    Route = new(1, [{1, 10}, {11, 20}], [{1, 1}, {2, 0}], <<"lsn.lora.com>">>, gwmp, 10),
    ?assertEqual([{1, 10}, {11, 20}], devaddr_ranges(Route)),
    ok.

euis_test() ->
    Route = new(1, [{1, 10}, {11, 20}], [{1, 1}, {2, 0}], <<"lsn.lora.com>">>, gwmp, 10),
    ?assertEqual([{1, 1}, {2, 0}], euis(Route)),
    ok.

lns_test() ->
    Route = new(1, [{1, 10}, {11, 20}], [{1, 1}, {2, 0}], <<"lsn.lora.com>">>, gwmp, 10),
    ?assertEqual(<<"lsn.lora.com>">>, lns(Route)),
    ok.

protocol_test() ->
    Route = new(1, [{1, 10}, {11, 20}], [{1, 1}, {2, 0}], <<"lsn.lora.com>">>, gwmp, 10),
    ?assertEqual(gwmp, protocol(Route)),
    ok.

oui_test() ->
    Route = new(1, [{1, 10}, {11, 20}], [{1, 1}, {2, 0}], <<"lsn.lora.com>">>, gwmp, 10),
    ?assertEqual(10, oui(Route)),
    ok.

-endif.
