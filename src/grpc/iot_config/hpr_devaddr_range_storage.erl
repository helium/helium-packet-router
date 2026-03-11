-module(hpr_devaddr_range_storage).

-export([
    init_ets/0,
    checkpoint/0,

    foldl/2,
    lookup/1,
    insert/1,
    delete/1,

    delete_route/1,
    replace_route/2,

    lookup_for_route/1,
    count_for_route/1,

    delete_all/0,

    clear_cache/0,
    cache_size/0
]).

-ifdef(TEST).
-export([test_delete_ets/0, test_size/0, test_tab_name/0, test_cache_size/0, test_clear_cache/0]).
-endif.

-define(ETS, hpr_route_devaddr_ranges_ets).
-define(DETS, hpr_route_devaddr_ranges_dets).
-define(CACHE_ETS, hpr_devaddr_cache_ets).
% 12 hours
-define(DEFAULT_CACHE_TTL_MS, 43200000).

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [
        public, named_table, bag, {read_concurrency, true}
    ]),
    ?CACHE_ETS = ets:new(?CACHE_ETS, [
        public, named_table, set, {read_concurrency, true}
    ]),
    ok = rehydrate_from_dets(),
    ok.

-spec checkpoint() -> ok.
checkpoint() ->
    with_open_dets(fun() ->
        ok = dets:from_ets(?DETS, ?ETS)
    end).

-spec foldl(Fun :: function(), Acc :: any()) -> any().
foldl(Fun, Acc) ->
    ets:foldl(Fun, Acc, ?ETS).

-spec lookup(DevAddr :: non_neg_integer()) -> [hpr_route_ets:route()].
lookup(DevAddr) ->
    case ets:lookup(?CACHE_ETS, DevAddr) of
        [{DevAddr, {RouteIDs, CachedAt}}] ->
            Now = erlang:system_time(millisecond),
            TTL = hpr_utils:get_env_int(devaddr_cache_ttl_ms, ?DEFAULT_CACHE_TTL_MS),
            case (Now - CachedAt) < TTL of
                true ->
                    %% Cache hit - fetch routes from storage
                    catch_metrics(fun hpr_metrics:devaddr_cache_hit/0),
                    [Route
                     || RouteID <- lists:usort(RouteIDs),
                        {ok, Route} <- [hpr_route_storage:lookup(RouteID)]];
                false ->
                    %% Cache expired
                    catch_metrics(fun hpr_metrics:devaddr_cache_miss/0),
                    lookup_and_cache(DevAddr)
            end;
        [] ->
            %% Cache miss
            catch_metrics(fun hpr_metrics:devaddr_cache_miss/0),
            lookup_and_cache(DevAddr)
    end.

-spec lookup_and_cache(DevAddr :: non_neg_integer()) -> [hpr_route_ets:route()].
lookup_and_cache(DevAddr) ->
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

    %% Cache the RouteIDs
    Now = erlang:system_time(millisecond),
    true = ets:insert(?CACHE_ETS, {DevAddr, {RouteIDs, Now}}),

    %% Return the full routes (dedup RouteIDs first to avoid redundant lookups)
    [Route || RouteID <- lists:usort(RouteIDs),
              {ok, Route} <- [hpr_route_storage:lookup(RouteID)]].

-spec insert(DevAddrRange :: hpr_devaddr_range:devaddr_range()) -> ok.
insert(DevAddrRange) ->
    true = ets:insert(?ETS, [
        {
            {hpr_devaddr_range:start_addr(DevAddrRange), hpr_devaddr_range:end_addr(DevAddrRange)},
            hpr_devaddr_range:route_id(DevAddrRange)
        }
    ]),
    %% Invalidate cache entries in the range being inserted (handles empty cached results)
    ok = invalidate_cache_for_range(
        hpr_devaddr_range:start_addr(DevAddrRange),
        hpr_devaddr_range:end_addr(DevAddrRange)
    ),
    %% Also invalidate all cache entries containing this route (handles existing cached results elsewhere)
    ok = invalidate_cache_for_route(hpr_devaddr_range:route_id(DevAddrRange)),
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
    %% Invalidate cache entries in the range being deleted (handles empty cached results)
    ok = invalidate_cache_for_range(
        hpr_devaddr_range:start_addr(DevAddrRange),
        hpr_devaddr_range:end_addr(DevAddrRange)
    ),
    %% Also invalidate all cache entries containing this route (handles existing cached results elsewhere)
    ok = invalidate_cache_for_route(hpr_devaddr_range:route_id(DevAddrRange)),
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

