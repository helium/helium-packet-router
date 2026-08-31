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

    rebuild_index/0,
    index_stats/0
]).

-ifdef(TEST).
-export([test_delete_ets/0, test_size/0, test_tab_name/0, test_index_size/0, test_wide_size/0]).
-endif.

-define(ETS, hpr_route_devaddr_ranges_ets).
-define(DETS, hpr_route_devaddr_ranges_dets).
%% Bucketed interval index over ?ETS, so a lookup is a hash lookup instead of a
%% scan. ?ETS stays authoritative; these two are derived and rebuilt from it.
%%
%% Replaces a per-DevAddr result cache. That cache only hid the real cost -- a
%% miss ran a linear ets:select over every range -- and could never help a
%% DevAddr it had not already seen. Indexing makes every lookup cheap, so there
%% is no miss to hide, and nothing to keep warm, invalidate or evict.
-define(INDEX_ETS, hpr_devaddr_range_index_ets).
-define(WIDE_ETS, hpr_devaddr_range_wide_ets).

%% 64 devaddrs per bucket. The table is really a point-lookup table with a few
%% real intervals -- the overwhelming majority of ranges are a single address,
%% and nearly all the rest are narrow -- while the occupied address space is
%% heavily clustered by NetID. A coarse bucket therefore does not spread the
%% load: it leaves thousands of ranges sharing one key, and a lookup landing
%% there scans them all. A small bucket keeps the candidate list at or near
%% empty for real traffic, and costs almost nothing in fan-out, because a range
%% is indexed once per bucket it touches and hardly any range spans more than
%% one.
-define(BUCKET_BITS, 6).
%% A range spanning more than this many buckets goes to ?WIDE_ETS instead of
%% being fanned out. ?WIDE_ETS is scanned on EVERY lookup, so it has to stay
%% empty to be free: even a handful of entries taxes every packet. The threshold
%% is expressed in buckets but sized in addresses -- 65536 * 2^6 = 4M -- which no
%% real range comes close to, so it sits empty as a safety valve against a future
%% pathological range. Keep it in step with ?BUCKET_BITS: shrinking the bucket
%% without growing this pushes wide ranges into the always-scanned table.
%% index_stats/0 reports the count.
-define(MAX_BUCKETS_PER_RANGE, 65536).
-define(WIDE_KEY, wide).

-define(DETS_FILENAME, "hpr_devaddr_range_storage.dets").

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [
        public, named_table, bag, {read_concurrency, true}
    ]),
    ?INDEX_ETS = ets:new(?INDEX_ETS, [
        public, named_table, bag, {read_concurrency, true}
    ]),
    ?WIDE_ETS = ets:new(?WIDE_ETS, [
        public, named_table, bag, {read_concurrency, true}
    ]),
    %% rehydrate_from_dets/0 builds the index once ?ETS is populated.
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

%% The bounds check stays here rather than moving into an ets:select match spec:
%% ets:select builds and compiles a spec per call, which costs more than
%% filtering the handful of candidates a bucket returns.
-spec lookup(DevAddr :: non_neg_integer()) -> [hpr_route_ets:route()].
lookup(DevAddr) ->
    Candidates =
        ets:lookup(?INDEX_ETS, DevAddr bsr ?BUCKET_BITS) ++
            ets:lookup(?WIDE_ETS, ?WIDE_KEY),
    RouteIDs = lists:usort([
        RouteID
     || {_Key, {Start, End, RouteID}} <- Candidates, Start =< DevAddr, DevAddr =< End
    ]),
    [
        Route
     || RouteID <- RouteIDs,
        {ok, Route} <- [hpr_route_storage:lookup(RouteID)]
    ].

