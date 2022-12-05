-module(hpr_route).

-include("../autogen/config_pb.hrl").

-export([
    id/1,
    net_id/1,
    devaddr_ranges/1, devaddr_ranges/2,
    euis/1, euis/2,
    server/1,
    oui/1,
    max_copies/1,
    nonce/1,
    lns/1,
    gwmp_region_lns/2
]).

-export([
    host/1,
    port/1,
    protocol/1,
    http_roaming_flow_type/1,
    protocol_type/1,
    http_roaming_dedupe_timeout/1,
    http_roaming_path/1
]).

-ifdef(TEST).

-export([test_new/1]).

-endif.

-type route() :: #config_route_v1_pb{}.
-type server() :: #config_server_v1_pb{}.
-type protocol() ::
    {packet_router, #config_protocol_packet_router_v1_pb{}}
    | {gwmp, #config_protocol_gwmp_v1_pb{}}
    | {http_roaming, #config_protocol_http_roaming_v1_pb{}}
    | undefined.
-type protocol_type() :: packet_router | gwmp | http_roaming | undefined.

-export_type([route/0, server/0, protocol/0]).

-spec id(Route :: route()) -> binary().
id(Route) ->
    Route#config_route_v1_pb.id.

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

-spec nonce(Route :: route()) -> non_neg_integer().
nonce(Route) ->
    Route#config_route_v1_pb.nonce.

-spec lns(Route :: route()) -> binary().
lns(Route) ->
    Server = ?MODULE:server(Route),
    Host = ?MODULE:host(Server),
    Port = ?MODULE:port(Server),
    case Server#config_server_v1_pb.protocol of
        {http_roaming, _RoamingProtocol} ->
            Path = http_roaming_path(Route),
            <<Host/binary, $:, (erlang:integer_to_binary(Port))/binary, Path/binary>>;
        _ ->
            <<Host/binary, $:, (erlang:integer_to_binary(Port))/binary>>
    end.

-spec gwmp_region_lns(Region :: atom(), Route :: route()) ->
    {Address :: string(), Port :: inet:port_number()}.
gwmp_region_lns(Region, Route) ->
    Server = ?MODULE:server(Route),
    {gwmp, #config_protocol_gwmp_v1_pb{mapping = Mapping}} = ?MODULE:protocol(Server),

    Host = ?MODULE:host(Server),
    Port =
        case lists:keyfind(Region, 2, Mapping) of
            false -> ?MODULE:port(Server);
            #config_protocol_gwmp_mapping_v1_pb{port = P} -> P
        end,
    {erlang:binary_to_list(Host), Port}.

-spec host(Server :: server()) -> binary().
host(Server) ->
    Server#config_server_v1_pb.host.

-spec port(Server :: server()) -> non_neg_integer().
port(Server) ->
    Server#config_server_v1_pb.port.

-spec protocol(Server :: server()) -> protocol().
protocol(Server) ->
    Server#config_server_v1_pb.protocol.

-spec http_roaming_flow_type(Route :: route()) -> sync | async.
http_roaming_flow_type(Route) ->
    Server = Route#config_route_v1_pb.server,
    {http_roaming, HttpRoamingProtocol} = Server#config_server_v1_pb.protocol,
    HttpRoamingProtocol#config_protocol_http_roaming_v1_pb.flow_type.

-spec http_roaming_dedupe_timeout(Route :: route()) -> non_neg_integer() | undefined.
http_roaming_dedupe_timeout(Route) ->
    Server = Route#config_route_v1_pb.server,
    {http_roaming, HttpRoamingProtocol} = Server#config_server_v1_pb.protocol,
    HttpRoamingProtocol#config_protocol_http_roaming_v1_pb.dedupe_timeout.

-spec http_roaming_path(Route :: route()) -> binary().
http_roaming_path(Route) ->
    Server = Route#config_route_v1_pb.server,
    case Server#config_server_v1_pb.protocol of
        {http_roaming, HttpRoamingProtocol} ->
            erlang:list_to_binary(
                HttpRoamingProtocol#config_protocol_http_roaming_v1_pb.path
            );
        _ ->
            <<>>
    end.

-spec protocol_type(Server :: server()) -> protocol_type().
protocol_type(Server) ->
    case Server#config_server_v1_pb.protocol of
        {Type, _} -> Type;
        undefined -> undefined
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-spec test_new(RouteMap :: map()) -> route().
test_new(RouteMap) ->
    #config_route_v1_pb{
        id = maps:get(id, RouteMap),
        net_id = maps:get(net_id, RouteMap),
        devaddr_ranges = [
            #config_devaddr_range_v1_pb{start_addr = S, end_addr = E}
         || #{start_addr := S, end_addr := E} <- maps:get(devaddr_ranges, RouteMap)
        ],
        euis = [
            #config_eui_v1_pb{dev_eui = D, app_eui = A}
         || #{dev_eui := D, app_eui := A} <- maps:get(euis, RouteMap)
        ],
        oui = maps:get(oui, RouteMap),
        server = mk_server(maps:get(server, RouteMap)),
        max_copies = maps:get(max_copies, RouteMap),
        nonce = maps:get(nonce, RouteMap)
    }.

-spec mk_server(map()) -> #config_server_v1_pb{}.
mk_server(ServerMap) ->
    #config_server_v1_pb{
        host = maps:get(host, ServerMap),
        port = maps:get(port, ServerMap),
        protocol = mk_protocol(maps:get(protocol, ServerMap))
    }.

-spec mk_protocol({protocol_type(), map()}) -> protocol().
mk_protocol({packet_router, _PacketRouterMap}) ->
    {packet_router, #config_protocol_packet_router_v1_pb{}};
mk_protocol({gwmp, GwmpMap}) ->
    Mapping = [
        #config_protocol_gwmp_mapping_v1_pb{region = Region, port = Port}
     || #{region := Region, port := Port} <- maps:get(mapping, GwmpMap)
    ],
    {gwmp, #config_protocol_gwmp_v1_pb{mapping = Mapping}};
mk_protocol({http_roaming, HttpMap}) ->
    Template = #config_protocol_http_roaming_v1_pb{},
    {http_roaming, #config_protocol_http_roaming_v1_pb{
        flow_type = maps:get(
            flow_type, HttpMap, Template#config_protocol_http_roaming_v1_pb.flow_type
        ),
        dedupe_timeout = maps:get(
            dedupe_timeout, HttpMap, Template#config_protocol_http_roaming_v1_pb.dedupe_timeout
        ),
        path = maps:get(path, HttpMap, Template#config_protocol_http_roaming_v1_pb.path)
    }};
mk_protocol(undefined) ->
    undefined.

test_new_test() ->
    Route = #config_route_v1_pb{
        id = <<"7d502f32-4d58-4746-965e-8c7dfdcfc624">>,
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
        max_copies = 1,
        nonce = 1
    },
    ?assertEqual(
        Route,
        ?MODULE:test_new(#{
            id => <<"7d502f32-4d58-4746-965e-8c7dfdcfc624">>,
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
            max_copies => 1,
            nonce => 1
        })
    ),
    ok.

id_test() ->
    Route = test_route(),
    ?assertEqual(<<"7d502f32-4d58-4746-965e-8c7dfdcfc624">>, ?MODULE:id(Route)),
    ok.

net_id_test() ->
    Route = test_route(),
    ?assertEqual(1, ?MODULE:net_id(Route)),
    ok.

devaddr_ranges_1_test() ->
    Route = test_route(),
    ?assertEqual([{1, 10}, {11, 20}], ?MODULE:devaddr_ranges(Route)),
    ok.

devaddr_ranges_2_test() ->
    Route = test_route(),
    ?assertEqual([], ?MODULE:devaddr_ranges(?MODULE:devaddr_ranges(Route, []))),
    ok.

euis_1_test() ->
    Route = test_route(),
    ?assertEqual([{1, 1}, {2, 0}], ?MODULE:euis(Route)),
    ok.

euis_2_test() ->
    Route = test_route(),
    ?assertEqual([], ?MODULE:euis(?MODULE:euis(Route, []))),
    ok.

region_lns_test() ->
    Route = ?MODULE:test_new(#{
        id => <<"7d502f32-4d58-4746-965e-8c7dfdcfc624">>,
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
        },
        max_copies => 1,
        nonce => 1
    }),
    ?assertEqual({"lsn.lora.com", 81}, ?MODULE:gwmp_region_lns('US915', Route)),
    ?assertEqual({"lsn.lora.com", 82}, ?MODULE:gwmp_region_lns('EU868', Route)),
    ?assertEqual({"lsn.lora.com", 83}, ?MODULE:gwmp_region_lns('AS923_1', Route)),
    ?assertEqual({"lsn.lora.com", 80}, ?MODULE:gwmp_region_lns('AS923_2', Route)),
    ok.

