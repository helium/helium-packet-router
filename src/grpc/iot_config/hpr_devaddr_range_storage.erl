-module(hpr_devaddr_range_storage).

-export([
    delete_route/1,

    lookup/1
]).

-define(ETS_DEVADDR_RANGES, hpr_route_devaddr_ranges_ets).

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

%% -------------------------------------------------------------------
%% Route Stream Helpers
%% -------------------------------------------------------------------

-spec delete_route(hpr_route:id()) -> non_neg_integer().
delete_route(RouteID) ->
    MS1 = [{{'_', RouteID}, [], [true]}],
    ets:select_delete(?ETS_DEVADDR_RANGES, MS1).
