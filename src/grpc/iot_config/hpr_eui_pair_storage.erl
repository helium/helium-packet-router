-module(hpr_eui_pair_storage).

-export([
    delete_route/1,

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

%% -------------------------------------------------------------------
%% Route Stream Helpers
%% -------------------------------------------------------------------

-spec delete_route(hpr_route:id()) -> non_neg_integer().
delete_route(RouteID) ->
    MS2 = [{{'_', RouteID}, [], [true]}],
    ets:select_delete(?ETS_EUI_PAIRS, MS2).
