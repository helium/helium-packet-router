-module(hpr_skf_storage).

-export([
    init_ets/0,
    make_ets/1,
    checkpoint/0,
    dets_filename/1,

    insert/1,
    delete/1,
    lookup/2,

    delete_route/1,
    clear_route/1,
    replace_route/2,
    lookup_route/1,
    count_route/1,

    delete_all/0
]).

-ifdef(TEST).
-export([
    test_delete_ets/0,
    test_register_heir/0,
    test_unregister_heir/0,
    test_size/1
]).
-endif.

-define(ETS_SKFS, hpr_route_skfs_ets).
%% Route ids whose SKF table has changed since it was last written to disk.
%% checkpoint/0 writes only these, so the periodic checkpoint costs one
%% dets:from_ets per *changed* route instead of one per route in existence.
-define(ETS_DIRTY, hpr_skf_dirty_ets).
%% Version 1: {SessionKey :: binary(), {Devaddr :: binary(), MaxCopies :: non_neg_integer()}}
%% Version 2: {{SessionKey :: binary(), Devaddr :: binary()}, MaxCopies :: non_neg_integer()}
%% Version 3: {{Devaddr :: binary(), SessionKey :: binary()}, MaxCopies :: non_neg_integer()}
%%
%% v3 exists only to put DevAddr first in the key. Every read is "the session
%% keys for this DevAddr", and on a `set' the hash covers the whole key term, so
%% a v2 lookup could not use it and full-scanned the table instead -- measured at
%% 23ms against a 137k-row route, which was the entire
%% `find_routes' cost. As an `ordered_set' keyed DevAddr-first, the bound prefix
%% restricts the traversal to that DevAddr: 0.7us for the same table.
-define(DETS_FILENAME(ROUTE_ID), io_lib:format("hpr_skf_~s_v3.dets", [ROUTE_ID])).
-define(LEGACY_DETS_FILENAME(ROUTE_ID), io_lib:format("hpr_skf_~s_v2.dets", [ROUTE_ID])).

-define(SKF_HEIR, hpr_sup).

