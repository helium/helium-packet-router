-module(hpr_eui_pair_storage).

-export([
    delete_route/1,
    replace_route/2,

    insert/1,
    lookup/2
]).

-define(ETS_EUI_PAIRS, hpr_route_eui_pairs_ets).

-spec lookup(AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()) ->
    [hpr_route_ets:route()].
lookup(AppEUI, 0) ->
    EUIPairs = ets:lookup(?ETS_EUI_PAIRS, {AppEUI, 0}),
    lists:flatten([
        Route
     || {_, RouteID} <- EUIPairs,
        {ok, Route} <- [hpr_route_storage:lookup(RouteID)]
    ]);
lookup(AppEUI, DevEUI) ->
    EUIPairs = ets:lookup(?ETS_EUI_PAIRS, {AppEUI, DevEUI}),
    lists:usort(
        lists:flatten([
            Route
         || {_, RouteID} <- EUIPairs,
            {ok, Route} <- [hpr_route_storage:lookup(RouteID)]
        ]) ++ lookup(AppEUI, 0)
    ).

-spec insert(EUIPair :: hpr_eui_pair:eui_pair()) -> ok.
insert(EUIPair) ->
    true = ets:insert(?ETS_EUI_PAIRS, [
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

%% -------------------------------------------------------------------
%% Route Stream Helpers
%% -------------------------------------------------------------------

-spec delete_route(hpr_route:id()) -> non_neg_integer().
delete_route(RouteID) ->
    MS2 = [{{'_', RouteID}, [], [true]}],
    ets:select_delete(?ETS_EUI_PAIRS, MS2).

-spec replace_route(RouteID :: hpr_route:id(), EUIs :: list(hpr_eui_pair:eui_pair())) ->
    non_neg_integer().
replace_route(RouteID, EUIs) ->
    Removed = ?MODULE:delete_route(RouteID),
    lists:foreach(fun ?MODULE:insert/1, EUIs),
    Removed.
