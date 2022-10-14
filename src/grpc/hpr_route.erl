-module(hpr_route).

-include("../grpc/autogen/server/config_pb.hrl").

-export([
    new/1,
    net_id/1,
    devaddr_ranges/1, devaddr_ranges/2,
    euis/1, euis/2,
    server/1,
    oui/1,
    max_copies/1,
    lns/1,
    region_lns/2
]).

-export([
    host/1,
    port/1,
    protocol/1
]).

-type route() :: #config_route_v1_pb{}.

-type server() :: #config_server_v1_pb{}.

-type protocol() ::
    {packet_router, #config_protocol_packet_router_v1_pb{}}
    | {gwmp, #config_protocol_gwmp_v1_pb{}}
    | {http_roaming, #config_protocol_http_roaming_v1_pb{}}
    | undefined.

-export_type([route/0, server/0, protocol/0]).

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

-spec devaddr_ranges(Route :: route(), DevRanges :: [#config_devaddr_range_v1_pb{}]) -> route().
devaddr_ranges(Route, DevRanges) ->
    Route#config_route_v1_pb{devaddr_ranges = DevRanges}.

-spec euis(Route :: route()) -> [{non_neg_integer(), non_neg_integer()}].
euis(Route) ->
    [
        {AppEUI, DevEUI}
     || #config_eui_v1_pb{app_eui = AppEUI, dev_eui = DevEUI} <-
            Route#config_route_v1_pb.euis
    ].

-spec euis(Route :: route(), EUIs :: [#config_eui_v1_pb{}]) -> route().
euis(Route, EUIs) ->
    Route#config_route_v1_pb{euis = EUIs}.

-spec server(Route :: route()) -> server().
server(Route) ->
    Route#config_route_v1_pb.server.

-spec oui(Route :: route()) -> non_neg_integer().
oui(Route) ->
    Route#config_route_v1_pb.oui.

-spec max_copies(Route :: route()) -> non_neg_integer().
max_copies(Route) ->
    Route#config_route_v1_pb.max_copies.

-spec lns(Route :: route()) -> binary().
lns(Route) ->
    Server = ?MODULE:server(Route),
    Host = ?MODULE:host(Server),
    Port = ?MODULE:port(Server),
    <<Host/binary, $:, (erlang:integer_to_binary(Port))/binary>>.

-spec region_lns(Region :: atom(), Route :: route()) -> binary().
region_lns(Region, Route) ->
    Server = ?MODULE:server(Route),

    case ?MODULE:protocol(Server) of
        {gwmp, #config_protocol_gwmp_v1_pb{mapping = Mapping}} ->
            Host = ?MODULE:host(Server),
            Port =
                case lists:keyfind(Region, 2, Mapping) of
                    false -> ?MODULE:port(Server);
                    #config_protocol_gwmp_mapping_v1_pb{port = P} -> P
                end,
            <<Host/binary, $:, (erlang:integer_to_binary(Port))/binary>>;
        _ ->
            ?MODULE:lns(Route)
    end.

-spec host(Server :: server()) -> binary().
host(Server) ->
    Server#config_server_v1_pb.host.

-spec port(Server :: server()) -> non_neg_integer().
port(Server) ->
    Server#config_server_v1_pb.port.

-spec protocol(Server :: server()) -> protocol().
protocol(Server) ->
    Server#config_server_v1_pb.protocol.

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
        oui = 10,
        server = #config_server_v1_pb{
            host = <<"lsn.lora.com">>,
            port = 80,
            protocol = {gwmp, #config_protocol_gwmp_v1_pb{mapping = []}}
        },
        max_copies = 1
    },
    ?assertEqual(
        Route,
        ?MODULE:new(#{
            net_id => 1,
            devaddr_ranges => [
                #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
            ],
            euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
            oui => 10,
            server => #{
                host => <<"lsn.lora.com">>,
                port => 80,
                protocol => {gwmp, #{mapping => []}}
            },
            max_copies => 1
        })
    ),
    ok.

net_id_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1
    }),
    ?assertEqual(1, ?MODULE:net_id(Route)),
    ok.

devaddr_ranges_1_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1
    }),
    ?assertEqual([{1, 10}, {11, 20}], ?MODULE:devaddr_ranges(Route)),
    ok.

devaddr_ranges_2_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1
    }),
    ?assertEqual([], ?MODULE:devaddr_ranges(?MODULE:devaddr_ranges(Route, []))),
    ok.

euis_1_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1
    }),
    ?assertEqual(
        [{1, 1}, {2, 0}], ?MODULE:euis(Route)
    ),
    ok.

euis_2_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1
    }),
    ?assertEqual(
        [], ?MODULE:euis(?MODULE:euis(Route, []))
    ),
    ok.

server_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        }
    }),
    ?assertEqual(
        #config_server_v1_pb{
            host = <<"lsn.lora.com">>,
            port = 80,
            protocol = {gwmp, #config_protocol_gwmp_v1_pb{mapping = []}}
        },
        ?MODULE:server(Route)
    ),
    ok.

lns_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        }
    }),
    ?assertEqual(<<"lsn.lora.com:80">>, ?MODULE:lns(Route)),
    ok.

region_lns_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol =>
                {gwmp, #{
                    mapping => [
                        #{region => 'US915', port => 81},
                        #{region => 'EU868', port => 82},
                        #{region => 'AS923_1', port => 83}
                    ]
                }}
        }
    }),
    ?assertEqual(<<"lsn.lora.com:81">>, ?MODULE:region_lns('US915', Route)),
    ?assertEqual(<<"lsn.lora.com:82">>, ?MODULE:region_lns('EU868', Route)),
    ?assertEqual(<<"lsn.lora.com:83">>, ?MODULE:region_lns('AS923_1', Route)),
    ?assertEqual(<<"lsn.lora.com:80">>, ?MODULE:region_lns('AS923_2', Route)),
    ok.

oui_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1
    }),
    ?assertEqual(10, ?MODULE:oui(Route)),
    ok.

server_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1
    }),
    ?assertEqual(
        #config_server_v1_pb{
            host = <<"lsn.lora.com">>,
            port = 80,
            protocol = {gwmp, #config_protocol_gwmp_v1_pb{mapping = []}}
        },
        ?MODULE:server(Route)
    ),
    ok.

max_copies_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1
    }),
    ?assertEqual(1, ?MODULE:max_copies(Route)),
    ok.

lns_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1
    }),
    ?assertEqual(<<"lsn.lora.com:80">>, ?MODULE:lns(Route)),
    ok.

host_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1
    }),
    ?assertEqual(<<"lsn.lora.com">>, ?MODULE:host(?MODULE:server(Route))),
    ok.

port_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1
    }),
    ?assertEqual(80, ?MODULE:port(?MODULE:server(Route))),
    ok.

protocol_test() ->
    Route = ?MODULE:new(#{
        net_id => 1,
        devaddr_ranges => [
            #{start_addr => 1, end_addr => 10}, #{start_addr => 11, end_addr => 20}
        ],
        euis => [#{app_eui => 1, dev_eui => 1}, #{app_eui => 2, dev_eui => 0}],
        oui => 10,
        server => #{
            host => <<"lsn.lora.com">>,
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1
    }),
    ?assertEqual(
        {gwmp, #config_protocol_gwmp_v1_pb{mapping = []}}, ?MODULE:protocol(?MODULE:server(Route))
    ),
    ok.

-endif.
