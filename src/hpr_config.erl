-module(hpr_config).

-export([
    init/0,
    stop/0,
    update_routes/1,
    insert_route/1,
    lookup_devaddr/1,
    lookup_eui/2
]).

-define(DEVADDRS_ETS, hpr_config_routes_by_devaddr).
-define(EUIS_ETS, hpr_config_routes_by_eui).

-spec init() -> ok.
init() ->
    ?DEVADDRS_ETS = ets:new(?DEVADDRS_ETS, [public, named_table, bag, {read_concurrency, true}]),
    ?EUIS_ETS = ets:new(?EUIS_ETS, [public, named_table, bag, {read_concurrency, true}]),
    ok.

-spec stop() -> ok.
stop() ->
    true = ets:delete(?DEVADDRS_ETS),
    true = ets:delete(?EUIS_ETS),
    ok.

-spec update_routes(map()) -> ok.
update_routes(#{routes := Routes}) ->
    {NewDevaddrRows, NewEUIRows} = lists:foldl(
        fun(RouteConfig, {DevaddrRowsAcc, EUIRowsAcc}) ->
            Route = hpr_route:new(RouteConfig),
            DevaddrRowsAcc2 = DevaddrRowsAcc ++ route_to_devaddr_rows(Route),
            EUIRowsAcc2 = EUIRowsAcc ++ route_to_eui_rows(Route),
            {DevaddrRowsAcc2, EUIRowsAcc2}
        end,
        {[], []},
        Routes
    ),
    true = ets:delete_all_objects(?DEVADDRS_ETS),
    true = ets:delete_all_objects(?EUIS_ETS),
    true = ets:insert(?DEVADDRS_ETS, NewDevaddrRows),
    true = ets:insert(?EUIS_ETS, NewEUIRows),
    ok.

-spec insert_route(Route :: hpr_route:route()) -> ok.
insert_route(Route) ->
    DevaddrRecords = route_to_devaddr_rows(Route),
    EUIRecords = route_to_eui_rows(Route),
    true = ets:insert(?DEVADDRS_ETS, DevaddrRecords),
    true = ets:insert(?EUIS_ETS, EUIRecords),
    ok.

-spec lookup_devaddr(Devaddr :: non_neg_integer()) -> list(hpr_route:route()).
lookup_devaddr(Devaddr) ->
    {ok, NetID} = lora_subnet:parse_netid(Devaddr, big),
    MS = [
        {
            {{'$1', '$2', '$3'}, '$4'},
            [
                {'andalso', {'==', '$1', NetID},
                    {'andalso', {'=<', '$2', Devaddr}, {'=<', Devaddr, '$3'}}}
            ],
            ['$4']
        }
    ],
    ets:select(?DEVADDRS_ETS, MS).

-spec lookup_eui(AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()) ->
    list(hpr_route:route()).
lookup_eui(AppEUI, 0) ->
    Routes = ets:lookup(?EUIS_ETS, {AppEUI, 0}),
    [Route || {_, Route} <- Routes];
lookup_eui(AppEUI, DevEUI) ->
    Routes = ets:lookup(?EUIS_ETS, {AppEUI, DevEUI}),
    [Route || {_, Route} <- Routes] ++ lookup_eui(AppEUI, 0).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec route_to_devaddr_rows(Route :: hpr_route:route()) -> list().
route_to_devaddr_rows(Route) ->
    NetID = hpr_route:net_id(Route),
    Ranges = hpr_route:devaddr_ranges(Route),
    [{{NetID, Start, End}, Route} || {Start, End} <- Ranges].

-spec route_to_eui_rows(Route :: hpr_route:route()) -> list().
route_to_eui_rows(Route) ->
    EUIs = hpr_route:euis(Route),
    [{{AppEUI, DevEUI}, Route} || {AppEUI, DevEUI} <- EUIs].

%% ------------------------------------------------------------------
% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

route_v1() ->
    hpr_route:new(#{
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A},
            #{start_addr => 16#00000010, end_addr => 16#0000001A}
        ],
        euis => [#{app_eui => 1, dev_eui => 2}, #{app_eui => 3, dev_eui => 4}],
        oui => 1,
        protocol => {http_roaming, #{ip => <<"lns1.testdomain.com">>, port => 80}}
    }).

route_to_devaddr_rows_test() ->
    Route = route_v1(),
    ?assertEqual(
        [{{0, 16#00000001, 16#0000000A}, Route}, {{0, 16#00000010, 16#0000001A}, Route}],
        route_to_devaddr_rows(Route)
    ).

route_to_eui_rows_test() ->
    Route = route_v1(),
    ?assertEqual([{{1, 2}, Route}, {{3, 4}, Route}], route_to_eui_rows(Route)).

route_insert_test() ->
    ok = init(),
    Route = route_v1(),
    ok = insert_route(Route),

    ExpectedDevaddrRows = lists:sort(route_to_devaddr_rows(Route)),
    ExpectedEUIRows = lists:sort(route_to_eui_rows(Route)),

    GotDevaddrRows = lists:sort(ets:tab2list(?DEVADDRS_ETS)),
    GotEUIRows = lists:sort(ets:tab2list(?EUIS_ETS)),

    ?assertEqual(ExpectedDevaddrRows, GotDevaddrRows),
    ?assertEqual(ExpectedEUIRows, GotEUIRows),
    ok = stop(),
    ok.

devaddr_lookup_test() ->
    ok = init(),
    Route = route_v1(),
    ok = insert_route(Route),

    ?assertEqual([Route], lookup_devaddr(16#00000005)),
    ?assertEqual([], lookup_devaddr(16#0000000B)),
    ?assertEqual([], lookup_devaddr(16#00000000)),
    ok = stop(),
    ok.

eui_lookup_test() ->
    ok = init(),
    Route1 = hpr_route:new(#{
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A},
            #{start_addr => 16#00000010, end_addr => 16#0000001A}
        ],
        euis => [#{app_eui => 1, dev_eui => 2}, #{app_eui => 3, dev_eui => 4}],
        oui => 1,
        protocol => {http_roaming, #{ip => <<"lns1.testdomain.com">>, port => 80}}
    }),
    Route2 = hpr_route:new(#{
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A},
            #{start_addr => 16#00000010, end_addr => 16#0000001A}
        ],
        euis => [#{app_eui => 1, dev_eui => 0}, #{app_eui => 5, dev_eui => 6}],
        oui => 1,
        protocol => {http_roaming, #{ip => <<"lns2.testdomain.com">>, port => 80}}
    }),

    ok = insert_route(Route1),
    ok = insert_route(Route2),

    ?assertEqual([Route1], lookup_eui(3, 4)),
    ?assertEqual([Route2], lookup_eui(5, 6)),
    ?assertEqual(lists:sort([Route1, Route2]), lists:sort(lookup_eui(1, 2))),
    ?assertEqual([Route2], lookup_eui(1, 0)),

    ok = stop(),
    ok.

-endif.