%% @doc Create the dirty-route table, or empty it if it already exists.
%%
%% Idempotent, unlike the strict `?ETS = ets:new(...)' the sibling storage
%% modules use, because this table has no owning route to hang a teardown off:
%% eunit suites that call hpr_route_ets:init/0 per test tear down tables by name
%% and would each need updating, and a second ets:new/2 on a named table raises
%% badarg. Emptying is the right state either way -- route hydration runs right
%% after this and marks every route dirty.
-spec init_ets() -> ok.
init_ets() ->
    case ets:info(?ETS_DIRTY, name) of
        undefined ->
            ?ETS_DIRTY = ets:new(?ETS_DIRTY, [
                public,
                named_table,
                set,
                {read_concurrency, true},
                {write_concurrency, true}
            ]);
        _ ->
            true = ets:delete_all_objects(?ETS_DIRTY)
    end,
    ok.

-spec make_ets(hpr_route:id()) -> ets:tab().
make_ets(RouteID) ->
    Ref = ets:new(?ETS_SKFS, [
        public,
        %% ordered_set, not set: see the version note above. The key is
        %% {DevAddr, SessionKey} and reads bind only DevAddr, which an
        %% ordered_set can use as a range prefix and a hashed set cannot.
        ordered_set,
        {read_concurrency, true},
        {write_concurrency, true},
        {heir, erlang:whereis(?SKF_HEIR), RouteID}
    ]),

    lager:info("rehydrating SKF from dets: ~p", [RouteID]),
    ok = rehydrate_from_dets(RouteID, Ref),

    %% A table we just built is not yet known to match its file: rehydration can
    %% have found a corrupt file (with_open_dets/2 deletes and retries), and a
    %% route created after boot has no file at all. Marking it dirty makes the
    %% next checkpoint write it once, which is what used to happen every time.
    ok = mark_dirty(RouteID),

    Ref.

-spec dets_filename(Route :: hpr_route:id()) -> list().
dets_filename(RouteID) ->
    DataDir = hpr_utils:base_data_dir(),
    Filename = ?DETS_FILENAME(RouteID),
    filename:join([DataDir, Filename]).

-spec legacy_dets_filename(Route :: hpr_route:id()) -> list().
legacy_dets_filename(RouteID) ->
    DataDir = hpr_utils:base_data_dir(),
    Filename = ?LEGACY_DETS_FILENAME(RouteID),
    filename:join([DataDir, Filename]).

%% @doc Persist every route whose SKFs changed since the last checkpoint.
%%
%% Returns the number of routes written, for the caller's timing log.
%%
%% A route's dirty flag is cleared before its write, not after. SKF updates are
%% applied by processes the stream worker spawns, so they keep landing while
%% this runs; one that lands mid-write marks the route again and the next
%% checkpoint picks it up. Cleared after the write, that mark was wiped with
%% the update possibly missing from the file -- and the stored resume timestamp
%% already past it, so the stream would never send it again. A failed write
%% marks the route again, so it is retried rather than lost.
-spec checkpoint() -> non_neg_integer().
checkpoint() ->
    lists:foldl(
        fun(RouteID, Written) ->
            case hpr_route_storage:lookup(RouteID) of
                {ok, RouteETS} ->
                    ETS = hpr_route_ets:skf_ets(RouteETS),
                    %% A dangling reference (dead table) cannot be written and
                    %% will not become writable, so drop the flag rather than
                    %% retrying it forever.
                    case ets:info(ETS, size) of
                        undefined ->
                            ok = mark_clean(RouteID),
                            Written;
                        _ ->
                            ok = mark_clean(RouteID),
                            DETSFile = ?MODULE:dets_filename(RouteID),
                            try
                                with_open_dets(DETSFile, fun() ->
                                    ok = dets:from_ets(DETSFile, ETS)
                                end)
                            catch
                                Class:Reason:Stacktrace ->
                                    ok = mark_dirty(RouteID),
                                    erlang:raise(Class, Reason, Stacktrace)
                            end,
                            Written + 1
                    end;
                {error, not_found} ->
                    %% Route deleted between being marked and now.
                    ok = mark_clean(RouteID),
                    Written
            end
        end,
        0,
        dirty_route_ids()
    ).

-spec with_open_dets(Filename :: list(), Fn :: fun()) -> ok.
with_open_dets(Filename, Fn) ->
    ok = filelib:ensure_dir(Filename),
    case dets:open_file(Filename, [{type, set}]) of
        {ok, _} ->
            lager:debug("opened dets: ~s", [Filename]),
            Fn(),
            dets:close(Filename);
        {error, _Reason} ->
            Deleted = file:delete(Filename),
            lager:warning("failed to open file ~p: ~p, deleted: ~p", [Filename, _Reason, Deleted]),
            with_open_dets(Filename, Fn)
    end.

%% @doc Load a route's SKFs, migrating a v2 file in place if that is all there is.
%%
%% The config stream is incremental (it resumes from a stored timestamp), so it
%% will not re-send SKFs we already acknowledged. A fresh v3 file would therefore
%% leave every route's SKFs empty until an operator forced a refresh -- so the
%% first boot on v3 reads the v2 file and flips each key instead. The v2 file is
%% deliberately left on disk: the next checkpoint writes v3 alongside it, and
%% keeping it means a rollback still finds data.
rehydrate_from_dets(RouteID, EtsRef) ->
    Filename = ?MODULE:dets_filename(RouteID),
    case filelib:is_regular(Filename) of
        true ->
            load_dets(Filename, EtsRef, fun(Entry) -> Entry end);
        false ->
            Legacy = legacy_dets_filename(RouteID),
            case filelib:is_regular(Legacy) of
                true ->
                    lager:info("migrating SKF dets v2 to v3: ~p", [RouteID]),
                    load_dets(Legacy, EtsRef, fun v2_to_v3/1);
                false ->
                    %% Neither file exists: create an empty v3 so a live route
                    %% always has one. That used to fall out of dets:open_file/2
                    %% creating the file it was asked to read; now that the read
                    %% is conditional, do it deliberately rather than lose the
                    %% invariant (hpr_route_stream_worker_SUITE asserts it, and
                    %% route removal is what deletes the file).
                    with_open_dets(Filename, fun() -> ok end)
            end
    end.

-spec load_dets(Filename :: list(), EtsRef :: ets:table(), Fn :: fun()) -> ok.
load_dets(Filename, EtsRef, Convert) ->
    with_open_dets(Filename, fun() ->
        [] = dets:traverse(Filename, fun(Entry) ->
            true = ets:insert(EtsRef, Convert(Entry)),
            continue
        end)
    end).

-spec v2_to_v3({{binary(), non_neg_integer()}, non_neg_integer()}) ->
    {{non_neg_integer(), binary()}, non_neg_integer()}.
v2_to_v3({{SessionKey, DevAddr}, MaxCopies}) ->
    {{DevAddr, SessionKey}, MaxCopies}.

-spec lookup(ETS :: ets:table(), DevAddr :: non_neg_integer()) ->
    [{SessionKey :: binary(), MaxCopies :: non_neg_integer()}].
lookup(ETS, DevAddr) ->
    ets:select(ETS, devaddr_ms(DevAddr)).

-spec insert(SKF :: hpr_skf:skf()) -> ok.
insert(SKF) ->
    RouteID = hpr_skf:route_id(SKF),
    MD = skf_md(RouteID, SKF),
    case hpr_route_storage:lookup(RouteID) of
        {ok, RouteETS} ->
            SKFETS = hpr_route_ets:skf_ets(RouteETS),
            ok = do_insert_skf(SKFETS, SKF),
            ok = mark_dirty(RouteID),
            lager:debug(MD, "updated SKF");
        _Other ->
            lager:error(MD, "failed to insert skf table not found ~p", [
                _Other
            ])
    end,
    ok.

-spec delete(SKF :: hpr_skf:skf()) -> ok.
delete(SKF) ->
    RouteID = hpr_skf:route_id(SKF),
    case hpr_route_storage:lookup(RouteID) of
        {ok, RouteETS} ->
            DevAddr = hpr_skf:devaddr(SKF),
            SessionKey = hpr_skf:session_key(SKF),
            MaxCopies = hpr_skf:max_copies(SKF),

            SKFETS = hpr_route_ets:skf_ets(RouteETS),
            true = ets:delete(SKFETS, {DevAddr, hpr_utils:hex_to_bin(SessionKey)}),
            ok = mark_dirty(RouteID),
            lager:debug(
                [
                    {route_id, RouteID},
                    {devaddr, hpr_utils:int_to_hex_string(DevAddr)},
                    {session_key, SessionKey},
                    {max_copies, MaxCopies}
                ],
                "deleted SKF"
            );
        _Other ->
            lager:warning("failed to delete skf not found ~p for ~s", [
                _Other, RouteID
            ])
    end,
    ok.

-spec delete_all() -> ok.
delete_all() ->
    lists:foreach(
        fun(Route) ->
            SKFETS = hpr_route_ets:skf_ets(Route),
            ets:delete(SKFETS)
        end,
        hpr_route_storage:all_route_ets()
    ),
    %% Every table is gone, so there is nothing left for a checkpoint to write.
    ok = clear_dirty(),
    ok.

-ifdef(TEST).

-spec test_delete_ets() -> ok.
test_delete_ets() ->
    ok = ?MODULE:delete_all(),
    %% Destroy the named table too: init_ets/0 recreates it per test, and
    %% ets:new/2 on an existing named table raises badarg.
    _ = catch ets:delete(?ETS_DIRTY),
    ok.

-spec test_register_heir() -> true.
test_register_heir() ->
    true = erlang:register(?SKF_HEIR, self()).

-spec test_unregister_heir() -> true.
test_unregister_heir() ->
    true = erlang:unregister(?SKF_HEIR).

-spec test_size(Tab :: ets:tab()) -> non_neg_integer().
test_size(Tab) ->
    ets:info(Tab, size).

-endif.

%% -------------------------------------------------------------------
%% Route Stream Functions
%% -------------------------------------------------------------------

-spec delete_route(hpr_route:id()) -> non_neg_integer().
delete_route(RouteID) ->
    case hpr_route_storage:lookup(RouteID) of
        {ok, RouteETS} ->
            SKFETS = hpr_route_ets:skf_ets(RouteETS),
            %% The skf table can be gone already (e.g. a dangling reference left
            %% over from a partial supervisor restart). ets:info/2 returns
            %% `undefined` for a dead table, but ets:delete/1 would raise badarg,
            %% so guard it and treat a missing table as already deleted.
            Size =
                case ets:info(SKFETS, size) of
                    undefined ->
                        0;
                    S ->
                        true = ets:delete(SKFETS),
                        S
                end,
            DetsFilename = ?MODULE:dets_filename(RouteID),
            _ = file:delete(DetsFilename),
            ok = mark_clean(RouteID),
            Size;
        {error, not_found} = Err ->
            DetsFilename = ?MODULE:dets_filename(RouteID),
            Deleted = file:delete(DetsFilename),
            lager:info(
                [
                    {route_id, RouteID},
                    {deleted, Deleted},
                    {filename, DetsFilename}
                ],
                "route not found, skf file maybe deleted"
            ),
            ok = mark_clean(RouteID),
            Err
    end.

%% @doc Empty a route's SKF table in place without destroying it.
%%
%% Used when deactivating a route: the SKFs are dropped but the route record
%% (and its `skf_ets' reference) is kept. Destroying the table here would leave
%% the kept route record pointing at a dead table (a dangling reference), so we
%% clear the contents in place instead and remove the persisted DETS file.
-spec clear_route(hpr_route:id()) -> non_neg_integer().
clear_route(RouteID) ->
    case hpr_route_storage:lookup(RouteID) of
        {ok, RouteETS} ->
            SKFETS = hpr_route_ets:skf_ets(RouteETS),
            Size =
                case ets:info(SKFETS, size) of
                    undefined ->
                        0;
                    S ->
                        true = ets:delete_all_objects(SKFETS),
                        S
                end,
            _ = file:delete(?MODULE:dets_filename(RouteID)),
            ok = mark_clean(RouteID),
            Size;
        {error, not_found} ->
            _ = file:delete(?MODULE:dets_filename(RouteID)),
            ok = mark_clean(RouteID),
            0
    end.

