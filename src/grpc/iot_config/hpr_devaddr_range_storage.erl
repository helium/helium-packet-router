-module(hpr_devaddr_range_storage).

-export([
    init_ets/0,
    checkpoint/0,

    foldl/2,
    route_ids/0,
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
-define(DETS_V1, hpr_route_devaddr_ranges_dets_v1).
%% Bucketed interval index over ?ETS, so a lookup is a hash lookup instead of a
%% scan. ?ETS stays authoritative; these two are derived and rebuilt from it.
%%
%% Replaces a per-DevAddr result cache. That cache existed only to hide the fact
%% that a miss ran a linear ets:select over every range: on
%% mainnet-iot-hpr0-oregon that was 184,169 rows costing 30-60ms, ~42 times a
%% second, and the hpr_find_routes_histogram put ~90% of its 73 accumulated hours
%% in the >30ms buckets. The cache itself had grown to 1.23M rows / 457MB.
-define(INDEX_ETS, hpr_devaddr_range_index_ets).
-define(WIDE_ETS, hpr_devaddr_range_wide_ets).

%% 2^12 = 4096 devaddrs per bucket. Both constants are measured from a
%% mainnet-iot-hpr0-oregon dump of all 198,414 ranges replayed against the
%% 1,236,263 DevAddrs that node had actually seen, not picked by intuition:
%%
%%   * 91.9% of ranges are a SINGLE address (Start == End) and 99.9% are =< 256
%%     wide, so this is really a point-lookup table with a few real intervals.
%%   * The occupied address space is heavily clustered by NetID. At 2^20 the
%%     ranges fell into just 83 buckets and ONE held 102,352 of them, so a lookup
%%     there scanned half the table -- barely better than the linear select this
%%     replaces. 2^12 brings the real-traffic candidate list to 0 at the median
%%     (82.9% of lookups match nothing) and 2 at p99.
%%   * 199,467 index rows for 198,414 ranges: 1.005x, so the fan-out is ~free.
-define(BUCKET_BITS, 12).
%% A range spanning more than this many buckets goes to ?WIDE_ETS rather than
%% being fanned out, bounding index rows per range. ?WIDE_ETS is scanned on every
%% lookup, so it must stay small -- at 1024 (a 4M-address range) exactly zero
%% production ranges qualify, which costs ~1000 extra rows for the three widest
%% and leaves the always-on scan empty. It stays as a safety valve for a future
%% pathological range; index_stats/0 reports the count.
-define(MAX_BUCKETS_PER_RANGE, 1024).
-define(WIDE_KEY, wide).

%% Version 1: unversioned filename, route ids stored as char lists
%% Version 2: route ids stored as binaries
-define(DETS_FILENAME, "hpr_devaddr_range_storage_v2.dets").
-define(DETS_FILENAME_V1, "hpr_devaddr_range_storage.dets").

%% See hpr_eui_pair_storage: hpr_route:id() is a string(), and a 36-char UUID as
%% a char list costs 576 bytes per row. Stored as a binary it costs 56. The
%% module API still speaks strings.
-spec id_to_stored(RouteID :: hpr_route:id()) -> binary().
id_to_stored(RouteID) ->
    erlang:list_to_binary(RouteID).

-spec stored_to_id(Stored :: binary()) -> hpr_route:id().
stored_to_id(Stored) ->
    erlang:binary_to_list(Stored).

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
    %% Hand the callback the route id in its public string() form. Callers
    %% (hpr_metrics:record_routes/0, the config route refresh_broken command)
    %% compare it against hpr_route:id/1, so leaking the interned binary here
    %% would silently make every comparison false.
    ets:foldl(
        fun({Range, Stored}, InnerAcc) -> Fun({Range, stored_to_id(Stored)}, InnerAcc) end,
        Acc,
        ?ETS
    ).

-spec route_ids() -> sets:set(hpr_route:id()).
route_ids() ->
    %% The distinct route ids that have at least one devaddr range. Dedup in the
    %% stored form and convert only the survivors: there are ~184k rows but only
    %% ~5k routes, so converting per row (as foldl/2 must) would churn ~100MB
    %% every metrics tick.
    Stored = ets:foldl(
        fun({_Range, S}, Acc) -> sets:add_element(S, Acc) end,
        sets:new(),
        ?ETS
    ),
    sets:from_list([stored_to_id(S) || S <- sets:to_list(Stored)]).

-spec lookup(DevAddr :: non_neg_integer()) -> [hpr_route_ets:route()].
lookup(DevAddr) ->
    Candidates =
        ets:lookup(?INDEX_ETS, DevAddr bsr ?BUCKET_BITS) ++
            ets:lookup(?WIDE_ETS, ?WIDE_KEY),
    Stored = lists:usort([
        RouteId
     || {_Key, {Start, End, RouteId}} <- Candidates, Start =< DevAddr, DevAddr =< End
    ]),
    [
        Route
     || RouteId <- Stored,
        {ok, Route} <- [hpr_route_storage:lookup(stored_to_id(RouteId))]
    ].

-spec insert(DevAddrRange :: hpr_devaddr_range:devaddr_range()) -> ok.
insert(DevAddrRange) ->
    StartAddr = hpr_devaddr_range:start_addr(DevAddrRange),
    EndAddr = hpr_devaddr_range:end_addr(DevAddrRange),
    Stored = id_to_stored(hpr_devaddr_range:route_id(DevAddrRange)),
    true = ets:insert(?ETS, [{{StartAddr, EndAddr}, Stored}]),
    ok = index_insert(StartAddr, EndAddr, Stored),
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
    Stored = id_to_stored(hpr_devaddr_range:route_id(DevAddrRange)),
    true = ets:delete_object(?ETS, {{StartAddr, EndAddr}, Stored}),
    ok = index_delete(StartAddr, EndAddr, Stored),
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
        fun({{StartAddr, EndAddr}, Stored}, Count) ->
            ok = index_insert(StartAddr, EndAddr, Stored),
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
    StartAddr :: non_neg_integer(), EndAddr :: non_neg_integer(), Stored :: binary()
) -> ok.
index_insert(StartAddr, EndAddr, Stored) ->
    Entry = {StartAddr, EndAddr, Stored},
    case index_buckets(StartAddr, EndAddr) of
        {ok, Buckets} ->
            true = ets:insert(?INDEX_ETS, [{Bucket, Entry} || Bucket <- Buckets]);
        wide ->
            true = ets:insert(?WIDE_ETS, {?WIDE_KEY, Entry})
    end,
    ok.

-spec index_delete(
    StartAddr :: non_neg_integer(), EndAddr :: non_neg_integer(), Stored :: binary()
) -> ok.
index_delete(StartAddr, EndAddr, Stored) ->
    Entry = {StartAddr, EndAddr, Stored},
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
    MS = [{{{'$1', '$2'}, id_to_stored(RouteID)}, [], [{{'$1', '$2'}}]}],
    ets:select(?ETS, MS).

-spec count_for_route(RouteID :: hpr_route:id()) -> non_neg_integer().
count_for_route(RouteID) ->
    MS = [{{'_', id_to_stored(RouteID)}, [], [true]}],
    ets:select_count(?ETS, MS).

%% -------------------------------------------------------------------
%% Route Stream Helpers
%% -------------------------------------------------------------------

-spec delete_route(hpr_route:id()) -> non_neg_integer().
delete_route(RouteID) ->
    Stored = id_to_stored(RouteID),
    Ranges = lookup_for_route(RouteID),
    Deleted = ets:select_delete(?ETS, [{{'_', Stored}, [], [true]}]),
    lists:foreach(
        fun({StartAddr, EndAddr}) -> ok = index_delete(StartAddr, EndAddr, Stored) end,
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
    ok = maybe_migrate_v1(),
    Indexed = rebuild_index(),
    lager:info("indexed ~w devaddr ranges: ~p", [Indexed, index_stats()]),
    ok.

%% See hpr_eui_pair_storage:maybe_migrate_v2/0 -- same reasoning. The route
%% stream is incremental, so the table has to be carried across the format
%% change rather than resynced.
-spec maybe_migrate_v1() -> ok.
maybe_migrate_v1() ->
    DataDir = hpr_utils:base_data_dir(),
    V1File = filename:join([DataDir, ?DETS_FILENAME_V1]),
    case ets:info(?ETS, size) == 0 andalso filelib:is_regular(V1File) of
        false ->
            ok;
        true ->
            case dets:open_file(?DETS_V1, [{file, V1File}, {type, bag}, {access, read}]) of
                {ok, _} ->
                    Migrated = dets:foldl(
                        fun({Range, RouteID}, Cnt) ->
                            true = ets:insert(?ETS, {Range, id_to_stored(RouteID)}),
                            Cnt + 1
                        end,
                        0,
                        ?DETS_V1
                    ),
                    ok = dets:close(?DETS_V1),
                    ok = ?MODULE:checkpoint(),
                    lager:info("migrated ~w devaddr ranges from ~s", [
                        Migrated, ?DETS_FILENAME_V1
                    ]);
                {error, _Reason} ->
                    lager:warning("failed to open ~s to migrate: ~p", [V1File, _Reason])
            end,
            ok
    end.

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

migration_test_() ->
    {foreach, fun migration_setup/0, fun migration_cleanup/1, [
        {"v1 char lists become v2 binaries", ?_test(migrates_v1_dets())},
        {"no v1 file is a no-op", ?_test(migration_without_v1_file())},
        {"a populated v2 file wins", ?_test(migration_skipped_when_v2_populated())}
    ]}.

migration_setup() ->
    %% Unique per test AND per run: unique_integer/1 restarts with the VM, so a
    %% timestamp is needed too or a later run rehydrates an earlier run's dets
    %% files and the "no legacy file" cases stop being empty.
    RunDir = filename:join([
        ?MODULE,
        erlang:integer_to_list(erlang:system_time(nanosecond)) ++
            "-" ++ erlang:integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = application:set_env(hpr, data_dir, filename:join([RunDir, "data"])),
    RunDir.

migration_cleanup(RunDir) ->
    catch ets:delete(?ETS),
    catch ets:delete(?INDEX_ETS),
    catch ets:delete(?WIDE_ETS),
    _ = file:del_dir_r(RunDir),
    ok.

write_dets(DETSFilename, Entries) ->
    DETSFile = filename:join([hpr_utils:base_data_dir(), DETSFilename]),
    ok = filelib:ensure_dir(DETSFile),
    {ok, test_legacy_dets} = dets:open_file(test_legacy_dets, [
        {file, DETSFile}, {type, bag}
    ]),
    ok = dets:insert(test_legacy_dets, Entries),
    ok = dets:close(test_legacy_dets),
    DETSFile.

migrates_v1_dets() ->
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    _ = write_dets(?DETS_FILENAME_V1, [
        {{16#00000000, 16#00000010}, RouteID},
        {{16#00000020, 16#00000030}, RouteID}
    ]),

    ok = ?MODULE:init_ets(),

    ?assertEqual(2, ?MODULE:test_size()),
    ?assertEqual(
        lists:sort([
            {{16#00000000, 16#00000010}, erlang:list_to_binary(RouteID)},
            {{16#00000020, 16#00000030}, erlang:list_to_binary(RouteID)}
        ]),
        lists:sort(ets:tab2list(?ETS))
    ),
    %% The API still speaks strings, so callers cannot tell.
    ?assertEqual(
        [{16#00000000, 16#00000010}, {16#00000020, 16#00000030}],
        lists:sort(?MODULE:lookup_for_route(RouteID))
    ),
    ?assertEqual(2, ?MODULE:count_for_route(RouteID)),
    ?assert(filelib:is_regular(filename:join([hpr_utils:base_data_dir(), ?DETS_FILENAME]))),
    ?assert(filelib:is_regular(filename:join([hpr_utils:base_data_dir(), ?DETS_FILENAME_V1]))),
    ok.

migration_without_v1_file() ->
    ok = ?MODULE:init_ets(),
    ?assertEqual(0, ?MODULE:test_size()),
    ok.

migration_skipped_when_v2_populated() ->
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    _ = write_dets(?DETS_FILENAME, [
        {{16#00000000, 16#00000010}, erlang:list_to_binary(RouteID)}
    ]),
    _ = write_dets(?DETS_FILENAME_V1, [
        {{16#00000020, 16#00000030}, RouteID},
        {{16#00000040, 16#00000050}, RouteID}
    ]),

    ok = ?MODULE:init_ets(),

    ?assertEqual(1, ?MODULE:test_size()),
    ?assertEqual(
        [{{16#00000000, 16#00000010}, erlang:list_to_binary(RouteID)}],
        ets:tab2list(?ETS)
    ),
    ok.

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
        {"rebuild_index_reconstructs_from_ets", ?_test(rebuild_index_reconstructs_from_ets())},
        {"foldl_yields_string_route_ids", ?_test(foldl_yields_string_route_ids())},
        {"route_ids_yields_string_route_ids", ?_test(route_ids_yields_string_route_ids())}
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
    %% Spans the 2^20 bucket boundary, so it must be indexed under both buckets.
    StartAddr = 16#000FFF00,
    EndAddr = 16#00100100,
    ok = ?MODULE:insert(test_range(RouteID, StartAddr, EndAddr)),

    ?assertEqual(2, ?MODULE:test_index_size(), "one row per bucket touched"),
    ?assertEqual([RouteID], lookup_ids(StartAddr), "found in the low bucket"),
    ?assertEqual([RouteID], lookup_ids(16#00100000), "found at the boundary"),
    ?assertEqual([RouteID], lookup_ids(EndAddr), "found in the high bucket"),
    ?assertEqual([], lookup_ids(StartAddr - 1)),
    ?assertEqual([], lookup_ids(EndAddr + 1)),
    ok.

wide_range_overflows() ->
    RouteID = "test-route-wide",
    _ = test_route(RouteID),
    %% 33 buckets wide, past ?MAX_BUCKETS_PER_RANGE, so it goes to ?WIDE_ETS
    %% instead of fanning out one index row per bucket.
    Range = test_range(RouteID, 16#00000000, 16#02000000),
    ok = ?MODULE:insert(Range),

    ?assertEqual(0, ?MODULE:test_index_size(), "not fanned out"),
    ?assertEqual(1, ?MODULE:test_wide_size()),
    ?assertEqual([RouteID], lookup_ids(16#01000000), "still found, via the wide scan"),
    ?assertEqual([RouteID], lookup_ids(16#00000000)),
    ?assertEqual([RouteID], lookup_ids(16#02000000)),
    ?assertEqual([], lookup_ids(16#02000001)),

    ok = ?MODULE:delete(Range),
    ?assertEqual(0, ?MODULE:test_wide_size()),
    ?assertEqual([], lookup_ids(16#01000000)),
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
    ok = ?MODULE:insert(test_range(RouteID, 16#00000000, 16#00000010)),
    ok = ?MODULE:insert(test_range(RouteID, 16#000FFF00, 16#00100100)),
    ok = ?MODULE:insert(test_range(RouteID, 16#00000000, 16#02000000)),
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

foldl_yields_string_route_ids() ->
    %% hpr_metrics:record_routes/0 and the "config route refresh_broken" command
    %% build a set of route ids from foldl/2 and test membership with
    %% hpr_route:id/1. If foldl leaked the interned binary, every route with SKFs
    %% would be reported broken, so pin the public form here.
    RouteID = "test-route-foldl",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 1,
        oui => 1,
        server => #{host => "localhost", port => 1234, protocol => {gwmp, #{mapping => []}}},
        max_copies => 10
    }),
    ok = hpr_route_storage:insert(Route),
    ok = ?MODULE:insert(
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000900, end_addr => 16#00000910
        })
    ),

    Collected = ?MODULE:foldl(fun({_Range, ID}, Acc) -> [ID | Acc] end, []),
    ?assertEqual([RouteID], Collected),
    ?assert(sets:is_element(hpr_route:id(Route), sets:from_list(Collected))),
    ok.

route_ids_yields_string_route_ids() ->
    %% Same contract as foldl/2 -- hpr_metrics:record_routes/0 and the "config
    %% route refresh_broken" command test membership with hpr_route:id/1 -- but
    %% deduped before conversion, and deduped across ranges of the same route.
    RouteID = "test-route-route-ids",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 1,
        oui => 1,
        server => #{host => "localhost", port => 1234, protocol => {gwmp, #{mapping => []}}},
        max_copies => 10
    }),
    ok = hpr_route_storage:insert(Route),
    ok = ?MODULE:insert(
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000A00, end_addr => 16#00000A10
        })
    ),
    ok = ?MODULE:insert(
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000B00, end_addr => 16#00000B10
        })
    ),

    RouteIDs = ?MODULE:route_ids(),
    ?assertEqual([RouteID], sets:to_list(RouteIDs)),
    ?assert(sets:is_element(hpr_route:id(Route), RouteIDs)),
    ok.

-endif.
