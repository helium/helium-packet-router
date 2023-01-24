-module(hpr_route_ets).

-export([
    init/0,

    insert_route/1,
    delete_route/1,
    lookup_route/1,

    insert_eui_pair/1,
    delete_eui_pair/1,
    lookup_eui_pair/2,

    insert_devaddr_range/1,
    delete_devaddr_range/1,
    lookup_devaddr_range/1,

    delete_all/0
]).

%% CLI exports
-export([
    all_routes/0,
    oui_routes/1,
    eui_pairs_for_route/1,
    devaddr_ranges_for_route/1
]).

-define(ROUTE_ETS, hpr_route_ets_routes).
-define(EUIS_ETS, hpr_route_ets_eui_pairs).
-define(DEVADDRS_ETS, hpr_route_ets_devaddr_ranges).

-spec init() -> ok.
init() ->
    ?DEVADDRS_ETS = ets:new(?DEVADDRS_ETS, [public, named_table, bag, {read_concurrency, true}]),
    ?EUIS_ETS = ets:new(?EUIS_ETS, [public, named_table, bag, {read_concurrency, true}]),
    ?ROUTE_ETS = ets:new(?ROUTE_ETS, [public, named_table, set, {read_concurrency, true}]),
    ok.

-spec insert_route(Route :: hpr_route:route()) -> ok.
insert_route(Route) ->
    true = ets:insert(?ROUTE_ETS, {hpr_route:id(Route), Route}),
    Server = hpr_route:server(Route),
    RouteFields = [
        {id, hpr_route:id(Route)},
        {net_id, hpr_utils:net_id_display(hpr_route:net_id(Route))},
        {oui, hpr_route:oui(Route)},
        {protocol, hpr_route:protocol_type(Server)},
        {max_copies, hpr_route:max_copies(Route)}
    ],
    lager:info(RouteFields, "inserting route"),
    ok.

-spec delete_route(Route :: hpr_route:route()) -> ok.
delete_route(Route) ->
    RouteID = hpr_route:id(Route),
    MS1 = [{{'_', {iot_config_devaddr_range_v1_pb, RouteID, '_', '_'}}, [], [true]}],
    DevAddrEntries = ets:select_delete(?DEVADDRS_ETS, MS1),
    MS2 = [{{'_', {iot_config_eui_pair_v1_pb, RouteID, '_', '_'}}, [], [true]}],
    EUISEntries = ets:select_delete(?EUIS_ETS, MS2),
    true = ets:delete(?ROUTE_ETS, RouteID),
    lager:info("deleted ~w DevAddr Entries, ~w EUIS Entries for ~s", [
        DevAddrEntries, EUISEntries, RouteID
    ]),
    ok.

-spec lookup_route(ID :: string()) -> [hpr_route:route()].
lookup_route(ID) ->
    Routes = ets:lookup(?ROUTE_ETS, ID),
    [Route || {_ID, Route} <- Routes].

-spec insert_eui_pair(EUIPair :: hpr_eui_pair:eui_pair()) -> ok.
insert_eui_pair(EUIPair) ->
    true = ets:insert(?EUIS_ETS, [
        {
            {hpr_eui_pair:app_eui(EUIPair), hpr_eui_pair:dev_eui(EUIPair)},
            EUIPair
        }
    ]),
    ok.

-spec delete_eui_pair(EUIPair :: hpr_eui_pair:eui_pair()) -> ok.
delete_eui_pair(EUIPair) ->
    true = ets:delete_object(?EUIS_ETS, {
        {hpr_eui_pair:app_eui(EUIPair), hpr_eui_pair:dev_eui(EUIPair)},
        EUIPair
    }),
    ok.

-spec lookup_eui_pair(AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()) ->
    [hpr_route:route()].
lookup_eui_pair(AppEUI, 0) ->
    EUIPairs = ets:lookup(?EUIS_ETS, {AppEUI, 0}),
    lists:flatten([?MODULE:lookup_route(hpr_eui_pair:route_id(EUIPair)) || {_, EUIPair} <- EUIPairs]);
lookup_eui_pair(AppEUI, DevEUI) ->
    EUIPairs = ets:lookup(?EUIS_ETS, {AppEUI, DevEUI}),
    lists:usort(
        lists:flatten([
            ?MODULE:lookup_route(hpr_eui_pair:route_id(EUIPair))
         || {_, EUIPair} <- EUIPairs
        ]) ++
            lookup_eui_pair(AppEUI, 0)
    ).

-spec insert_devaddr_range(DevAddrRange :: hpr_devaddr_range:devaddr_range()) -> ok.
insert_devaddr_range(DevAddrRange) ->
    true = ets:insert(?DEVADDRS_ETS, [
        {
            {hpr_devaddr_range:start_addr(DevAddrRange), hpr_devaddr_range:end_addr(DevAddrRange)},
            DevAddrRange
        }
    ]),
    ok.

