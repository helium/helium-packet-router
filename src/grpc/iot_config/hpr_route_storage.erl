-module(hpr_route_storage).

-export([
    init_ets/0,
    checkpoint/0,

    foldl/2,
    insert/1, insert/2, insert/3,
    delete/1,
    lookup/1,
    set_backoff/2,

    all_routes/0,
    all_route_ets/0,
    oui_routes/1,
    oui_routes_ets/1,

    delete_all/0
]).

-ifdef(TEST).
-export([test_delete_ets/0, test_size/0]).
-endif.

-define(ETS, hpr_routes_ets).
-define(DETS, hpr_routes_dets).

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [
        public,
        named_table,
        set,
        {keypos, hpr_route_ets:ets_keypos()},
        {read_concurrency, true}
    ]),
    with_open_dets(fun() ->
        [] = dets:traverse(
            ?DETS,
            fun(RouteETS) ->
                Route = hpr_route_ets:route(RouteETS),
                ok = ?MODULE:insert(Route),
                continue
            end
        )
    end),

    ok.

-spec checkpoint() -> ok.
checkpoint() ->
    with_open_dets(fun() ->
        ok = dets:from_ets(?DETS, ?ETS)
    end).

-spec lookup(ID :: hpr_route:id()) -> {ok, hpr_route_ets:route()} | {error, not_found}.
lookup(ID) ->
    case ets:lookup(?ETS, ID) of
        [Route] ->
            {ok, Route};
        _Other ->
            {error, not_found}
    end.

-spec foldl(Fun :: function(), Acc :: any()) -> any().
foldl(Fun, Acc) ->
    ets:foldl(Fun, Acc, ?ETS).

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
    true = ets:insert(?ETS, RouteETS),
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

    true = ets:delete(?ETS, RouteID),
    lager:info(
        [{devaddr, DevAddrEntries}, {euis, EUIsEntries}, {skfs, SKFEntries}, {route_id, RouteID}],
        "route deleted"
    ),
    ok.

-spec delete_all() -> ok.
delete_all() ->
    ets:delete_all_objects(?ETS),
    ok.

-spec set_backoff(RouteID :: hpr_route:id(), Backoff :: hpr_route_ets:backoff()) -> ok.
set_backoff(RouteID, Backoff) ->
    true = ets:update_element(?ETS, RouteID, {5, Backoff}),
    ok.

-ifdef(TEST).

-spec test_delete_ets() -> ok.
test_delete_ets() ->
    ets:delete(?ETS),
    ok.

-spec test_size() -> non_neg_integer().
test_size() ->
    ets:info(?ETS, size).

-endif.

%% ------------------------------------------------------------------
%% CLI Functions
%% ------------------------------------------------------------------

-spec all_routes() -> list(hpr_route:route()).
all_routes() ->
    [hpr_route_ets:route(RouteETS) || RouteETS <- ets:tab2list(?ETS)].

-spec all_route_ets() -> list(hpr_route_ets:route()).
all_route_ets() ->
    ets:tab2list(?ETS).

-spec oui_routes(OUI :: non_neg_integer()) -> list(hpr_route:route()).
oui_routes(OUI) ->
    [
        hpr_route_ets:route(RouteETS)
     || RouteETS <- ets:tab2list(?ETS), OUI == hpr_route:oui(hpr_route_ets:route(RouteETS))
    ].

-spec oui_routes_ets(OUI :: non_neg_integer()) -> list(hpr_route_ets:route()).
oui_routes_ets(OUI) ->
    [
        RouteETS
     || RouteETS <- ets:tab2list(?ETS), OUI == hpr_route:oui(hpr_route_ets:route(RouteETS))
    ].

%% -------------------------------------------------------------------
%% Internal Functions
%% -------------------------------------------------------------------

with_open_dets(FN) ->
    DataDir = hpr_utils:base_data_dir(),
    DETSFile = filename:join([DataDir, "hpr_routes_storage.dets"]),
    ok = filelib:ensure_dir(DETSFile),

    case
        dets:open_file(?DETS, [
            {file, DETSFile}, {type, set}, {keypos, hpr_route_ets:ets_keypos()}
        ])
    of
        {ok, _Dets} ->
            lager:info("~s opened by ~p", [DETSFile, self()]),
            FN(),
            dets:close(?DETS);
        %% ok;
        {error, Reason} ->
            Deleted = file:delete(DETSFile),
            lager:warning("failed to open dets file ~p: ~p, deleted: ~p", [?MODULE, Reason, Deleted]),
            with_open_dets(FN)
    end.