-include_lib("eunit/include/eunit.hrl").

-spec test_delete_ets() -> ok.
test_delete_ets() ->
    ets:delete(?ETS),
    ets:delete(?CACHE_ETS),
    ok.

-spec test_size() -> non_neg_integer().
test_size() ->
    ets:info(?ETS, size).

-spec test_tab_name() -> atom().
test_tab_name() ->
    ?ETS.

-spec test_cache_size() -> non_neg_integer().
test_cache_size() ->
    ets:info(?CACHE_ETS, size).

-spec test_clear_cache() -> ok.
test_clear_cache() ->
    ets:delete_all_objects(?CACHE_ETS),
    ok.

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        {"cache_miss_on_first_lookup", ?_test(cache_miss_on_first_lookup())},
        {"cache_hit_on_second_lookup", ?_test(cache_hit_on_second_lookup())},
        {"cache_expiration", ?_test(cache_expiration())},
        {"cache_invalidation_on_insert", ?_test(cache_invalidation_on_insert())},
        {"cache_invalidation_on_delete", ?_test(cache_invalidation_on_delete())},
        {"cache_invalidation_on_replace", ?_test(cache_invalidation_on_replace())},
        {"cache_deduplicates_route_ids", ?_test(cache_deduplicates_route_ids())},
        {"clear_cache_function", ?_test(clear_cache_function())},
        {"cache_size_function", ?_test(cache_size_function())}
    ]}.

foreach_setup() ->
    BaseDirPath = filename:join([
        ?MODULE,
        erlang:integer_to_list(erlang:system_time(millisecond)),
        "data"
    ]),
    ok = application:set_env(hpr, data_dir, BaseDirPath),
    ok = application:set_env(hpr, devaddr_cache_ttl_ms, 1000),
    true = hpr_skf_storage:test_register_heir(),
    ok = hpr_route_ets:init(),
    ok.

foreach_cleanup(ok) ->
    ok = hpr_devaddr_range_storage:test_delete_ets(),
    ok = hpr_eui_pair_storage:test_delete_ets(),
    ok = hpr_skf_storage:test_delete_ets(),
    ok = hpr_route_storage:test_delete_ets(),
    true = hpr_skf_storage:test_unregister_heir(),
    ok.

cache_miss_on_first_lookup() ->
    %% Setup route
    RouteID = "test-route-1",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 1,
        oui => 1,
        server => #{host => "localhost", port => 1234, protocol => {gwmp, #{mapping => []}}},
        max_copies => 10
    }),
    ok = hpr_route_storage:insert(Route),

    %% Insert devaddr range
    DevAddr = 16#00000001,
    DevAddrRange = hpr_devaddr_range:test_new(#{
        route_id => RouteID,
        start_addr => 16#00000000,
        end_addr => 16#00000002
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange),

    %% Cache should be empty before lookup
    ?assertEqual(0, cache_size()),
    ?assertEqual([], ets:lookup(?CACHE_ETS, DevAddr)),

    %% First lookup - should be a cache miss
    Routes = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(1, erlang:length(Routes)),
    [FoundRoute] = Routes,
    ?assertEqual(RouteID, hpr_route:id(hpr_route_ets:route(FoundRoute))),

    %% Cache should now have 1 entry with correct data
    ?assertEqual(1, cache_size()),
    [{DevAddr, {CachedRouteIDs, Timestamp}}] = ets:lookup(?CACHE_ETS, DevAddr),
    ?assertEqual([RouteID], CachedRouteIDs),
    ?assert(is_integer(Timestamp)),
    ?assert(Timestamp > 0),
    ok.

