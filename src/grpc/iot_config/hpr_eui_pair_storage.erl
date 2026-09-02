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
-define(DETS_V2, hpr_route_eui_pairs_dets_v2).

%% Version 1: dets is a set
%% Version 2: dets is a bag
%% Version 3: route ids are stored as binaries rather than char lists
-define(DETS_FILENAME, "hpr_eui_pair_storage_v3.dets").
-define(DETS_FILENAME_V2, "hpr_eui_pair_storage_v2.dets").

%% hpr_route:id() is a string(), and a 36-char UUID as a char list costs 36 cons
%% cells = 576 bytes. At 1.66M pairs that was 84% of this table (1.13GB of the
%% 2.16GB of ETS on mainnet-iot-hpr0-oregon); the same id as a binary is 56.
%% Only the stored form changes -- the module's API still speaks strings, as do
%% the protobufs, hpr_routes_ets's keypos, the CLI and the logs.
-spec id_to_stored(RouteID :: hpr_route:id()) -> binary().
id_to_stored(RouteID) ->
    erlang:list_to_binary(RouteID).

-spec stored_to_id(Stored :: binary()) -> hpr_route:id().
stored_to_id(Stored) ->
    erlang:binary_to_list(Stored).

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
     || {_, Stored} <- EUIPairs,
        {ok, Route} <- [hpr_route_storage:lookup(stored_to_id(Stored))]
    ]);
lookup(AppEUI, DevEUI) ->
    EUIPairs = ets:lookup(?ETS, {AppEUI, DevEUI}),
    lists:usort(
        lists:flatten([
            Route
         || {_, Stored} <- EUIPairs,
            {ok, Route} <- [hpr_route_storage:lookup(stored_to_id(Stored))]
        ]) ++ lookup(AppEUI, 0)
    ).

