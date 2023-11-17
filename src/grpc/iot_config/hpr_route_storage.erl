-module(hpr_route_storage).

-export([
    init_ets/0,

    insert/1, insert/2, insert/3,
    delete/1,
    lookup/1,
    set_backoff/2,

    all_routes/0,
    all_route_ets/0,
    oui_routes/1,

    delete_all/0
]).

-ifdef(TEST).
-export([test_delete_ets/0, test_size/0]).
-endif.

-define(ETS_ROUTES, hpr_routes_ets).

-spec init_ets() -> ok.
init_ets() ->
    ?ETS_ROUTES = ets:new(?ETS_ROUTES, [
        public,
        named_table,
        set,
        {keypos, hpr_route_ets:ets_keypos()},
        {read_concurrency, true}
    ]),
    ok.

-spec lookup(ID :: hpr_route:id()) -> {ok, hpr_route_ets:route()} | {error, not_found}.
lookup(ID) ->
    case ets:lookup(?ETS_ROUTES, ID) of
        [Route] ->
            {ok, Route};
        _Other ->
            {error, not_found}
    end.

-spec insert(Route :: hpr_route:route()) -> ok.
insert(Route) ->
    RouteID = hpr_route:id(Route),
    SKFETS =
        case ?MODULE:lookup(RouteID) of
            {ok, ExistingRoute} ->
                hpr_route_ets:skf_ets(ExistingRoute);
            _Other ->
                hpr_skf_storage:make_ets(RouteID)
        end,
    ?MODULE:insert(Route, SKFETS).

-spec insert(Route :: hpr_route:route(), SKFETS :: ets:table()) -> ok.
insert(Route, SKFETS) ->
    ?MODULE:insert(Route, SKFETS, undefined).

-spec insert(
    Route :: hpr_route:route(),
    SKFETS :: ets:table(),
    Backoff :: hpr_route_ets:backoff()
) -> ok.
insert(Route, SKFETS, Backoff) ->
    RouteETS = hpr_route_ets:new(Route, SKFETS, Backoff),
    true = ets:insert(?ETS_ROUTES, RouteETS),
    Server = hpr_route:server(Route),
    RouteFields = [
        {id, hpr_route:id(Route)},
        {net_id, hpr_utils:net_id_display(hpr_route:net_id(Route))},
        {oui, hpr_route:oui(Route)},
        {protocol, hpr_route:protocol_type(Server)},
        {max_copies, hpr_route:max_copies(Route)},
        {active, hpr_route:active(Route)},
        {locked, hpr_route:locked(Route)},
        {ignore_empty_skf, hpr_route:ignore_empty_skf(Route)},
        {skf_ets, SKFETS},
        {backoff, Backoff}
    ],
    lager:info(RouteFields, "inserting route"),
    ok.

-spec delete(Route :: hpr_route:route()) -> ok.
delete(Route) ->
    RouteID = hpr_route:id(Route),
    DevAddrEntries = hpr_devaddr_range_storage:delete_route(RouteID),
    EUIsEntries = hpr_eui_pair_storage:delete_route(RouteID),
    SKFEntries = hpr_skf_storage:delete_route(RouteID),

    true = ets:delete(?ETS_ROUTES, RouteID),
    lager:info(
        [{devaddr, DevAddrEntries}, {euis, EUIsEntries}, {skfs, SKFEntries}, {route_id, RouteID}],
        "route deleted"
    ),
    ok.

-spec delete_all() -> ok.
delete_all() ->
    ets:delete_all_objects(?ETS_ROUTES),
    ok.

-spec set_backoff(RouteID :: hpr_route:id(), Backoff :: hpr_route_ets:backoff()) -> ok.
set_backoff(RouteID, Backoff) ->
    true = ets:update_element(?ETS_ROUTES, RouteID, {5, Backoff}),
    ok.

-ifdef(TEST).

-spec test_delete_ets() -> ok.
test_delete_ets() ->
    ets:delete(?ETS_ROUTES),
    ok.

-spec test_size() -> non_neg_integer().
test_size() ->
    ets:info(?ETS_ROUTES, size).

-endif.

%% ------------------------------------------------------------------
%% CLI Functions
%% ------------------------------------------------------------------

-spec all_routes() -> list(hpr_route:route()).
all_routes() ->
    [hpr_route_ets:route(R) || R <- ets:tab2list(?ETS_ROUTES)].

-spec all_route_ets() -> list(hpr_route_ets:route()).
all_route_ets() ->
    ets:tab2list(?ETS_ROUTES).

-spec oui_routes(OUI :: non_neg_integer()) -> list(hpr_route_ets:route()).
oui_routes(OUI) ->
    [
        RouteETS
     || RouteETS <- ets:tab2list(?ETS_ROUTES), OUI == hpr_route:oui(hpr_route_ets:route(RouteETS))
    ].

%% ------------------------------------------------------------------
%% CLI Functions
%% ------------------------------------------------------------------

-spec all_routes() -> list(hpr_route:route()).
all_routes() ->
    [hpr_route_ets:route(R) || R <- ets:tab2list(?ETS_ROUTES)].

-spec all_route_ets() -> list(route()).
all_route_ets() ->
    ets:tab2list(?ETS_ROUTES).

-spec oui_routes(OUI :: non_neg_integer()) -> list(route()).
oui_routes(OUI) ->
    [
        RouteETS
     || RouteETS <- ets:tab2list(?ETS_ROUTES), OUI == hpr_route:oui(hpr_route_ets:route(RouteETS))
    ].

%% -------------------------------------------------------------------
%% Internal Functions
%% -------------------------------------------------------------------