-spec delete_devaddr_range(DevAddrRange :: hpr_devaddr_range:devaddr_range()) -> ok.
delete_devaddr_range(DevAddrRange) ->
    true = ets:delete_object(?DEVADDRS_ETS, {
        {hpr_devaddr_range:start_addr(DevAddrRange), hpr_devaddr_range:end_addr(DevAddrRange)},
        DevAddrRange
    }),
    ok.

-spec lookup_devaddr_range(DevAddr :: non_neg_integer()) -> [hpr_route:route()].
lookup_devaddr_range(DevAddr) ->
    MS = [
        {
            {{'$1', '$2'}, '$3'},
            [
                {'andalso', {'=<', '$1', DevAddr}, {'=<', DevAddr, '$2'}}
            ],
            ['$3']
        }
    ],
    DevAddrRanges = ets:select(?DEVADDRS_ETS, MS),
    lists:usort(
        lists:flatten([
            ?MODULE:lookup_route(hpr_devaddr_range:route_id(DevAddrRange))
         || DevAddrRange <- DevAddrRanges
        ])
    ).

-spec delete_all() -> ok.
delete_all() ->
    ets:delete_all_objects(?DEVADDRS_ETS),
    ets:delete_all_objects(?EUIS_ETS),
    ets:delete_all_objects(?ROUTE_ETS),
    ok.

%% ------------------------------------------------------------------
%% CLI Functions
%% ------------------------------------------------------------------

-spec all_routes() -> list(hpr_route:route()).
all_routes() ->
    [Route || {_ID, Route} <- ets:tab2list(?ROUTE_ETS)].

-spec oui_routes(OUI :: non_neg_integer()) -> list(hpr_route:route()).
oui_routes(OUI) ->
    [Route || {_ID, Route} <- ets:tab2list(?ROUTE_ETS), OUI == hpr_route:oui(Route)].

-spec eui_pairs_for_route(RouteID :: string()) -> list({non_neg_integer(), non_neg_integer()}).
eui_pairs_for_route(RouteID) ->
    MS = [{{'_', {iot_config_eui_pair_v1_pb, RouteID, '$1', '$2'}}, [], [{'$1', '$2'}]}],
    ets:select(?EUIS_ETS, MS).

-spec devaddr_ranges_for_route(RouteID :: string()) -> list({non_neg_integer(), non_neg_integer()}).
devaddr_ranges_for_route(RouteID) ->
    MS = [{{'_', {iot_config_devaddr_range_v1_pb, RouteID, '$1', '$2'}}, [], [{'$1', '$2'}]}],
    ets:select(?DEVADDRS_ETS, MS).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {setup, fun setup/0,
        {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
            ?_test(test_route()),
            ?_test(test_eui_pair()),
            ?_test(test_devaddr_range()),
            ?_test(test_delete_all())
        ]}}.

setup() ->
    ok.

foreach_setup() ->
    init(),
    ok.

foreach_cleanup(ok) ->
    true = ets:delete(?DEVADDRS_ETS),
    true = ets:delete(?EUIS_ETS),
    true = ets:delete(?ROUTE_ETS),
    ok.