cache_hit_on_second_lookup() ->
    %% Setup route
    RouteID = "test-route-2",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 1,
        oui => 1,
        server => #{host => "localhost", port => 1234, protocol => {gwmp, #{mapping => []}}},
        max_copies => 10
    }),
    ok = hpr_route_storage:insert(Route),

    %% Insert devaddr range
    DevAddr = 16#00000010,
    DevAddrRange = hpr_devaddr_range:test_new(#{
        route_id => RouteID,
        start_addr => 16#00000010,
        end_addr => 16#00000020
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange),

    %% First lookup - cache miss
    Routes1 = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(1, erlang:length(Routes1)),
    ?assertEqual(1, cache_size()),

    %% Get cached data after first lookup
    [{DevAddr, {CachedRouteIDs1, Timestamp1}}] = ets:lookup(?CACHE_ETS, DevAddr),
    ?assertEqual([RouteID], CachedRouteIDs1),

    %% Wait a bit to ensure timestamps would differ if cache was refreshed
    timer:sleep(10),

    %% Second lookup - should be cache hit (timestamp should NOT change)
    Routes2 = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(1, erlang:length(Routes2)),
    ?assertEqual(1, cache_size()),

    %% Verify cache entry is unchanged (proves it was a cache hit)
    [{DevAddr, {CachedRouteIDs2, Timestamp2}}] = ets:lookup(?CACHE_ETS, DevAddr),
    ?assertEqual(CachedRouteIDs1, CachedRouteIDs2),
    ?assertEqual(Timestamp1, Timestamp2),

    %% Routes should be the same
    ?assertEqual(Routes1, Routes2),
    ok.

cache_expiration() ->
    %% Setup route
    RouteID = "test-route-3",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 1,
        oui => 1,
        server => #{host => "localhost", port => 1234, protocol => {gwmp, #{mapping => []}}},
        max_copies => 10
    }),
    ok = hpr_route_storage:insert(Route),

    %% Insert devaddr range
    DevAddr = 16#00000030,
    DevAddrRange = hpr_devaddr_range:test_new(#{
        route_id => RouteID,
        start_addr => 16#00000030,
        end_addr => 16#00000040
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange),

    %% Set short TTL for this test
    ok = application:set_env(hpr, devaddr_cache_ttl_ms, 100),

    %% First lookup - cache miss
    Routes1 = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(1, erlang:length(Routes1)),
    ?assertEqual(1, cache_size()),

    %% Get cached data after first lookup
    [{DevAddr, {CachedRouteIDs1, Timestamp1}}] = ets:lookup(?CACHE_ETS, DevAddr),
    ?assertEqual([RouteID], CachedRouteIDs1),

    %% Wait for cache to expire
    timer:sleep(150),

    %% Lookup after expiration - should trigger fresh lookup and update timestamp
    Routes2 = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(1, erlang:length(Routes2)),

    %% Cache should still have 1 entry but timestamp should be updated
    ?assertEqual(1, cache_size()),
    [{DevAddr, {CachedRouteIDs2, Timestamp2}}] = ets:lookup(?CACHE_ETS, DevAddr),
    ?assertEqual([RouteID], CachedRouteIDs2),
    ?assert(Timestamp2 > Timestamp1, "Timestamp should be updated after expiration"),

    %% Routes should still be the same
    ?assertEqual(Routes1, Routes2),

    %% Reset TTL
    ok = application:set_env(hpr, devaddr_cache_ttl_ms, 1000),
    ok.

cache_invalidation_on_insert() ->
    %% Setup route
    RouteID = "test-route-4",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 1,
        oui => 1,
        server => #{host => "localhost", port => 1234, protocol => {gwmp, #{mapping => []}}},
        max_copies => 10
    }),
    ok = hpr_route_storage:insert(Route),

    %% Insert first devaddr range
    DevAddr = 16#00000050,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID,
        start_addr => 16#00000050,
        end_addr => 16#00000060
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange1),

    %% First lookup to populate cache
    Routes1 = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(1, erlang:length(Routes1)),
    ?assertEqual(1, cache_size()),

    %% Verify cache entry exists
    [{DevAddr, {CachedRouteIDs1, _Timestamp1}}] = ets:lookup(?CACHE_ETS, DevAddr),
    ?assertEqual([RouteID], CachedRouteIDs1),

    %% Insert another range for same route - should invalidate cache
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => RouteID,
        start_addr => 16#00000061,
        end_addr => 16#00000070
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange2),

    %% Cache entry for this DevAddr should be cleared
    ?assertEqual([], ets:lookup(?CACHE_ETS, DevAddr)),
    ?assertEqual(0, cache_size()),

    %% Next lookup should work and repopulate cache
    Routes2 = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(1, erlang:length(Routes2)),
    ?assertEqual(1, cache_size()),
    ok.

