-module(hpr_route).

-include("../grpc/autogen/server/config_pb.hrl").

-export([
    new/1,
    new/6,
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

new(#{
    net_id := NetID,
    devaddr_ranges := DevAddrRanges,
    euis := EUIs,
    lns := LNS,
    protocol := Protocol,
    oui := OUI
}) ->
    new(NetID, DevAddrRanges, EUIs, LNS, Protocol, OUI).

-spec new(
    NetID :: non_neg_integer(),
    DevAddrRanges :: [{non_neg_integer(), non_neg_integer()}],
    EUIs :: [{non_neg_integer(), non_neg_integer()}],
    LNS :: binary(),
    ProtocolType :: gwmp | http_roaming | router,
    OUI :: non_neg_integer()
) -> route().
new(NetID, DevAddrRanges, EUIs, LNS, ProtocolType, OUI) ->
    {Address, Port} = lns_to_ip_and_port(LNS),
    Protocol =
        case ProtocolType of
            gwmp ->
                {gwmp, #config_protocol_gwmp_pb{ip = Address, port = Port}};
            router ->
                {router, #config_protocol_router_pb{ip = Address, port = Port}};
            http_roaming ->
                {http_roaming, #config_protocol_http_roaming_pb{ip = Address, port = Port}}
        end,
    #config_route_v1_pb{
        net_id = NetID,
        devaddr_ranges = [
            #config_devaddr_range_v1_pb{start_addr = Start, end_addr = End}
         || {Start, End} <- DevAddrRanges
        ],
        euis = [
            #config_eui_v1_pb{app_eui = AppEUI, dev_eui = DevEUI}
         || {AppEUI, DevEUI} <- EUIs
        ],
        protocol = Protocol,
        oui = OUI
    }.

lns_to_ip_and_port(LNS) ->
    case binary:split(LNS, <<":">>) of
        [Address] ->
            {Address, 80};
        [Address, Port] ->
            {Address, erlang:binary_to_integer(Port)};
        Err ->
            throw({route_to_dest_err, Err})
    end.

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

routes_res_v1() ->
    #{
        routes =>
            [
                #{
                    devaddr_ranges =>
                        [
                            #{start_addr => 400, end_addr => 500},
                            #{start_addr => 600, end_addr => 650}
                        ],
                    euis => [#{app_eui => 4, dev_eui => 3}],
                    lns => <<"lns2.testdomain.com">>,
                    net_id => 8,
                    oui => 0,
                    protocol => http
                },
                #{
                    devaddr_ranges => [#{'end' => 300, start => 200}],
                    euis => [#{app_eui => 200, dev_eui => 100}],
                    lns => <<"lns1.testdomain.com">>,
                    net_id => 7,
                    oui => 0,
                    protocol => http
                }
            ]
    }.

new_from_config_service_test() ->
    RouteUpdateRes = routes_res_v1(),
    #{routes := RouteConfigs} = RouteUpdateRes,
    RouteConfig0 = hd(RouteConfigs),
    ?assertMatch(
        #route{
            net_id = 8,
            oui = 0,
            protocol = http,
            lns = <<"lns2.testdomain.com">>,
            devaddr_ranges = [
                {400, 500},
                {600, 650}
            ]
        },
        new(RouteConfig0)
    ),
    ok.

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
        ExpectedRoute,
        new(
            1,
            [#{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}],
            [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
            <<"lsn.lora.com>">>,
            gwmp,
            10
        )
    ),
    ok.

net_id_test() ->
    Route = new(1, [{1, 10}, {11, 20}], [{1, 1}, {2, 0}], <<"lsn.lora.com>">>, gwmp, 10),
    ?assertEqual(1, net_id(Route)),
    ok.

devaddr_ranges_test() ->
    Route = new(
        1,
        [#{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}],
        [{1, 1}, {2, 0}],
        <<"lsn.lora.com>">>,
        gwmp,
        10
    ),
    ?assertEqual([{1, 10}, {11, 20}], devaddr_ranges(Route)),
    ok.

euis_test() ->
    Route = new(
        1,
        [{1, 10}, {11, 20}],
        [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        <<"lsn.lora.com>">>,
        gwmp,
        10
    ),
    ?assertEqual(
        [{1, 1}, {2, 0}], euis(Route)
    ),
    ok.

lns_test() ->
    Route = new(1, [{1, 10}, {11, 20}], [{1, 1}, {2, 0}], <<"lsn.lora.com>">>, gwmp, 10),
    %% If no port is in the Endpoint, 80 is assumed.
    ?assertEqual(<<"lsn.lora.com>:80">>, lns(Route)),
    ok.

protocol_test() ->
    Route = new(1, [{1, 10}, {11, 20}], [{1, 1}, {2, 0}], <<"lsn.lora.com>">>, gwmp, 10),
    ?assertEqual(
        {gwmp, #config_protocol_gwmp_pb{ip = <<"lsn.lora.com>">>, port = 80}}, protocol(Route)
    ),
    ok.

oui_test() ->
    Route = new(1, [{1, 10}, {11, 20}], [{1, 1}, {2, 0}], <<"lsn.lora.com>">>, gwmp, 10),
    ?assertEqual(10, oui(Route)),
    ok.

-endif.