test_route() ->
    Route = hpr_route:test_new(#{
        id => "11ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    RouteID = hpr_route:id(Route),

    ?assertEqual(ok, ?MODULE:insert_route(Route)),
    ?assertEqual([Route], ?MODULE:lookup_route(RouteID)),
    ?assertEqual(ok, ?MODULE:delete_route(Route)),
    ?assertEqual([], ?MODULE:lookup_route(RouteID)),
    ok.

test_eui_pair() ->
    Route1 = hpr_route:test_new(#{
        id => "11ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    Route2 = hpr_route:test_new(#{
        id => "12345678a-3dce-4106-8980-d34007ab689b",
        net_id => 1,
        oui => 2,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    RouteID1 = hpr_route:id(Route1),
    RouteID2 = hpr_route:id(Route2),
    EUIPair1 = hpr_eui_pair:test_new(#{route_id => RouteID1, app_eui => 1, dev_eui => 1}),
    EUIPair2 = hpr_eui_pair:test_new(#{route_id => RouteID1, app_eui => 2, dev_eui => 0}),
    EUIPair3 = hpr_eui_pair:test_new(#{route_id => RouteID2, app_eui => 2, dev_eui => 2}),

    ?assertEqual(ok, ?MODULE:insert_route(Route1)),
    ?assertEqual(ok, ?MODULE:insert_route(Route2)),

    ?assertEqual(ok, ?MODULE:insert_eui_pair(EUIPair1)),
    ?assertEqual(ok, ?MODULE:insert_eui_pair(EUIPair2)),
    ?assertEqual(ok, ?MODULE:insert_eui_pair(EUIPair3)),

    ?assertEqual([Route1], ?MODULE:lookup_eui_pair(1, 1)),
    ?assertEqual([], ?MODULE:lookup_eui_pair(1, 2)),
    ?assertEqual([Route1], ?MODULE:lookup_eui_pair(2, 1)),
    ?assertEqual([Route1, Route2], ?MODULE:lookup_eui_pair(2, 2)),

    EUIPair4 = hpr_eui_pair:test_new(#{route_id => RouteID1, app_eui => 1, dev_eui => 0}),
    ?assertEqual(ok, ?MODULE:insert_eui_pair(EUIPair4)),
    ?assertEqual([Route1], ?MODULE:lookup_eui_pair(1, 1)),
    ?assertEqual(ok, ?MODULE:delete_eui_pair(EUIPair1)),
    ?assertEqual([Route1], ?MODULE:lookup_eui_pair(1, 1)),
    ?assertEqual(ok, ?MODULE:delete_eui_pair(EUIPair4)),
    ?assertEqual([], ?MODULE:lookup_eui_pair(1, 1)),

    ?assertEqual(ok, ?MODULE:delete_eui_pair(EUIPair2)),
    ?assertEqual(ok, ?MODULE:delete_eui_pair(EUIPair3)),
    ?assertEqual([], ?MODULE:lookup_eui_pair(2, 1)),
    ?assertEqual([], ?MODULE:lookup_eui_pair(2, 2)),

    ok.

test_devaddr_range() ->
    Route1 = hpr_route:test_new(#{
        id => "11ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    Route2 = hpr_route:test_new(#{
        id => "12345678a-3dce-4106-8980-d34007ab689b",
        net_id => 1,
        oui => 2,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    RouteID1 = hpr_route:id(Route1),
    RouteID2 = hpr_route:id(Route2),
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000001, end_addr => 16#0000000A
    }),
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => RouteID2, start_addr => 16#00000010, end_addr => 16#0000001A
    }),
    DevAddrRange3 = hpr_devaddr_range:test_new(#{
        route_id => RouteID2, start_addr => 16#00000001, end_addr => 16#00000003
    }),

    ?assertEqual(ok, ?MODULE:insert_route(Route1)),
    ?assertEqual(ok, ?MODULE:insert_route(Route2)),
    ?assertEqual(ok, ?MODULE:insert_devaddr_range(DevAddrRange1)),
    ?assertEqual(ok, ?MODULE:insert_devaddr_range(DevAddrRange2)),
    ?assertEqual(ok, ?MODULE:insert_devaddr_range(DevAddrRange3)),

    ?assertEqual([Route1], ?MODULE:lookup_devaddr_range(16#00000005)),
    ?assertEqual([Route2], ?MODULE:lookup_devaddr_range(16#00000010)),
    ?assertEqual([Route2], ?MODULE:lookup_devaddr_range(16#0000001A)),
    ?assertEqual([Route1, Route2], ?MODULE:lookup_devaddr_range(16#00000002)),

    ?assertEqual(ok, ?MODULE:delete_devaddr_range(DevAddrRange1)),
    ?assertEqual([], ?MODULE:lookup_devaddr_range(16#00000005)),
    ?assertEqual([Route2], ?MODULE:lookup_devaddr_range(16#00000002)),

    ?assertEqual(ok, ?MODULE:delete_devaddr_range(DevAddrRange2)),
    ?assertEqual([], ?MODULE:lookup_devaddr_range(16#00000010)),
    ?assertEqual([], ?MODULE:lookup_devaddr_range(16#0000001A)),

    ?assertEqual(ok, ?MODULE:delete_devaddr_range(DevAddrRange3)),
    ?assertEqual([], ?MODULE:lookup_devaddr_range(16#00000002)),

    ok.

test_delete_all() ->
    Route = hpr_route:test_new(#{
        id => "11ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    RouteID = hpr_route:id(Route),
    EUIPair = hpr_eui_pair:test_new(#{route_id => RouteID, app_eui => 1, dev_eui => 1}),
    DevAddrRange = hpr_devaddr_range:test_new(#{
        route_id => RouteID, start_addr => 16#00000001, end_addr => 16#0000000A
    }),

    ?assertEqual(ok, ?MODULE:insert_route(Route)),
    ?assertEqual(ok, ?MODULE:insert_eui_pair(EUIPair)),
    ?assertEqual(ok, ?MODULE:insert_devaddr_range(DevAddrRange)),
    ?assertEqual(ok, ?MODULE:delete_all()),
    ?assertEqual([], ets:tab2list(?DEVADDRS_ETS)),
    ?assertEqual([], ets:tab2list(?EUIS_ETS)),
    ?assertEqual([], ets:tab2list(?ROUTE_ETS)),
    ok.

-endif.