-spec insert(DevAddrRange :: hpr_devaddr_range:devaddr_range()) -> ok.
insert(DevAddrRange) ->
    StartAddr = hpr_devaddr_range:start_addr(DevAddrRange),
    EndAddr = hpr_devaddr_range:end_addr(DevAddrRange),
    RouteID = hpr_devaddr_range:route_id(DevAddrRange),
    true = ets:insert(?ETS, [{{StartAddr, EndAddr}, RouteID}]),
    ok = index_insert(StartAddr, EndAddr, RouteID),
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
    StartAddr = hpr_devaddr_range:start_addr(DevAddrRange),
    EndAddr = hpr_devaddr_range:end_addr(DevAddrRange),
    RouteID = hpr_devaddr_range:route_id(DevAddrRange),
    true = ets:delete_object(?ETS, {{StartAddr, EndAddr}, RouteID}),
    ok = index_delete(StartAddr, EndAddr, RouteID),
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
    ets:delete_all_objects(?INDEX_ETS),
    ets:delete_all_objects(?WIDE_ETS),
    ok.

%% Rebuild the derived index from ?ETS. Called after hydration/migration, and
%% exposed so an operator can force it if the index is ever suspected of drifting.
-spec rebuild_index() -> non_neg_integer().
rebuild_index() ->
    true = ets:delete_all_objects(?INDEX_ETS),
    true = ets:delete_all_objects(?WIDE_ETS),
    ets:foldl(
        fun({{StartAddr, EndAddr}, RouteID}, Count) ->
            ok = index_insert(StartAddr, EndAddr, RouteID),
            Count + 1
        end,
        0,
        ?ETS
    ).

-spec index_stats() ->
    #{
        ranges := non_neg_integer(),
        index_rows := non_neg_integer(),
        wide_ranges := non_neg_integer()
    }.
index_stats() ->
    #{
        ranges => table_size(?ETS),
        index_rows => table_size(?INDEX_ETS),
        wide_ranges => table_size(?WIDE_ETS)
    }.

%% ------------------------------------------------------------------
%% Index Function Definitions
%% ------------------------------------------------------------------

-spec index_insert(
    StartAddr :: non_neg_integer(), EndAddr :: non_neg_integer(), RouteID :: hpr_route:id()
) -> ok.
index_insert(StartAddr, EndAddr, RouteID) ->
    Entry = {StartAddr, EndAddr, RouteID},
    case index_buckets(StartAddr, EndAddr) of
        {ok, Buckets} ->
            true = ets:insert(?INDEX_ETS, [{Bucket, Entry} || Bucket <- Buckets]);
        wide ->
            true = ets:insert(?WIDE_ETS, {?WIDE_KEY, Entry})
    end,
    ok.

-spec index_delete(
    StartAddr :: non_neg_integer(), EndAddr :: non_neg_integer(), RouteID :: hpr_route:id()
) -> ok.
index_delete(StartAddr, EndAddr, RouteID) ->
    Entry = {StartAddr, EndAddr, RouteID},
    case index_buckets(StartAddr, EndAddr) of
        {ok, Buckets} ->
            lists:foreach(
                fun(Bucket) -> true = ets:delete_object(?INDEX_ETS, {Bucket, Entry}) end,
                Buckets
            );
        wide ->
            true = ets:delete_object(?WIDE_ETS, {?WIDE_KEY, Entry})
    end,
    ok.

-spec index_buckets(StartAddr :: non_neg_integer(), EndAddr :: non_neg_integer()) ->
    {ok, [non_neg_integer()]} | wide.
index_buckets(StartAddr, EndAddr) when EndAddr < StartAddr ->
    %% Degenerate range: no DevAddr can satisfy Start =< DevAddr =< End, so it
    %% would never be returned. Index nothing rather than let lists:seq/2 raise.
    {ok, []};
index_buckets(StartAddr, EndAddr) ->
    First = StartAddr bsr ?BUCKET_BITS,
    Last = EndAddr bsr ?BUCKET_BITS,
    case (Last - First) < ?MAX_BUCKETS_PER_RANGE of
        true -> {ok, lists:seq(First, Last)};
        false -> wide
    end.