oui_test() ->
    Route = test_route(),
    ?assertEqual(10, ?MODULE:oui(Route)),
    ok.

server_test() ->
    Route = test_route(),
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
    Route = test_route(),
    ?assertEqual(1, ?MODULE:max_copies(Route)),
    ok.

nonce_test() ->
    Route = test_route(),
    ?assertEqual(1, ?MODULE:nonce(Route)),
    ok.

lns_test() ->
    Route = test_route(),
    ?assertEqual(<<"lsn.lora.com:80">>, ?MODULE:lns(Route)),
    ok.

host_test() ->
    Route = test_route(),
    ?assertEqual(<<"lsn.lora.com">>, ?MODULE:host(?MODULE:server(Route))),
    ok.

port_test() ->
    Route = test_route(),
    ?assertEqual(80, ?MODULE:port(?MODULE:server(Route))),
    ok.

protocol_test() ->
    Route = test_route(),
    ?assertEqual({gwmp, #config_protocol_gwmp_v1_pb{mapping = []}}, ?MODULE:protocol(?MODULE:server(Route))),
    ok.

test_route() ->
    ?MODULE:test_new(#{
        id => <<"7d502f32-4d58-4746-965e-8c7dfdcfc624">>,
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
        max_copies => 1,
        nonce => 1
    }).

-endif.
