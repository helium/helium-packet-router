-module(hpr_devaddr_range_storage).

-export([
    init_ets/0,
         checkpoint/0,

    lookup/1,
    insert/1,
    delete/1,

    delete_route/1,
    replace_route/2,

    lookup_for_route/1,
    count_for_route/1,

    delete_all/0
]).

-ifdef(TEST).
-export([test_delete_ets/0, test_size/0, test_tab_name/0]).
-endif.

-define(ETS_DEVADDR_RANGES, hpr_route_devaddr_ranges_ets).
-define(DETS_DEVADDR_RANGES, hpr_route_devaddr_ranges_dets).

-spec init_ets() -> ok.
init_ets() ->
    ?ETS_DEVADDR_RANGES = ets:new(?ETS_DEVADDR_RANGES, [
        public, named_table, bag, {read_concurrency, true}
    ]),
    ok = rehydrate_from_dets(),
    ok.

-spec checkpoint() -> ok.
checkpoint() ->
    ok = open_dets(),
    ok = dets:from_ets(?DETS_DEVADDR_RANGES, ?ETS_DEVADDR_RANGES),
    ok = dets:close(?DETS_DEVADDR_RANGES),
    ok.

-spec lookup(DevAddr :: non_neg_integer()) -> [hpr_route_ets:route()].
lookup(DevAddr) ->
    MS = [
        {
            {{'$1', '$2'}, '$3'},
            [
                {'andalso', {'=<', '$1', DevAddr}, {'=<', DevAddr, '$2'}}
            ],
            ['$3']
        }
    ],
    RouteIDs = ets:select(?ETS_DEVADDR_RANGES, MS),

    lists:usort(
        lists:flatten([
            Route
         || RouteID <- RouteIDs,
            {ok, Route} <- [hpr_route_storage:lookup(RouteID)]
        ])
    ).

-spec insert(DevAddrRange :: hpr_devaddr_range:devaddr_range()) -> ok.
insert(DevAddrRange) ->
    true = ets:insert(?ETS_DEVADDR_RANGES, [
        {
            {hpr_devaddr_range:start_addr(DevAddrRange), hpr_devaddr_range:end_addr(DevAddrRange)},
            hpr_devaddr_range:route_id(DevAddrRange)
        }
    ]),
    lager:debug(
        [
            {start_addr, hpr_utils:int_to_hex_string(hpr_devaddr_range:start_addr(DevAddrRange))},
            {end_addr, hpr_utils:int_to_hex_string(hpr_devaddr_range:end_addr(DevAddrRange))},
            {route_id, hpr_devaddr_range:route_id(DevAddrRange)}
        ],
        "inserted devaddr range"
    ),
    ok.

-spec delete(DevAddrRange :: hpr_devaddr_range:devaddr_range()) -> ok.
delete(DevAddrRange) ->
    true = ets:delete_object(?ETS_DEVADDR_RANGES, {
        {hpr_devaddr_range:start_addr(DevAddrRange), hpr_devaddr_range:end_addr(DevAddrRange)},
        hpr_devaddr_range:route_id(DevAddrRange)
    }),
    lager:debug(
        [
            {start_addr, hpr_utils:int_to_hex_string(hpr_devaddr_range:start_addr(DevAddrRange))},
            {end_addr, hpr_utils:int_to_hex_string(hpr_devaddr_range:end_addr(DevAddrRange))},
            {route_id, hpr_devaddr_range:route_id(DevAddrRange)}
        ],
        "deleted devaddr range"
    ),
    ok.

-spec delete_all() -> ok.
delete_all() ->
    ets:delete_all_objects(?ETS_DEVADDR_RANGES),
    ok.

-ifdef(TEST).

-spec test_delete_ets() -> ok.
test_delete_ets() ->
    ets:delete(?ETS_DEVADDR_RANGES),
    ok.

-spec test_size() -> non_neg_integer().
test_size() ->
    ets:info(?ETS_DEVADDR_RANGES, size).

-spec test_tab_name() -> atom().
test_tab_name() ->
    ?ETS_DEVADDR_RANGES.

-endif.

%% ------------------------------------------------------------------
%% CLI Functions
%% ------------------------------------------------------------------

-spec lookup_for_route(RouteID :: hpr_route:id()) ->
    list({non_neg_integer(), non_neg_integer()}).
lookup_for_route(RouteID) ->
    MS = [{{{'$1', '$2'}, RouteID}, [], [{{'$1', '$2'}}]}],
    ets:select(?ETS_DEVADDR_RANGES, MS).

-spec count_for_route(RouteID :: hpr_route:id()) -> non_neg_integer().
count_for_route(RouteID) ->
    MS = [{{'_', RouteID}, [], [true]}],
    ets:select_count(?ETS_DEVADDR_RANGES, MS).

%% -------------------------------------------------------------------
%% Route Stream Helpers
%% -------------------------------------------------------------------

-spec delete_route(hpr_route:id()) -> non_neg_integer().
delete_route(RouteID) ->
    MS1 = [{{'_', RouteID}, [], [true]}],
    ets:select_delete(?ETS_DEVADDR_RANGES, MS1).

-spec replace_route(
    RouteID :: hpr_route:id(),
    DevAddrRanges :: list(hpr_devaddr_range:devaddr_range())
) -> non_neg_integer().
replace_route(RouteID, DevAddrRanges) ->
    Removed = hpr_devaddr_range_storage:delete_route(RouteID),
    lists:foreach(fun ?MODULE:insert/1, DevAddrRanges),
    Removed.

-spec rehydrate_from_dets() -> ok.
rehydrate_from_dets() ->
    ok = open_dets(),

    case dets:to_ets(?DETS_DEVADDR_RANGES, ?ETS_DEVADDR_RANGES) of
        {error, _Reason} ->
            lager:error("failed ot hydrate ets: ~p", [_Reason]);
        _ ->
            lager:info("ets hydrated")
    end.

-spec open_dets() -> ok.
open_dets() ->
    DataDir = hpr_utils:base_data_dir(),
    DETSFile = filename:join([DataDir, "hpr_eui_pair_storage.dets"]),
    ok = filelib:ensure_dir(DETSFile),

    case
        dets:open_file(?DETS_DEVADDR_RANGES, [
            {file, DETSFile}, {type, bag}, {keypos, hpr_route_ets:ets_keypos()}
        ])
    of
        {ok, _Dets} ->
            ok;
        {error, Reason} ->
            Deleted = file:delete(DETSFile),
            lager:warning("failed to open dets file ~p: ~p, deleted: ~p", [?MODULE, Reason, Deleted]),
            rehydrate_from_dets()
    end.