-spec table_size(Tab :: atom()) -> non_neg_integer().
table_size(Tab) ->
    case ets:info(Tab, size) of
        undefined -> 0;
        Size -> Size
    end.

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
    Ranges = lookup_for_route(RouteID),
    Deleted = ets:select_delete(?ETS, [{{'_', RouteID}, [], [true]}]),
    lists:foreach(
        fun({StartAddr, EndAddr}) -> ok = index_delete(StartAddr, EndAddr, RouteID) end,
        Ranges
    ),
    Deleted.

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
    ok = with_open_dets(fun() ->
        case dets:to_ets(?DETS, ?ETS) of
            {error, _Reason} ->
                lager:error("failed ot hydrate ets: ~p", [_Reason]);
            _ ->
                lager:info("ets hydrated")
        end
    end),
    Indexed = rebuild_index(),
    lager:info("indexed ~w devaddr ranges: ~p", [Indexed, index_stats()]),
    ok.

-spec with_open_dets(FN :: fun()) -> ok.
with_open_dets(FN) ->
    DataDir = hpr_utils:base_data_dir(),
    DETSFile = filename:join([DataDir, ?DETS_FILENAME]),
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

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-spec test_delete_ets() -> ok.
test_delete_ets() ->
    ets:delete(?ETS),
    ets:delete(?INDEX_ETS),
    ets:delete(?WIDE_ETS),
    ok.

-spec test_size() -> non_neg_integer().
test_size() ->
    ets:info(?ETS, size).

-spec test_tab_name() -> atom().
test_tab_name() ->
    ?ETS.

-spec test_index_size() -> non_neg_integer().
test_index_size() ->
    ets:info(?INDEX_ETS, size).

-spec test_wide_size() -> non_neg_integer().
test_wide_size() ->
    ets:info(?WIDE_ETS, size).

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        {"lookup_finds_route", ?_test(lookup_finds_route())},
        {"lookup_reflects_delete", ?_test(lookup_reflects_delete())},
        {"lookup_reflects_insert", ?_test(lookup_reflects_insert())},
        {"lookup_across_bucket_boundary", ?_test(lookup_across_bucket_boundary())},
        {"wide_range_overflows", ?_test(wide_range_overflows())},
        {"lookup_deduplicates_overlapping_ranges",
            ?_test(lookup_deduplicates_overlapping_ranges())},
        {"degenerate_range_never_matches", ?_test(degenerate_range_never_matches())},
        {"delete_route_leaves_no_index_rows", ?_test(delete_route_leaves_no_index_rows())},
        {"replace_route_updates_index", ?_test(replace_route_updates_index())},
        {"rebuild_index_reconstructs_from_ets", ?_test(rebuild_index_reconstructs_from_ets())}
    ]}.

foreach_setup() ->
    BaseDirPath = filename:join([
        ?MODULE,
        erlang:integer_to_list(erlang:system_time(millisecond)),
        "data"
    ]),
    ok = application:set_env(hpr, data_dir, BaseDirPath),
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

%% Inserts a route and returns its id.
test_route(RouteID) ->
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 1,
        oui => 1,
        server => #{host => "localhost", port => 1234, protocol => {gwmp, #{mapping => []}}},
        max_copies => 10
    }),
    ok = hpr_route_storage:insert(Route),
    Route.

test_range(RouteID, StartAddr, EndAddr) ->
    hpr_devaddr_range:test_new(#{
        route_id => RouteID, start_addr => StartAddr, end_addr => EndAddr
    }).

%% The route ids a lookup resolved to, as strings.
lookup_ids(DevAddr) ->
    lists:sort([
        hpr_route:id(hpr_route_ets:route(RouteETS))
     || RouteETS <- ?MODULE:lookup(DevAddr)
    ]).

