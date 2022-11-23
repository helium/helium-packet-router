-module(hpr_route_ets).

-export([
    init/0,
    insert/1,
    delete/1,
    lookup_devaddr/1,
    lookup_eui/2
]).

%% CLI exports
-export([
    all_routes/0,
    oui_routes/1
]).

-ifdef(TEST).

-export([
    remove_euis_dev_ranges/1
]).

-endif.

-define(DEVADDRS_ETS, hpr_route_ets_routes_by_devaddr).
-define(EUIS_ETS, hpr_route_ets_routes_by_eui).
-define(ROUTE_ETS, hpr_route_ets_routes).

-spec init() -> ok.
init() ->
    ?DEVADDRS_ETS = ets:new(?DEVADDRS_ETS, [public, named_table, bag, {read_concurrency, true}]),
    ?EUIS_ETS = ets:new(?EUIS_ETS, [public, named_table, bag, {read_concurrency, true}]),
    ?ROUTE_ETS = ets:new(?ROUTE_ETS, [public, named_table, set]),
    ok.

-spec insert(Route :: hpr_route:route()) -> ok.
insert(Route) ->
    ok = ?MODULE:delete(Route),
    true = ets:insert(?DEVADDRS_ETS, route_to_devaddr_rows(Route)),
    true = ets:insert(?EUIS_ETS, route_to_eui_rows(Route)),
    true = ets:insert(?ROUTE_ETS, {hpr_route:id(Route), Route}),
    Server = hpr_route:server(Route),
    RouteFields = [
        {id, erlang:binary_to_list(hpr_route:id(Route))},
        {net_id, hpr_utils:net_id_display(hpr_route:net_id(Route))},
        {oui, hpr_route:oui(Route)},
        {protocol, hpr_route:protocol_type(Server)},
        {max_copies, hpr_route:max_copies(Route)},
        {devaddr_cnt, erlang:length(hpr_route:devaddr_ranges(Route))},
        {eui_cnt, erlang:length(hpr_route:euis(Route))}
    ],
    lager:info(RouteFields, "inserting route"),
    ok.

-spec delete(Route :: hpr_route:route()) -> ok.
delete(Route) ->
    ID = hpr_route:id(Route),
    MS = [
        {
            {'_', {config_route_v1_pb, ID, '_', '_', '_', '_', '_', '_', '_'}},
            [],
            [true]
        }
    ],
    DevAddrEntries = ets:select_delete(?DEVADDRS_ETS, MS),
    EUISEntries = ets:select_delete(?EUIS_ETS, MS),
    true = ets:delete(?ROUTE_ETS, ID),
    lager:info("deleted ~w DevAddr Entries, ~w EUIS Entries for ~s", [
        DevAddrEntries, EUISEntries, ID
    ]),
    ok.

-spec lookup_devaddr(Devaddr :: non_neg_integer()) -> list(hpr_route:route()).
lookup_devaddr(Devaddr) ->
    case lora_subnet:parse_netid(Devaddr, big) of
        {error, invalid_netid_type} ->
            lager:debug("invalid devaddr ~p", [Devaddr]),
            [];
        {ok, NetID} ->
            MS = [
                {
                    {{NetID, '$2', '$3'}, '$4'},
                    [
                        {'andalso', {'=<', '$2', Devaddr}, {'=<', Devaddr, '$3'}}
                    ],
                    ['$4']
                }
            ],
            ets:select(?DEVADDRS_ETS, MS)
    end.

-spec lookup_eui(AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()) ->
    list(hpr_route:route()).
lookup_eui(AppEUI, 0) ->
    Routes = ets:lookup(?EUIS_ETS, {AppEUI, 0}),
    [Route || {_, Route} <- Routes];
lookup_eui(AppEUI, DevEUI) ->
    Routes = ets:lookup(?EUIS_ETS, {AppEUI, DevEUI}),
    [Route || {_, Route} <- Routes] ++ lookup_eui(AppEUI, 0).

%% ------------------------------------------------------------------
%% CLI Functions
%% ------------------------------------------------------------------

-spec all_routes() -> list(hpr_route:route()).
all_routes() ->
    [Route || {_ID, Route} <- ets:tab2list(?ROUTE_ETS)].

