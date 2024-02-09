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

-define(ETS, hpr_route_devaddr_ranges_ets).
-define(DETS, hpr_route_devaddr_ranges_dets).

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [
        public, named_table, bag, {read_concurrency, true}
    ]),
    ok = rehydrate_from_dets(),
    ok.

-spec checkpoint() -> ok.
checkpoint() ->
    with_open_dets(fun() ->
        ok = dets:from_ets(?DETS, ?ETS)
    end).

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
    RouteIDs = ets:select(?ETS, MS),

    lists:usort(
        lists:flatten([
            Route
         || RouteID <- RouteIDs,
            {ok, Route} <- [hpr_route_storage:lookup(RouteID)]
        ])
    ).

-spec insert(DevAddrRange :: hpr_devaddr_range:devaddr_range()) -> ok.
insert(DevAddrRange) ->
    true = ets:insert(?ETS, [
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
    true = ets:delete_object(?ETS, {
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
    ets:delete_all_objects(?ETS),
    ok.

-ifdef(TEST).

-spec test_delete_ets() -> ok.
test_delete_ets() ->
    ets:delete(?ETS),
    ok.

-spec test_size() -> non_neg_integer().
test_size() ->
    ets:info(?ETS, size).

-spec test_tab_name() -> atom().
test_tab_name() ->
    ?ETS.

-endif.

%% ------------------------------------------------------------------
%% CLI Functions
%% ------------------------------------------------------------------

-spec lookup_for_route(RouteID :: hpr_route:id()) ->
    list({non_neg_integer(), non_neg_integer()}).
lookup_for_route(RouteID) ->
    MS = [{{{'$1', '$2'}, RouteID}, [], [{{'$1', '$2'}}]}],
    ets:select(?ETS, MS).

-spec count_for_route(RouteID :: hpr_route:id()) -> non_neg_integer().
count_for_route(RouteID) ->
    MS = [{{'_', RouteID}, [], [true]}],
    ets:select_count(?ETS, MS).

%% -------------------------------------------------------------------
%% Route Stream Helpers
%% -------------------------------------------------------------------

-spec delete_route(hpr_route:id()) -> non_neg_integer().
delete_route(RouteID) ->
    MS1 = [{{'_', RouteID}, [], [true]}],
    ets:select_delete(?ETS, MS1).

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
    with_open_dets(fun() ->
        case dets:to_ets(?DETS, ?ETS) of
            {error, _Reason} ->
                lager:error("failed ot hydrate ets: ~p", [_Reason]);
            _ ->
                lager:info("ets hydrated")
        end
    end).

-spec with_open_dets(FN :: fun()) -> ok.
with_open_dets(FN) ->
    DataDir = hpr_utils:base_data_dir(),
    DETSFile = filename:join([DataDir, "hpr_devaddr_range_storage.dets"]),
    ok = filelib:ensure_dir(DETSFile),

    case dets:open_file(?DETS, [{file, DETSFile}, {type, bag}]) of
        {ok, _Dets} ->
            FN(),
            dets:close(?DETS);
        {error, Reason} ->
            Deleted = file:delete(DETSFile),
            lager:warning("failed to open dets file ~p: ~p, deleted: ~p", [?MODULE, Reason, Deleted]),
            with_open_dets(FN)
    end.