%% @doc Replace a route's full SKF set, mutating the existing table in place.
%%
%% The `skf_ets' table reference stored in the route record is created once (at
%% route creation) and must stay valid for the route's whole lifetime. We never
%% create a new table or rewrite the record's `skf_ets' field here, otherwise a
%% concurrent read-modify-write from another process (e.g. a CLI `route sync')
%% could write back a stale reference to a table we just deleted.
%%
%% New entries are inserted/overwritten first and stale keys deleted after, so
%% the table is always a superset of the old and new sets during the update and
%% never transiently missing a currently-valid key.
-spec replace_route(hpr_route:id(), list(hpr_skf:skf())) ->
    {ok, non_neg_integer()} | {error, any()}.
replace_route(RouteID, NewSKFs) ->
    case hpr_route_storage:lookup(RouteID) of
        {ok, RouteETS} ->
            %% Recover from a pre-existing dangling reference: if the table is
            %% already gone, recreate it once. This is a controlled single-writer
            %% re-creation (replace_route only runs in the stream worker).
            {SKFETS, OldSize} =
                case ets:info(hpr_route_ets:skf_ets(RouteETS), size) of
                    undefined ->
                        Tab = hpr_skf_storage:make_ets(RouteID),
                        ok = hpr_route_storage:insert(
                            hpr_route_ets:route(RouteETS),
                            Tab,
                            hpr_route_ets:backoff(RouteETS)
                        ),
                        {Tab, 0};
                    S ->
                        {hpr_route_ets:skf_ets(RouteETS), S}
                end,

            ok = lists:foreach(fun(SKF) -> ok = do_insert_skf(SKFETS, SKF) end, NewSKFs),

            NewKeys = sets:from_list([new_skf_key(SKF) || SKF <- NewSKFs]),
            CurrentKeys = ets:select(SKFETS, [{{'$1', '_'}, [], ['$1']}]),
            lists:foreach(
                fun(Key) ->
                    case sets:is_element(Key, NewKeys) of
                        true -> ok;
                        false -> true = ets:delete(SKFETS, Key)
                    end
                end,
                CurrentKeys
            ),
            ok = mark_dirty(RouteID),
            {ok, OldSize};
        Other ->
            {error, Other}
    end.

%% @doc Every SKF on a route, as explicit tuples rather than raw ETS rows, so
%% callers do not depend on the key layout (it has changed three times).
-spec lookup_route(RouteID :: hpr_route:id()) ->
    list({DevAddr :: non_neg_integer(), SessionKey :: binary(), MaxCopies :: non_neg_integer()}).
lookup_route(RouteID) ->
    case hpr_route_storage:lookup(RouteID) of
        {ok, RouteETS} ->
            SKFETS = hpr_route_ets:skf_ets(RouteETS),
            %% Tolerate a dangling reference: ets:tab2list/1 would raise badarg
            %% on a dead table.
            case ets:info(SKFETS, size) of
                undefined ->
                    [];
                _ ->
                    [
                        {DevAddr, SessionKey, MaxCopies}
                     || {{DevAddr, SessionKey}, MaxCopies} <- ets:tab2list(SKFETS)
                    ]
            end;
        {error, not_found} ->
            []
    end.

-spec count_route(RouteID :: hpr_route:id()) -> non_neg_integer().
count_route(RouteID) ->
    case hpr_route_storage:lookup(RouteID) of
        {ok, RouteETS} ->
            SKFETS = hpr_route_ets:skf_ets(RouteETS),
            case ets:info(SKFETS, size) of
                undefined -> 0;
                Size -> Size
            end;
        {error, not_found} ->
            0
    end.

%% -------------------------------------------------------------------
%% Internal Functions
%% -------------------------------------------------------------------

%% @doc Record that a route's SKF table no longer matches its file on disk.
%%
%% Tolerates a missing dirty table so a caller is never killed by bookkeeping:
%% the table is created in init_ets/0, but eunit suites drive individual
%% functions without it. A lost mark only means a route is written one
%% checkpoint later than it could have been.
-spec mark_dirty(hpr_route:id()) -> ok.
mark_dirty(RouteID) ->
    try ets:insert(?ETS_DIRTY, {RouteID}) of
        true -> ok
    catch
        error:badarg -> ok
    end.

-spec mark_clean(hpr_route:id()) -> ok.
mark_clean(RouteID) ->
    try ets:delete(?ETS_DIRTY, RouteID) of
        true -> ok
    catch
        error:badarg -> ok
    end.

-spec clear_dirty() -> ok.
clear_dirty() ->
    try ets:delete_all_objects(?ETS_DIRTY) of
        true -> ok
    catch
        error:badarg -> ok
    end.

-spec dirty_route_ids() -> [hpr_route:id()].
dirty_route_ids() ->
    try
        [RouteID || {RouteID} <- ets:tab2list(?ETS_DIRTY)]
    catch
        error:badarg -> []
    end.

%% @doc Match every SKF for one DevAddr.
%%
%% DevAddr is bound and is the first element of the key, which is what lets an
%% ordered_set restrict the traversal to that DevAddr's range instead of walking
%% the table.
-spec devaddr_ms(DevAddr :: non_neg_integer()) -> ets:match_spec().
devaddr_ms(DevAddr) ->
    [{{{DevAddr, '$1'}, '$2'}, [], [{{'$1', '$2'}}]}].

-spec do_insert_skf(ets:table(), hpr_skf:skf()) -> ok.
do_insert_skf(SKFETS, SKF) ->
    DevAddr = hpr_skf:devaddr(SKF),
    SessionKey = hpr_skf:session_key(SKF),
    MaxCopies = hpr_skf:max_copies(SKF),
    try hpr_utils:hex_to_bin(SessionKey) of
        SessionKeyBin ->
            true = ets:insert(SKFETS, {{DevAddr, SessionKeyBin}, MaxCopies})
    catch
        _E:_R ->
            lager:warning("failed to insert ~p ~p", [{{SessionKey, DevAddr}, MaxCopies}, _R])
    end,
    ok.

%% @doc The ETS key for an SKF, matching the entry inserted by do_insert_skf/2.
%% Returns `undefined' for a malformed session key (which do_insert_skf/2 skips),
%% a harmless sentinel that never matches a real key.
-spec new_skf_key(hpr_skf:skf()) -> {non_neg_integer(), binary()} | undefined.
new_skf_key(SKF) ->
    DevAddr = hpr_skf:devaddr(SKF),
    SessionKey = hpr_skf:session_key(SKF),
    try hpr_utils:hex_to_bin(SessionKey) of
        SessionKeyBin ->
            {DevAddr, SessionKeyBin}
    catch
        _E:_R ->
            undefined
    end.

-spec skf_md(hpr_route:id(), hpr_skf:skf()) -> proplists:proplist().
skf_md(RouteID, SKF) ->
    [
        {route_id, RouteID},
        {devaddr, hpr_utils:int_to_hex_string(hpr_skf:devaddr(SKF))},
        {session_key, hpr_skf:session_key(SKF)},
        {max_copies, hpr_skf:max_copies(SKF)}
    ].