-spec oui_routes(OUI :: non_neg_integer()) -> list(hpr_route:route()).
oui_routes(OUI) ->
    [Route || {_ID, Route} <- ets:tab2list(?ROUTE_ETS), OUI == hpr_route:oui(Route)].

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec route_to_devaddr_rows(Route :: hpr_route:route()) -> list().
route_to_devaddr_rows(Route) ->
    NetID = hpr_route:net_id(Route),
    Ranges = hpr_route:devaddr_ranges(Route),
    CleanedRoute = remove_euis_dev_ranges(Route),
    [{{NetID, Start, End}, CleanedRoute} || {Start, End} <- Ranges].

-spec route_to_eui_rows(Route :: hpr_route:route()) -> list().
route_to_eui_rows(Route) ->
    EUIs = hpr_route:euis(Route),
    CleanedRoute = remove_euis_dev_ranges(Route),
    [{{AppEUI, DevEUI}, CleanedRoute} || {AppEUI, DevEUI} <- EUIs].

-spec remove_euis_dev_ranges(Route :: hpr_route:route()) -> hpr_route:route().
remove_euis_dev_ranges(Route) ->
    hpr_route:euis(hpr_route:devaddr_ranges(Route, []), []).

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {setup, fun setup/0,
        {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
            ?_test(test_insert()),
            ?_test(test_delete()),
            ?_test(test_devaddr_lookup()),
            ?_test(test_eui_lookup()),
            ?_test(test_route_to_devaddr_rows()),
            ?_test(test_route_to_eui_rows())
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

test_insert() ->
    Route = hpr_route:new(#{
        id => <<"11ea6dfd-3dce-4106-8980-d34007ab689b">>,
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A},
            #{start_addr => 16#00000010, end_addr => 16#0000001A}
        ],
        euis => [#{app_eui => 1, dev_eui => 2}, #{app_eui => 3, dev_eui => 4}],
        oui => 1,
        server => #{
            host => <<"lns1.testdomain.com">>,
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1,
        nonce => 1
    }),
    ok = insert(Route),

    ExpectedDevaddrRows0 = lists:sort(route_to_devaddr_rows(Route)),
    ExpectedEUIRows0 = lists:sort(route_to_eui_rows(Route)),

    GotDevaddrRows0 = lists:sort(ets:tab2list(?DEVADDRS_ETS)),
    GotEUIRows0 = lists:sort(ets:tab2list(?EUIS_ETS)),

    ?assertEqual(
        ExpectedDevaddrRows0,
        [{K, remove_euis_dev_ranges(R)} || {K, R} <- GotDevaddrRows0]
    ),
    ?assertEqual(ExpectedEUIRows0, [{K, remove_euis_dev_ranges(R)} || {K, R} <- GotEUIRows0]),

    ID = hpr_route:id(Route),
    ?assertEqual([{ID, Route}], ets:lookup(?ROUTE_ETS, ID)),

    UpdatedRoute = hpr_route:new(#{
        id => <<"11ea6dfd-3dce-4106-8980-d34007ab689b">>,
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A}
        ],
        euis => [
            #{app_eui => 1, dev_eui => 2},
            #{app_eui => 3, dev_eui => 4},
            #{app_eui => 5, dev_eui => 6}
        ],
        oui => 1,
        server => #{
            host => <<"lns1.testdomain.com">>,
            port => 8080,
            protocol => {http_roaming, #{}}
        },
        max_copies => 100,
        nonce => 2
    }),

    ok = insert(UpdatedRoute),

    ExpectedDevaddrRows1 = lists:sort(route_to_devaddr_rows(UpdatedRoute)),
    ExpectedEUIRows1 = lists:sort(route_to_eui_rows(UpdatedRoute)),

    GotDevaddrRows1 = lists:sort(ets:tab2list(?DEVADDRS_ETS)),
    GotEUIRows1 = lists:sort(ets:tab2list(?EUIS_ETS)),

    ?assertEqual(
        ExpectedDevaddrRows1,
        [{K, remove_euis_dev_ranges(R)} || {K, R} <- GotDevaddrRows1]
    ),
    ?assertEqual(ExpectedEUIRows1, [{K, remove_euis_dev_ranges(R)} || {K, R} <- GotEUIRows1]),
    ?assertEqual([{ID, UpdatedRoute}], ets:lookup(?ROUTE_ETS, ID)),
    ok.