-spec insert(EUIPair :: hpr_eui_pair:eui_pair()) -> ok.
insert(EUIPair) ->
    true = ets:insert(?ETS, [
        {
            {hpr_eui_pair:app_eui(EUIPair), hpr_eui_pair:dev_eui(EUIPair)},
            id_to_stored(hpr_eui_pair:route_id(EUIPair))
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
        id_to_stored(hpr_eui_pair:route_id(EUIPair))
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

-include_lib("eunit/include/eunit.hrl").

migration_test_() ->
    {foreach, fun migration_setup/0, fun migration_cleanup/1, [
        {"v2 char lists become v3 binaries", ?_test(migrates_v2_dets())},
        {"no v2 file is a no-op", ?_test(migration_without_v2_file())},
        {"a populated v3 file wins", ?_test(migration_skipped_when_v3_populated())}
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
    _ = file:del_dir_r(RunDir),
    ok.

%% Writes Entries into DETSFilename as a legacy (pre-migration) file would look.
write_dets(DETSFilename, Entries) ->
    DETSFile = filename:join([hpr_utils:base_data_dir(), DETSFilename]),
    ok = filelib:ensure_dir(DETSFile),
    {ok, test_legacy_dets} = dets:open_file(test_legacy_dets, [
        {file, DETSFile}, {type, bag}
    ]),
    ok = dets:insert(test_legacy_dets, Entries),
    ok = dets:close(test_legacy_dets),
    DETSFile.

migrates_v2_dets() ->
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    _ = write_dets(?DETS_FILENAME_V2, [
        {{1, 1}, RouteID},
        {{2, 2}, RouteID}
    ]),

    ok = ?MODULE:init_ets(),

    %% Rows carried across the format change, with the ids now stored as binaries.
    ?assertEqual(2, ?MODULE:test_size()),
    ?assertEqual(
        lists:sort([
            {{1, 1}, erlang:list_to_binary(RouteID)},
            {{2, 2}, erlang:list_to_binary(RouteID)}
        ]),
        lists:sort(ets:tab2list(?ETS))
    ),
    %% The API still speaks strings, so callers cannot tell.
    ?assertEqual([{1, 1}, {2, 2}], lists:sort(?MODULE:lookup_for_route(RouteID))),
    ?assertEqual(2, ?MODULE:count_for_route(RouteID)),
    %% Checkpointed to v3, so the v2 file is never read again...
    ?assert(filelib:is_regular(filename:join([hpr_utils:base_data_dir(), ?DETS_FILENAME]))),
    %% ...but is left in place, so rolling back is just a redeploy.
    ?assert(filelib:is_regular(filename:join([hpr_utils:base_data_dir(), ?DETS_FILENAME_V2]))),
    ok.

migration_without_v2_file() ->
    ok = ?MODULE:init_ets(),
    ?assertEqual(0, ?MODULE:test_size()),
    ok.

migration_skipped_when_v3_populated() ->
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    %% v3 already holds the migrated form; v2 is stale and must not be re-applied
    %% on top of it, or every row would be duplicated on each boot.
    _ = write_dets(?DETS_FILENAME, [{{1, 1}, erlang:list_to_binary(RouteID)}]),
    _ = write_dets(?DETS_FILENAME_V2, [{{2, 2}, RouteID}, {{3, 3}, RouteID}]),

    ok = ?MODULE:init_ets(),

    ?assertEqual(1, ?MODULE:test_size()),
    ?assertEqual([{{1, 1}, erlang:list_to_binary(RouteID)}], ets:tab2list(?ETS)),
    ok.

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
    list({AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer(), RouteID :: string()}).
lookup_dev_eui(DevEUI) ->
    MS = [{{{'$1', DevEUI}, '$2'}, [], [{{'$1', DevEUI, '$2'}}]}],
    [{AppEUI, DevEUI0, stored_to_id(Stored)} || {AppEUI, DevEUI0, Stored} <- ets:select(?ETS, MS)].

-spec lookup_app_eui(AppEUI :: non_neg_integer()) ->
    list({AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer(), RouteID :: string()}).
lookup_app_eui(AppEUI) ->
    MS = [{{{AppEUI, '$1'}, '$2'}, [], [{{AppEUI, '$1', '$2'}}]}],
    [{AppEUI0, DevEUI, stored_to_id(Stored)} || {AppEUI0, DevEUI, Stored} <- ets:select(?ETS, MS)].

-spec lookup_for_route(RouteID :: hpr_route:id()) ->
    list({AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()}).
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
    MS2 = [{{'_', id_to_stored(RouteID)}, [], [true]}],
    ets:select_delete(?ETS, MS2).

-spec replace_route(RouteID :: hpr_route:id(), EUIs :: list(hpr_eui_pair:eui_pair())) ->
    non_neg_integer().
replace_route(RouteID, EUIs) ->
    Removed = ?MODULE:delete_route(RouteID),
    lists:foreach(fun ?MODULE:insert/1, EUIs),
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
    ok = maybe_migrate_v2(),
    ok.

%% v2 files hold route ids as char lists. Convert them on first boot after the
%% upgrade rather than leaning on a config resync: the route stream is
%% incremental (hpr_route_stream_worker keeps last_timestamp in dets), so an
%% empty table would only be refilled by deltas, not by the full configuration.
%% The v2 file is left in place, so rolling back is just a redeploy.
-spec maybe_migrate_v2() -> ok.
maybe_migrate_v2() ->
    DataDir = hpr_utils:base_data_dir(),
    V2File = filename:join([DataDir, ?DETS_FILENAME_V2]),
    case ets:info(?ETS, size) == 0 andalso filelib:is_regular(V2File) of
        false ->
            ok;
        true ->
            case dets:open_file(?DETS_V2, [{file, V2File}, {type, bag}, {access, read}]) of
                {ok, _} ->
                    Migrated = dets:foldl(
                        fun({EUIs, RouteID}, Cnt) ->
                            true = ets:insert(?ETS, {EUIs, id_to_stored(RouteID)}),
                            Cnt + 1
                        end,
                        0,
                        ?DETS_V2
                    ),
                    ok = dets:close(?DETS_V2),
                    ok = ?MODULE:checkpoint(),
                    lager:info("migrated ~w eui pairs from ~s", [Migrated, ?DETS_FILENAME_V2]);
                {error, _Reason} ->
                    lager:warning("failed to open ~s to migrate: ~p", [V2File, _Reason])
            end,
            ok
    end.

with_open_dets(FN) ->
    DataDir = hpr_utils:base_data_dir(),
    DETSFile = filename:join([DataDir, ?DETS_FILENAME]),
    ok = filelib:ensure_dir(DETSFile),

    case dets:open_file(?DETS, [{file, DETSFile}, {type, bag}]) of
        {ok, _Dets} ->
            lager:info("~s opened by ~p", [DETSFile, self()]),
            FN(),
            dets:close(?DETS);
        {error, Reason} ->
            Deleted = file:delete(DETSFile),
            lager:warning("failed to open dets file ~p: ~p, deleted: ~p", [?MODULE, Reason, Deleted]),
            with_open_dets(FN)
    end.
