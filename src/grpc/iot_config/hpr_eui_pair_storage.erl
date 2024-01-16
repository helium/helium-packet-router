-module(hpr_eui_pair_storage).

-export([
    init_ets/0,
    checkpoint/0,

    insert/1,
    lookup/2,
    delete/1,

    delete_route/1,
    replace_route/2,

    lookup_dev_eui/1,
    lookup_app_eui/1,
    lookup_for_route/1,
    count_for_route/1,

    delete_all/0
]).

-ifdef(TEST).
-export([test_delete_ets/0, test_size/0, test_tab_name/0]).
-endif.

-define(ETS, hpr_route_eui_pairs_ets).
-define(DETS, hpr_route_eui_pairs_dets).

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [
        public,
        named_table,
        bag,
        {read_concurrency, true}
    ]),
    ok = rehydrate_from_dets(),

    ok.

-spec checkpoint() -> ok.
checkpoint() ->
    with_open_dets(fun() ->
        ok = dets:from_ets(?DETS, ?ETS)
    end).

-spec lookup(AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()) ->
    [hpr_route_ets:route()].
lookup(AppEUI, 0) ->
    EUIPairs = ets:lookup(?ETS, {AppEUI, 0}),
    lists:flatten([
        Route
     || {_, RouteID} <- EUIPairs,
        {ok, Route} <- [hpr_route_storage:lookup(RouteID)]
    ]);
lookup(AppEUI, DevEUI) ->
    EUIPairs = ets:lookup(?ETS, {AppEUI, DevEUI}),
    lists:usort(
        lists:flatten([
            Route
         || {_, RouteID} <- EUIPairs,
            {ok, Route} <- [hpr_route_storage:lookup(RouteID)]
        ]) ++ lookup(AppEUI, 0)
    ).

-spec insert(EUIPair :: hpr_eui_pair:eui_pair()) -> ok.
insert(EUIPair) ->
    true = ets:insert(?ETS, [
        {
            {hpr_eui_pair:app_eui(EUIPair), hpr_eui_pair:dev_eui(EUIPair)},
            hpr_eui_pair:route_id(EUIPair)
        }
    ]),
    lager:debug(
        [
            {app_eui, hpr_utils:int_to_hex_string(hpr_eui_pair:app_eui(EUIPair))},
            {dev_eui, hpr_utils:int_to_hex_string(hpr_eui_pair:dev_eui(EUIPair))},
            {route_id, hpr_eui_pair:route_id(EUIPair)}
        ],
        "inserted eui pair"
    ),
    ok.

-spec delete(EUIPair :: hpr_eui_pair:eui_pair()) -> ok.
delete(EUIPair) ->
    true = ets:delete_object(?ETS, {
        {hpr_eui_pair:app_eui(EUIPair), hpr_eui_pair:dev_eui(EUIPair)},
        hpr_eui_pair:route_id(EUIPair)
    }),
    lager:debug(
        [
            {app_eui, hpr_utils:int_to_hex_string(hpr_eui_pair:app_eui(EUIPair))},
            {dev_eui, hpr_utils:int_to_hex_string(hpr_eui_pair:dev_eui(EUIPair))},
            {route_id, hpr_eui_pair:route_id(EUIPair)}
        ],
        "deleted eui pair"
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

-spec lookup_dev_eui(DevEUI :: non_neg_integer()) ->
    list({AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()}).
lookup_dev_eui(DevEUI) ->
    MS = [{{{'$1', DevEUI}, '_'}, [], [{{'$1', DevEUI}}]}],
    ets:select(?ETS, MS).

-spec lookup_app_eui(AppEUI :: non_neg_integer()) ->
    list({AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()}).
lookup_app_eui(AppEUI) ->
    MS = [{{{AppEUI, '$1'}, '_'}, [], [{{AppEUI, '$1'}}]}],
    ets:select(?ETS, MS).

-spec lookup_for_route(RouteID :: hpr_route:id()) ->
    list({AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()}).
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
    MS2 = [{{'_', RouteID}, [], [true]}],
    ets:select_delete(?ETS, MS2).

-spec replace_route(RouteID :: hpr_route:id(), EUIs :: list(hpr_eui_pair:eui_pair())) ->
    non_neg_integer().
replace_route(RouteID, EUIs) ->
    Removed = ?MODULE:delete_route(RouteID),
    lists:foreach(fun ?MODULE:insert/1, EUIs),
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

with_open_dets(FN) ->
    DataDir = hpr_utils:base_data_dir(),
    DETSFile = filename:join([DataDir, "hpr_eui_pair_storage.dets"]),
    ok = filelib:ensure_dir(DETSFile),

    case dets:open_file(?DETS, [{file, DETSFile}, {type, set}]) of
        {ok, _Dets} ->
            lager:info("~s opened by ~p", [DETSFile, self()]),
            FN(),
            dets:close(?DETS);
        {error, Reason} ->
            Deleted = file:delete(DETSFile),
            lager:warning("failed to open dets file ~p: ~p, deleted: ~p", [?MODULE, Reason, Deleted]),
            with_open_dets(FN)
    end.
