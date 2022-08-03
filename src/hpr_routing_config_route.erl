-module(hpr_routing_config_route).

-include_lib("helium_proto/include/config_service_route_v1_pb.hrl").

-export([
    new/6,
    net_id/1,
    devaddr_ranges/1,
    euis/1,
    lns/1,
    protocol/1,
    oui/1
]).

-type route() :: #config_service_route_v1_pb{}.

-export_type([route/0]).

-spec new(
    NetID :: non_neg_integer(),
    DevAddrRandes :: [{non_neg_integer(), non_neg_integer()}],
    EUIs :: [{non_neg_integer(), non_neg_integer()}],
    LNS :: binary(),
    Protocol :: gwmp | http,
    OUI :: non_neg_integer()
) -> route().
new(NetID, DevAddrRandes, EUIs, LNS, Protocol, OUI) ->
    #config_service_route_v1_pb{
        net_id = NetID,
        devaddr_ranges = [
            #config_service_route_v1_devaddr_range_pb{start = Start, 'end' = End}
         || {Start, End} <- DevAddrRandes
        ],
        euis = [
            #config_service_route_v1_eui_pb{app_eui = AppEUI, dev_eui = DevEUI}
         || {AppEUI, DevEUI} <- EUIs
        ],
        lns = LNS,
        protocol = Protocol,
        oui = OUI
    }.

-spec net_id(Route :: route()) -> non_neg_integer().
net_id(Route) ->
    Route#config_service_route_v1_pb.net_id.

-spec devaddr_ranges(Route :: route()) -> [{non_neg_integer(), non_neg_integer()}].
devaddr_ranges(Route) ->
    [
        {Start, End}
     || #config_service_route_v1_devaddr_range_pb{start = Start, 'end' = End} <-
            Route#config_service_route_v1_pb.devaddr_ranges
    ].

-spec euis(Route :: route()) -> [{non_neg_integer(), non_neg_integer()}].
euis(Route) ->
    [
        {AppEUI, DevEUI}
     || #config_service_route_v1_eui_pb{app_eui = AppEUI, dev_eui = DevEUI} <-
            Route#config_service_route_v1_pb.euis
    ].

-spec lns(Route :: route()) -> binary().
lns(Route) ->
    Route#config_service_route_v1_pb.lns.

-spec protocol(Route :: route()) -> gwmp | http.
protocol(Route) ->
    Route#config_service_route_v1_pb.protocol.

-spec oui(Route :: route()) -> non_neg_integer().
oui(Route) ->
    Route#config_service_route_v1_pb.oui.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

new_test() ->
    Route = #config_service_route_v1_pb{
        net_id = 1,
        devaddr_ranges = [
            #config_service_route_v1_devaddr_range_pb{start = 1, 'end' = 10},
            #config_service_route_v1_devaddr_range_pb{start = 11, 'end' = 20}
        ],
        euis = [
            #config_service_route_v1_eui_pb{app_eui = 1, dev_eui = 1},
            #config_service_route_v1_eui_pb{app_eui = 2, dev_eui = 0}
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
