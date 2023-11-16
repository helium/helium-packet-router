-module(hpr_route_storage).

-export([
    init/0,

    insert/1, insert/2, insert/3,
    delete/1,
    lookup/1
]).

-define(ETS_ROUTES, hpr_routes_ets).

-record(hpr_route_ets, {
    id :: hpr_route:id(),
    route :: hpr_route:route(),
    skf_ets :: ets:tid(),
    backoff :: backoff()
}).

-type backoff() :: undefined | {non_neg_integer(), backoff:backoff()}.
-type route() :: #hpr_route_ets{}.

init() ->
    ok.

-spec insert(Route :: hpr_route:route()) -> ok.
insert(Route) ->
    RouteID = hpr_route:id(Route),
    SKFETS =
        case ?MODULE:lookup(RouteID) of
            [#hpr_route_ets{skf_ets = ETS}] ->
                ETS;
            _Other ->
                hpr_skf_storage:make_ets(RouteID)
        end,
    ?MODULE:insert(Route, SKFETS).

-spec insert(Route :: hpr_route:route(), SKFETS :: ets:table()) -> ok.
insert(Route, SKFETS) ->
    ?MODULE:insert(Route, SKFETS, undefined).

-spec insert(Route :: hpr_route:route(), SKFETS :: ets:table(), Backoff :: backoff()) -> ok.
insert(Route, SKFETS, Backoff) ->
    RouteID = hpr_route:id(Route),
    RouteETS = #hpr_route_ets{
        id = RouteID,
        route = Route,
        skf_ets = SKFETS,
        backoff = Backoff
    },
    true = ets:insert(?ETS_ROUTES, RouteETS),
    Server = hpr_route:server(Route),
    RouteFields = [
        {id, RouteID},
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

-spec lookup(ID :: hpr_route:id()) -> {ok, route()} | {error, not_found}.
lookup(ID) ->
    case ets:lookup(?ETS_ROUTES, ID) of
        [#hpr_route_ets{} = Route] ->
            {ok, Route};
        _Other ->
            {error, not_found}
    end.

%% -------------------------------------------------------------------
%% Internal Functions
%% -------------------------------------------------------------------