test_delete() ->
    Route = new_route(),
    ok = insert(Route),

    ExpectedDevaddrRows = lists:sort(route_to_devaddr_rows(Route)),
    ExpectedEUIRows = lists:sort(route_to_eui_rows(Route)),

    GotDevaddrRows = lists:sort(ets:tab2list(?DEVADDRS_ETS)),
    GotEUIRows = lists:sort(ets:tab2list(?EUIS_ETS)),

    ?assertEqual(ExpectedDevaddrRows, [{K, remove_euis_dev_ranges(R)} || {K, R} <- GotDevaddrRows]),
    ?assertEqual(ExpectedEUIRows, [{K, remove_euis_dev_ranges(R)} || {K, R} <- GotEUIRows]),

    ID = hpr_route:id(Route),
    ?assertEqual([{ID, Route}], ets:lookup(?ROUTE_ETS, ID)),

    ok = delete(Route),

    ?assertEqual([], ets:tab2list(?DEVADDRS_ETS)),
    ?assertEqual([], ets:tab2list(?EUIS_ETS)),
    ?assertEqual([], ets:lookup(?ROUTE_ETS, ID)),
    ok.

test_devaddr_lookup() ->
    Route = new_route(),
    CleanedRoute = remove_euis_dev_ranges(Route),
    ok = insert(Route),

    ?assertEqual([CleanedRoute], lookup_devaddr(16#00000005)),
    ?assertEqual([], lookup_devaddr(16#0000000B)),
    ?assertEqual([], lookup_devaddr(16#00000000)),
    ok.

test_eui_lookup() ->
    Route1 = hpr_route:new(#{
        id => <<"11ea6dfd-3dce-4106-8980-d34007ab689b">>,
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A},
            #{start_addr => 16#00000010, end_addr => 16#0000001A}
        ],
        euis => [#{app_eui => 1, dev_eui => 2}, #{app_eui => 3, dev_eui => 4}],
        oui => 1,
        server => #{
            host => <<"lns1.testdomain.com">>,
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1,
        nonce => 1
    }),

    Route2 = hpr_route:new(#{
        id => <<"be427c6d-d3b7-4146-ae14-1fc662034f6d">>,
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A},
            #{start_addr => 16#00000010, end_addr => 16#0000001A}
        ],
        euis => [#{app_eui => 1, dev_eui => 0}, #{app_eui => 5, dev_eui => 6}],
        oui => 1,
        server => #{
            host => <<"lns2.testdomain.com">>,
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1,
        nonce => 1
    }),

    ok = insert(Route1),
    ok = insert(Route2),
    CleanedRoute1 = remove_euis_dev_ranges(Route1),
    CleanedRoute2 = remove_euis_dev_ranges(Route2),

    ?assertEqual([CleanedRoute1], lookup_eui(3, 4)),
    ?assertEqual([CleanedRoute2], lookup_eui(5, 6)),
    ?assertEqual(lists:sort([CleanedRoute1, CleanedRoute2]), lists:sort(lookup_eui(1, 2))),
    ?assertEqual([CleanedRoute2], lookup_eui(1, 0)),

    ok.

test_route_to_devaddr_rows() ->
    Route = new_route(),
    CleanedRoute = remove_euis_dev_ranges(Route),
    ?assertEqual(
        [
            {{0, 16#00000001, 16#0000000A}, CleanedRoute},
            {{0, 16#00000010, 16#0000001A}, CleanedRoute}
        ],
        route_to_devaddr_rows(Route)
    ).

test_route_to_eui_rows() ->
    Route = new_route(),
    CleanedRoute = remove_euis_dev_ranges(Route),
    ?assertEqual([{{1, 2}, CleanedRoute}, {{3, 4}, CleanedRoute}], route_to_eui_rows(Route)).

new_route() ->
    hpr_route:new(#{
        id => <<"7d502f32-4d58-4746-965e-8c7dfdcfc624">>,
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A},
            #{start_addr => 16#00000010, end_addr => 16#0000001A}
        ],
        euis => [#{app_eui => 1, dev_eui => 2}, #{app_eui => 3, dev_eui => 4}],
        oui => 1,
        server => #{
            host => <<"lns1.testdomain.com">>,
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1,
        nonce => 1
    }).

-endif.
