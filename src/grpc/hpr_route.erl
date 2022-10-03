-module(hpr_route).

-include("../grpc/autogen/server/config_pb.hrl").

-export([
    new/1,
    net_id/1,
    devaddr_ranges/1,
    euis/1,
    lns/1,
    protocol/1,
    oui/1
]).

-type route() :: #config_route_v1_pb{}.

-type protocol() ::
    {router, config_pb:config_protocol_router_pb()}
    | {gwmp, config_pb:config_protocol_gwmp_pb()}
    | {http_roaming, config_pb:config_protocol_http_roaming_pb()}
    | undefined.

-spec new(RouteMap :: client_config_pb:route_v1_pb()) -> route().
new(RouteMap) ->
    config_pb:decode_msg(
        client_config_pb:encode_msg(RouteMap, route_v1_pb),
        config_route_v1_pb
    ).

-spec net_id(Route :: route()) -> non_neg_integer().
net_id(Route) ->
    Route#config_route_v1_pb.net_id.

-spec devaddr_ranges(Route :: route()) -> [{non_neg_integer(), non_neg_integer()}].
devaddr_ranges(Route) ->
    [
        {Start, End}
     || #config_devaddr_range_v1_pb{start_addr = Start, end_addr = End} <-
            Route#config_route_v1_pb.devaddr_ranges
    ].

-spec euis(Route :: route()) -> [{non_neg_integer(), non_neg_integer()}].
euis(Route) ->
    [
        {AppEUI, DevEUI}
     || #config_eui_v1_pb{app_eui = AppEUI, dev_eui = DevEUI} <-
            Route#config_route_v1_pb.euis
    ].

-spec lns(Route :: route()) -> binary().
lns(Route) ->
    {IP, Port} =
        case ?MODULE:protocol(Route) of
            undefined -> throw(misconfigured_route);
            {router, #config_protocol_router_pb{ip = I, port = P}} -> {I, P};
            {gwmp, #config_protocol_gwmp_pb{ip = I, port = P}} -> {I, P};
            {http_roaming, #config_protocol_http_roaming_pb{ip = I, port = P}} -> {I, P}
        end,
    <<IP/binary, $:, (erlang:integer_to_binary(Port))/binary>>.

-spec protocol(Route :: route()) -> protocol().
protocol(Route) ->
    Route#config_route_v1_pb.protocol.

-spec oui(Route :: route()) -> non_neg_integer().
oui(Route) ->
    Route#config_route_v1_pb.oui.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

new_test() ->
    Route = #config_route_v1_pb{
        net_id = 1,
        devaddr_ranges = [
            #config_devaddr_range_v1_pb{start_addr = 1, end_addr = 10},
            #config_devaddr_range_v1_pb{start_addr = 11, end_addr = 20}
        ],
        euis = [
            #config_eui_v1_pb{app_eui = 1, dev_eui = 1},
            #config_eui_v1_pb{app_eui = 2, dev_eui = 0}
        ],

        protocol = {gwmp, #config_protocol_gwmp_pb{ip = <<"lsn.lora.com>">>, port = 80}},
        oui = 10
    },
    ?assertEqual(
        Route,
        new(#{
            net_id => 1,
            devaddr_ranges => [
                #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
            ],
            euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
            oui => 10,
            protocol => {gwmp, #{ip => <<"lsn.lora.com>">>, port => 80}}
        })
    ),
    ok.

net_id_test() ->
    Route = new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        protocol => {gwmp, #{ip => <<"lsn.lora.com>">>, port => 80}}
    }),
    ?assertEqual(1, net_id(Route)),
    ok.

devaddr_ranges_test() ->
    Route = new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        protocol => {gwmp, #{ip => <<"lsn.lora.com>">>, port => 80}}
    }),
    ?assertEqual([{1, 10}, {11, 20}], devaddr_ranges(Route)),
    ok.

euis_test() ->
    Route = new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        protocol => {gwmp, #{ip => <<"lsn.lora.com>">>, port => 80}}
    }),
    ?assertEqual(
        [{1, 1}, {2, 0}], euis(Route)
    ),
    ok.

lns_test() ->
    Route = new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        protocol => {gwmp, #{ip => <<"lsn.lora.com>">>, port => 80}}
    }),
    ?assertEqual(<<"lsn.lora.com>:80">>, lns(Route)),
    ok.

protocol_test() ->
    Route = new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        protocol => {gwmp, #{ip => <<"lsn.lora.com>">>, port => 80}}
    }),
    ?assertEqual(
        {gwmp, #config_protocol_gwmp_pb{ip = <<"lsn.lora.com>">>, port = 80}}, protocol(Route)
    ),
    ok.

oui_test() ->
    Route = new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        protocol => {gwmp, #{ip => <<"lsn.lora.com>">>, port => 80}}
    }),
    ?assertEqual(10, oui(Route)),
    ok.

-endif.
