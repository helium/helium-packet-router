-module(hpr_config).

-export([
    init/0,
    update_routes/1,
    insert_route/1,
    lookup_devaddr/1,
    lookup_eui/2
]).

-ifdef(TEST).

-export([
    remove_euis_dev_ranges/1
]).

-endif.

-define(DEVADDRS_ETS, hpr_config_routes_by_devaddr).
-define(EUIS_ETS, hpr_config_routes_by_eui).

-spec init() -> ok.
init() ->
    ?DEVADDRS_ETS = ets:new(?DEVADDRS_ETS, [public, named_table, bag, {read_concurrency, true}]),
    ?EUIS_ETS = ets:new(?EUIS_ETS, [public, named_table, bag, {read_concurrency, true}]),
    ok.

-spec update_routes(client_config_pb:routes_res_v1_pb()) -> ok.
update_routes(#{routes := []}) ->
    case application:get_env(hpr, hpr_config_empty_routes_delete_all, false) of
        true ->
            lager:info("applying empty routes update"),
            true = ets:delete_all_objects(?DEVADDRS_ETS),
            true = ets:delete_all_objects(?EUIS_ETS);
        false ->
            lager:info("ignoring empty routes update"),
            ok
    end;
update_routes(#{routes := Routes}) ->
    lager:info("got update  with ~w routes", [erlang:length(Routes)]),
    true = ets:delete_all_objects(?DEVADDRS_ETS),
    true = ets:delete_all_objects(?EUIS_ETS),
    lists:foreach(
        fun(RouteConfigMap) ->
            Route = hpr_route:new(RouteConfigMap),
            ok = insert_route(Route)
        end,
        Routes
    ).

-spec insert_route(Route :: hpr_route:route()) -> ok.
insert_route(Route) ->
    true = ets:insert(?DEVADDRS_ETS, route_to_devaddr_rows(Route)),
    true = ets:insert(?EUIS_ETS, route_to_eui_rows(Route)),
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
% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {setup, fun setup/0,
        {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
            ?_test(test_route_to_devaddr_rows()),
            ?_test(test_route_to_eui_rows()),
            ?_test(test_route_insert()),
            ?_test(test_devaddr_lookup()),
            ?_test(test_eui_lookup())
        ]}}.

setup() ->
    ok.

foreach_setup() ->
    init(),
    ok.

foreach_cleanup(ok) ->
    true = ets:delete(?DEVADDRS_ETS),
    true = ets:delete(?EUIS_ETS),
    ok.

test_route_to_devaddr_rows() ->
    Route = route_v1(),
    CleanedRoute = remove_euis_dev_ranges(Route),
    ?assertEqual(
        [
            {{0, 16#00000001, 16#0000000A}, CleanedRoute},
            {{0, 16#00000010, 16#0000001A}, CleanedRoute}
        ],
        route_to_devaddr_rows(Route)
    ).

test_route_to_eui_rows() ->
    Route = route_v1(),
    CleanedRoute = remove_euis_dev_ranges(Route),
    ?assertEqual([{{1, 2}, CleanedRoute}, {{3, 4}, CleanedRoute}], route_to_eui_rows(Route)).

test_route_insert() ->
    Route = route_v1(),
    ok = insert_route(Route),

    ExpectedDevaddrRows = lists:sort(route_to_devaddr_rows(Route)),
    ExpectedEUIRows = lists:sort(route_to_eui_rows(Route)),

    GotDevaddrRows = lists:sort(ets:tab2list(?DEVADDRS_ETS)),
    GotEUIRows = lists:sort(ets:tab2list(?EUIS_ETS)),

    ?assertEqual(ExpectedDevaddrRows, [{K, remove_euis_dev_ranges(R)} || {K, R} <- GotDevaddrRows]),
    ?assertEqual(ExpectedEUIRows, [{K, remove_euis_dev_ranges(R)} || {K, R} <- GotEUIRows]),
    ok.

test_devaddr_lookup() ->
    Route = route_v1(),
    CleanedRoute = remove_euis_dev_ranges(Route),
    ok = insert_route(Route),

    ?assertEqual([CleanedRoute], lookup_devaddr(16#00000005)),
    ?assertEqual([], lookup_devaddr(16#0000000B)),
    ?assertEqual([], lookup_devaddr(16#00000000)),
    ok.

test_eui_lookup() ->
    Route1 = hpr_route:new(#{
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
        }
    }),

    Route2 = hpr_route:new(#{
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
        }
    }),

    ok = insert_route(Route1),
    ok = insert_route(Route2),
    CleanedRoute1 = remove_euis_dev_ranges(Route1),
    CleanedRoute2 = remove_euis_dev_ranges(Route2),

    ?assertEqual([CleanedRoute1], lookup_eui(3, 4)),
    ?assertEqual([CleanedRoute2], lookup_eui(5, 6)),
    ?assertEqual(lists:sort([CleanedRoute1, CleanedRoute2]), lists:sort(lookup_eui(1, 2))),
    ?assertEqual([CleanedRoute2], lookup_eui(1, 0)),

    ok.

route_v1() ->
    hpr_route:new(#{
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
        }
    }).

-endif.