lookup_finds_route() ->
    RouteID = "test-route-lookup",
    _ = test_route(RouteID),
    ok = ?MODULE:insert(test_range(RouteID, 16#00000000, 16#00000010)),

    ?assertEqual([RouteID], lookup_ids(16#00000005)),
    ?assertEqual([RouteID], lookup_ids(16#00000000), "inclusive lower bound"),
    ?assertEqual([RouteID], lookup_ids(16#00000010), "inclusive upper bound"),
    ?assertEqual([], lookup_ids(16#00000011), "just past the end"),
    ok.

lookup_reflects_delete() ->
    RouteID = "test-route-delete",
    _ = test_route(RouteID),
    Range = test_range(RouteID, 16#00000000, 16#00000010),
    ok = ?MODULE:insert(Range),
    ?assertEqual([RouteID], lookup_ids(16#00000005)),

    ok = ?MODULE:delete(Range),
    %% No stale cache to invalidate any more -- the index is the lookup path, so
    %% this also proves index rows are removed rather than merely shadowed.
    ?assertEqual([], lookup_ids(16#00000005)),
    ?assertEqual(0, ?MODULE:test_index_size()),
    ok.

lookup_reflects_insert() ->
    RouteID = "test-route-insert",
    _ = test_route(RouteID),
    %% Miss first: the old cache would have memoised this empty result.
    ?assertEqual([], lookup_ids(16#00000005)),

    ok = ?MODULE:insert(test_range(RouteID, 16#00000000, 16#00000010)),
    ?assertEqual([RouteID], lookup_ids(16#00000005)),
    ok.

lookup_across_bucket_boundary() ->
    RouteID = "test-route-boundary",
    _ = test_route(RouteID),
    %% Straddles a bucket boundary, so it must be indexed under both buckets.
    %% Derived from ?BUCKET_BITS rather than hardcoded: retuning the constant
    %% must not quietly turn this into a single-bucket range that proves nothing.
    Boundary = 1 bsl ?BUCKET_BITS,
    StartAddr = Boundary - 16,
    EndAddr = Boundary + 16,
    ok = ?MODULE:insert(test_range(RouteID, StartAddr, EndAddr)),

    ?assertEqual(2, ?MODULE:test_index_size(), "one row per bucket touched"),
    ?assertEqual([RouteID], lookup_ids(StartAddr), "found in the low bucket"),
    ?assertEqual([RouteID], lookup_ids(Boundary), "found at the boundary"),
    ?assertEqual([RouteID], lookup_ids(EndAddr), "found in the high bucket"),
    ?assertEqual([], lookup_ids(StartAddr - 1)),
    ?assertEqual([], lookup_ids(EndAddr + 1)),
    ok.

wide_range_overflows() ->
    RouteID = "test-route-wide",
    _ = test_route(RouteID),
    %% Exactly one bucket past ?MAX_BUCKETS_PER_RANGE, so it goes to ?WIDE_ETS
    %% instead of fanning out one index row per bucket. Sized off both constants
    %% so it keeps testing the overflow rather than the happy path.
    EndAddr = ?MAX_BUCKETS_PER_RANGE bsl ?BUCKET_BITS,
    Mid = EndAddr div 2,
    Range = test_range(RouteID, 16#00000000, EndAddr),
    ok = ?MODULE:insert(Range),

    ?assertEqual(0, ?MODULE:test_index_size(), "not fanned out"),
    ?assertEqual(1, ?MODULE:test_wide_size()),
    ?assertEqual([RouteID], lookup_ids(Mid), "still found, via the wide scan"),
    ?assertEqual([RouteID], lookup_ids(16#00000000)),
    ?assertEqual([RouteID], lookup_ids(EndAddr)),
    ?assertEqual([], lookup_ids(EndAddr + 1)),

    ok = ?MODULE:delete(Range),
    ?assertEqual(0, ?MODULE:test_wide_size()),
    ?assertEqual([], lookup_ids(Mid)),
    ok.

lookup_deduplicates_overlapping_ranges() ->
    RouteID = "test-route-dedup",
    _ = test_route(RouteID),
    %% Three overlapping ranges, all the same route: the DevAddr matches every
    %% one of them, but the route must come back once.
    ok = ?MODULE:insert(test_range(RouteID, 16#000000A0, 16#000000C0)),
    ok = ?MODULE:insert(test_range(RouteID, 16#000000B0, 16#000000D0)),
    ok = ?MODULE:insert(test_range(RouteID, 16#00000090, 16#000000B5)),

    ?assertEqual([RouteID], lookup_ids(16#000000B0)),
    ?assertEqual(1, erlang:length(?MODULE:lookup(16#000000B0))),
    ok.

degenerate_range_never_matches() ->
    RouteID = "test-route-degenerate",
    _ = test_route(RouteID),
    %% EndAddr < StartAddr cannot satisfy Start =< DevAddr =< End. It must be
    %% indexed as nothing rather than blowing up lists:seq/2 on insert.
    ok = ?MODULE:insert(test_range(RouteID, 16#00000010, 16#00000001)),

    ?assertEqual(0, ?MODULE:test_index_size()),
    ?assertEqual(0, ?MODULE:test_wide_size()),
    ?assertEqual([], lookup_ids(16#00000005)),
    ?assertEqual([], lookup_ids(16#00000010)),
    ok.

delete_route_leaves_no_index_rows() ->
    RouteID = "test-route-delete-route",
    _ = test_route(RouteID),
    Boundary = 1 bsl ?BUCKET_BITS,
    ok = ?MODULE:insert(test_range(RouteID, 16#00000000, 16#00000010)),
    ok = ?MODULE:insert(test_range(RouteID, Boundary - 16, Boundary + 16)),
    ok = ?MODULE:insert(
        test_range(RouteID, 16#00000000, ?MAX_BUCKETS_PER_RANGE bsl ?BUCKET_BITS)
    ),
    ?assertEqual(3, ?MODULE:test_index_size(), "1 + 2 narrow rows"),
    ?assertEqual(1, ?MODULE:test_wide_size()),

    ?assertEqual(3, ?MODULE:delete_route(RouteID)),

    ?assertEqual(0, ?MODULE:test_size()),
    ?assertEqual(0, ?MODULE:test_index_size(), "no orphaned index rows"),
    ?assertEqual(0, ?MODULE:test_wide_size()),
    ?assertEqual([], lookup_ids(16#00000005)),
    ok.

replace_route_updates_index() ->
    RouteID = "test-route-replace",
    _ = test_route(RouteID),
    ok = ?MODULE:insert(test_range(RouteID, 16#00000000, 16#00000010)),
    ?assertEqual([RouteID], lookup_ids(16#00000005)),

    ?assertEqual(
        1,
        ?MODULE:replace_route(RouteID, [
            test_range(RouteID, 16#00000100, 16#00000110)
        ])
    ),

    ?assertEqual([], lookup_ids(16#00000005), "old range gone"),
    ?assertEqual([RouteID], lookup_ids(16#00000105), "new range live"),
    ?assertEqual(1, ?MODULE:test_index_size()),
    ok.

rebuild_index_reconstructs_from_ets() ->
    RouteID = "test-route-rebuild",
    _ = test_route(RouteID),
    ok = ?MODULE:insert(test_range(RouteID, 16#00000000, 16#00000010)),
    ok = ?MODULE:insert(test_range(RouteID, 16#00000000, 16#02000000)),

    %% ?ETS is authoritative; wipe the derived tables and rebuild from it.
    Before = {?MODULE:test_index_size(), ?MODULE:test_wide_size()},
    ?assertEqual(2, ?MODULE:rebuild_index(), "one pass per range"),
    ?assertEqual(Before, {?MODULE:test_index_size(), ?MODULE:test_wide_size()}),
    ?assertEqual([RouteID], lookup_ids(16#00000005)),
    ?assertEqual([RouteID], lookup_ids(16#01000000)),
    ok.

-endif.