cache_invalidation_on_delete() ->
    %% Setup route
    RouteID = "test-route-5",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 1,
        oui => 1,
        server => #{host => "localhost", port => 1234, protocol => {gwmp, #{mapping => []}}},
        max_copies => 10
    }),
    ok = hpr_route_storage:insert(Route),

    %% Insert devaddr range
    DevAddr = 16#00000070,
    DevAddrRange = hpr_devaddr_range:test_new(#{
        route_id => RouteID,
        start_addr => 16#00000070,
        end_addr => 16#00000080
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange),

    %% First lookup to populate cache
    Routes1 = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(1, erlang:length(Routes1)),
    ?assertEqual(1, cache_size()),

    %% Verify cache entry exists
    [{DevAddr, {CachedRouteIDs1, _Timestamp1}}] = ets:lookup(?CACHE_ETS, DevAddr),
    ?assertEqual([RouteID], CachedRouteIDs1),

    %% Delete the devaddr range - should invalidate cache
    ok = hpr_devaddr_range_storage:delete(DevAddrRange),

    %% Cache should be cleared
    ?assertEqual([], ets:lookup(?CACHE_ETS, DevAddr)),
    ?assertEqual(0, cache_size()),

    %% Next lookup should find no routes and cache empty result
    Routes2 = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(0, erlang:length(Routes2)),

    %% Cache should now contain empty result
    ?assertEqual(1, cache_size()),
    [{DevAddr, {CachedRouteIDs2, _Timestamp2}}] = ets:lookup(?CACHE_ETS, DevAddr),
    ?assertEqual([], CachedRouteIDs2),
    ok.

cache_invalidation_on_replace() ->
    %% Setup route
    RouteID = "test-route-6",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 1,
        oui => 1,
        server => #{host => "localhost", port => 1234, protocol => {gwmp, #{mapping => []}}},
        max_copies => 10
    }),
    ok = hpr_route_storage:insert(Route),

    %% Insert devaddr range
    DevAddr = 16#00000090,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID,
        start_addr => 16#00000090,
        end_addr => 16#000000A0
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange1),

    %% First lookup to populate cache
    Routes1 = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(1, erlang:length(Routes1)),
    ?assertEqual(1, cache_size()),

    %% Verify cache entry exists
    [{DevAddr, {CachedRouteIDs1, _Timestamp1}}] = ets:lookup(?CACHE_ETS, DevAddr),
    ?assertEqual([RouteID], CachedRouteIDs1),

    %% Replace route - should invalidate cache
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => RouteID,
        start_addr => 16#000000A1,
        end_addr => 16#000000B0
    }),
    Removed = hpr_devaddr_range_storage:replace_route(RouteID, [DevAddrRange2]),
    ?assertEqual(1, Removed),

    %% Cache should be cleared
    ?assertEqual([], ets:lookup(?CACHE_ETS, DevAddr)),
    ?assertEqual(0, cache_size()),

    %% Next lookup should find no routes (range no longer includes DevAddr)
    Routes2 = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(0, erlang:length(Routes2)),

    %% Verify empty result was cached
    ?assertEqual(1, cache_size()),
    [{DevAddr, {CachedRouteIDs2, _Timestamp2}}] = ets:lookup(?CACHE_ETS, DevAddr),
    ?assertEqual([], CachedRouteIDs2),
    ok.

cache_deduplicates_route_ids() ->
    %% Setup route
    RouteID = "test-route-dedup",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 1,
        oui => 1,
        server => #{host => "localhost", port => 1234, protocol => {gwmp, #{mapping => []}}},
        max_copies => 10
    }),
    ok = hpr_route_storage:insert(Route),

    %% Insert multiple overlapping devaddr ranges for same route
    DevAddr = 16#000000B0,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID,
        start_addr => 16#000000A0,
        end_addr => 16#000000C0
    }),
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => RouteID,
        start_addr => 16#000000B0,
        end_addr => 16#000000D0
    }),
    DevAddrRange3 = hpr_devaddr_range:test_new(#{
        route_id => RouteID,
        start_addr => 16#00000090,
        end_addr => 16#000000B5
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange1),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange2),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange3),

    %% Lookup should find all 3 ranges but return only 1 route (deduplicated)
    Routes = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(1, erlang:length(Routes)),
    [FoundRoute] = Routes,
    ?assertEqual(RouteID, hpr_route:id(hpr_route_ets:route(FoundRoute))),

    %% Verify cached RouteIDs contains duplicates (raw ETS select result)
    [{DevAddr, {CachedRouteIDs, _Timestamp}}] = ets:lookup(?CACHE_ETS, DevAddr),
    ?assertEqual(3, erlang:length(CachedRouteIDs)),
    ?assertEqual([RouteID, RouteID, RouteID], CachedRouteIDs),

    %% Second lookup should still return only 1 route (usort applied)
    Routes2 = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(1, erlang:length(Routes2)),
    ok.

