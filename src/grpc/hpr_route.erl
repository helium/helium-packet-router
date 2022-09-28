-module(hpr_route).

-include("../grpc/autogen/server/config_pb.hrl").

-export([
    new/1,
    new/5,
    net_id/1,
    devaddr_ranges/1,
    euis/1,
    lns/1,
    protocol/1,
    oui/1
]).

-type route() :: #config_route_v1_pb{}.

-type protocol() ::
    undefined
    | {gwmp, #config_protocol_gwmp_pb{}}
    | {router, #config_protocol_router_pb{}}
    | {http_roaming, #config_protocol_http_roaming_pb{}}.

-export_type([route/0]).

new(#{
    net_id := NetID,
    devaddr_ranges := DevAddrRanges,
    euis := EUIs,
    protocol := Protocol,
    oui := OUI
}) ->
    new(NetID, DevAddrRanges, EUIs, OUI, Protocol).

-spec new(
    NetID :: non_neg_integer(),
    DevAddrRanges :: [#{end_addr := non_neg_integer(), start_addr := non_neg_integer()}],
    EUIs :: [#{app_eui := non_neg_integer(), dev_eui := non_neg_integer()}],
    OUI :: non_neg_integer(),
    Protocol :: {router | gwmp | http_roaming, #{ip := binary(), port := non_neg_integer()}}
) -> route().
new(NetID, DevAddrRanges, EUIs, OUI, {ProtocolType, Protocol}) ->
    ProtocolRecord =
        case ProtocolType of
            gwmp ->
                #{ip := IP, port := Port} = Protocol,
                {gwmp, #config_protocol_gwmp_pb{ip = IP, port = Port}};
            router ->
                #{ip := IP, port := Port} = Protocol,
                {router, #config_protocol_router_pb{ip = IP, port = Port}};
            http_roaming ->
                #{ip := IP, port := Port} = Protocol,
                {http_roaming, #config_protocol_http_roaming_pb{ip = IP, port = Port}}
        end,
    #config_route_v1_pb{
        net_id = NetID,
        devaddr_ranges = [
            #config_devaddr_range_v1_pb{start_addr = Start, end_addr = End}
         || #{end_addr := End, start_addr := Start} <- DevAddrRanges
        ],
        euis = [
            #config_eui_v1_pb{app_eui = AppEUI, dev_eui = DevEUI}
         || #{app_eui := AppEUI, dev_eui := DevEUI} <- EUIs
        ],
        oui = OUI,
        protocol = ProtocolRecord
    }.

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
        new(
            1,
            [#{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}],
            [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
            10,
            {gwmp, #{ip => <<"lsn.lora.com>">>, port => 80}}
        )
    ),
    ok.

net_id_test() ->
    Route = new(
        1,
        [#{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}],
        [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        10,
        {gwmp, #{ip => <<"lsn.lora.com>">>, port => 80}}
    ),
    ?assertEqual(1, net_id(Route)),
    ok.

devaddr_ranges_test() ->
    Route = new(
        1,
        [#{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}],
        [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        10,
        {gwmp, #{ip => <<"lsn.lora.com>">>, port => 80}}
    ),
    ?assertEqual([{1, 10}, {11, 20}], devaddr_ranges(Route)),
    ok.

euis_test() ->
    Route = new(
        1,
        [#{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}],
        [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        10,
        {gwmp, #{ip => <<"lsn.lora.com>">>, port => 80}}
    ),
    ?assertEqual(
        [{1, 1}, {2, 0}], euis(Route)
    ),
    ok.

lns_test() ->
    Route = new(
        1,
        [#{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}],
        [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        10,
        {gwmp, #{ip => <<"lsn.lora.com>">>, port => 80}}
    ),
    %% If no port is in the Endpoint, 80 is assumed.
    ?assertEqual(<<"lsn.lora.com>:80">>, lns(Route)),
    ok.

protocol_test() ->
    Route = new(
        1,
        [#{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}],
        [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        10,
        {gwmp, #{ip => <<"lsn.lora.com>">>, port => 80}}
    ),
    ?assertEqual(
        {gwmp, #config_protocol_gwmp_pb{ip = <<"lsn.lora.com>">>, port = 80}}, protocol(Route)
    ),
    ok.

oui_test() ->
    Route = new(
        1,
        [#{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}],
        [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        10,
        {gwmp, #{ip => <<"lsn.lora.com>">>, port => 80}}
    ),
    ?assertEqual(10, oui(Route)),
    ok.

-endif.