clear_cache_function() ->
    %% Setup route and devaddr range
    RouteID = "test-route-7",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 1,
        oui => 1,
        server => #{host => "localhost", port => 1234, protocol => {gwmp, #{mapping => []}}},
        max_copies => 10
    }),
    ok = hpr_route_storage:insert(Route),

    DevAddr = 16#000000C0,
    DevAddrRange = hpr_devaddr_range:test_new(#{
        route_id => RouteID,
        start_addr => 16#000000C0,
        end_addr => 16#000000D0
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange),

    %% Populate cache
    _Routes = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(1, cache_size()),

    %% Clear cache
    ok = clear_cache(),
    ?assertEqual(0, cache_size()),

    %% Next lookup should work and repopulate cache
    _Routes2 = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(1, cache_size()),
    ok.

cache_size_function() ->
    %% Cache should start empty
    ?assertEqual(0, cache_size()),

    %% Setup multiple routes and ranges
    lists:foreach(
        fun(N) ->
            RouteID = "test-route-" ++ erlang:integer_to_list(N),
            Route = hpr_route:test_new(#{
                id => RouteID,
                net_id => 1,
                oui => 1,
                server => #{
                    host => "localhost", port => 1234, protocol => {gwmp, #{mapping => []}}
                },
                max_copies => 10
            }),
            ok = hpr_route_storage:insert(Route),

            DevAddr = 16#00000100 + N,
            DevAddrRange = hpr_devaddr_range:test_new(#{
                route_id => RouteID,
                start_addr => DevAddr,
                end_addr => DevAddr + 10
            }),
            ok = hpr_devaddr_range_storage:insert(DevAddrRange),

            %% Lookup to populate cache
            _Routes = hpr_devaddr_range_storage:lookup(DevAddr)
        end,
        lists:seq(1, 5)
    ),

    %% Cache should have 5 entries
    ?assertEqual(5, cache_size()),
    ok.

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

-spec clear_cache() -> ok.
clear_cache() ->
    ets:delete_all_objects(?CACHE_ETS),
    ok.

-spec cache_size() -> non_neg_integer().
cache_size() ->
    case ets:info(?CACHE_ETS, size) of
        undefined -> 0;
        Size -> Size
    end.

%% -------------------------------------------------------------------
%% Route Stream Helpers
%% -------------------------------------------------------------------

-spec delete_route(hpr_route:id()) -> non_neg_integer().
delete_route(RouteID) ->
    ok = invalidate_cache_for_route(RouteID),
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

-spec invalidate_cache_for_route(RouteID :: hpr_route:id()) -> ok.
invalidate_cache_for_route(RouteID) ->
    %% Delete all cache entries that contain this RouteID
    %% Since cache stores {DevAddr, {RouteIDs, Timestamp}}, we need to iterate
    ets:foldl(
        fun({DevAddr, {RouteIDs, _Ts}}, Acc) ->
            case lists:member(RouteID, RouteIDs) of
                true -> ets:delete(?CACHE_ETS, DevAddr);
                false -> ok
            end,
            Acc
        end,
        ok,
        ?CACHE_ETS
    ),
    ok.

-spec invalidate_cache_for_range(
    StartAddr :: non_neg_integer(),
    EndAddr :: non_neg_integer()
) -> ok.
invalidate_cache_for_range(StartAddr, EndAddr) ->
    %% Delete all cache entries for DevAddrs within this range
    %% This handles the case where empty results were cached
    ets:foldl(
        fun({DevAddr, _CachedData}, Acc) ->
            case DevAddr >= StartAddr andalso DevAddr =< EndAddr of
                true -> ets:delete(?CACHE_ETS, DevAddr);
                false -> ok
            end,
            Acc
        end,
        ok,
        ?CACHE_ETS
    ),
    ok.

-spec catch_metrics(Fun :: fun(() -> ok)) -> ok.
catch_metrics(Fun) ->
    try
        Fun()
    catch
        _:_ -> ok
    end.

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
