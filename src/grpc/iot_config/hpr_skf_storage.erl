-module(hpr_skf_storage).

-export([
    make_ets/1,
    checkpoint/0,
    dets_filename/1,

    insert/1,
    update/4,
    delete/1,
    lookup/2,
    select/1, select/2,

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
%% Version 1: {SessionKey :: binary(), {Devaddr :: binary(), MaxCopies :: non_neg_integer()}}
%% Version 2: {{SessionKey :: binary(), Devaddr :: binary()}, MaxCopies :: non_neg_integer()}
-define(DETS_FILENAME(ROUTE_ID), io_lib:format("hpr_skf_~s_v2.dets", [ROUTE_ID])).

-define(SKF_HEIR, hpr_sup).

-spec make_ets(hpr_route:id()) -> ets:tab().
make_ets(RouteID) ->
    Ref = ets:new(?ETS_SKFS, [
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true},
        {heir, erlang:whereis(?SKF_HEIR), RouteID}
    ]),

    lager:info("rehydrating SKF from dets: ~p", [RouteID]),
    ok = rehydrate_from_dets(RouteID, Ref),

    Ref.

-spec dets_filename(Route :: hpr_route:id()) -> list().
dets_filename(RouteID) ->
    DataDir = hpr_utils:base_data_dir(),
    Filename = ?DETS_FILENAME(RouteID),
    filename:join([DataDir, Filename]).

-spec checkpoint() -> ok.
checkpoint() ->
    lists:foreach(
        fun(RouteETS) ->
            Route = hpr_route_ets:route(RouteETS),
            RouteID = hpr_route:id(Route),
            DETSFile = ?MODULE:dets_filename(RouteID),

            ETS = hpr_route_ets:skf_ets(RouteETS),
            with_open_dets(DETSFile, fun() -> ok = dets:from_ets(DETSFile, ETS) end)
        end,
        hpr_route_storage:all_route_ets()
    ),
    ok.

-spec with_open_dets(Filename :: list(), Fn :: fun()) -> ok.
with_open_dets(Filename, Fn) ->
    ok = filelib:ensure_dir(Filename),
    case dets:open_file(Filename, [{type, set}]) of
        {ok, _} ->
            lager:info("opened dets: ~s~n", [Filename]),
            Fn(),
            dets:close(Filename);
        {error, _Reason} ->
            Deleted = file:delete(Filename),
            lager:warning("failed to open file ~p: ~p, deleted: ~p", [Filename, _Reason, Deleted]),
            with_open_dets(Filename, Fn)
    end.

rehydrate_from_dets(RouteID, EtsRef) ->
    Filename = ?MODULE:dets_filename(RouteID),
    with_open_dets(Filename, fun() ->
        [] = dets:traverse(Filename, fun(Entry) ->
            true = ets:insert(EtsRef, Entry),
            continue
        end)
    end).

-spec lookup(ETS :: ets:table(), DevAddr :: non_neg_integer()) ->
    [{SessionKey :: binary(), MaxCopies :: non_neg_integer()}].
lookup(ETS, DevAddr) ->
    MS = [{{{'$1', DevAddr}, '$2'}, [], [{{'$1', '$2'}}]}],
    ets:select(ETS, MS).

-spec select(Continuation :: ets:continuation()) ->
    {[{binary(), string(), non_neg_integer()}], ets:continuation()} | '$end_of_table'.
select(Continuation) ->
    ets:select(Continuation).

-spec select(ETS :: ets:table(), DevAddr :: non_neg_integer() | ets:continuation()) ->
    {[{SessionKey :: binary(), MaxCopies :: non_neg_integer()}], ets:continuation()}
    | '$end_of_table'.
select(ETS, DevAddr) ->
    MS = [{{{'$1', DevAddr}, '$2'}, [], [{{'$1', '$2'}}]}],
    ets:select(ETS, MS, 100).

-spec insert(SKF :: hpr_skf:skf()) -> ok.
insert(SKF) ->
    RouteID = hpr_skf:route_id(SKF),
    MD = skf_md(RouteID, SKF),
    case hpr_route_storage:lookup(RouteID) of
        {ok, RouteETS} ->
            SKFETS = hpr_route_ets:skf_ets(RouteETS),
            ok = do_insert_skf(SKFETS, SKF),
            lager:debug(MD, "updated SKF");
        _Other ->
            lager:error(MD, "failed to insert skf table not found ~p", [
                _Other
            ])
    end,
    ok.

-spec update(
    DevAddr :: non_neg_integer(),
    SessionKey :: binary(),
    RouteID :: hpr_route:id(),
    MaxCopies :: non_neg_integer()
) -> ok.
update(DevAddr, SessionKey, RouteID, MaxCopies) ->
    SKF = hpr_skf:new(#{
        route_id => RouteID,
        devaddr => DevAddr,
        session_key => hpr_utils:bin_to_hex_string(SessionKey),
        max_copies => MaxCopies
    }),
    ok = ?MODULE:insert(SKF),
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
            true = ets:delete(SKFETS, {hpr_utils:hex_to_bin(SessionKey), DevAddr}),
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
    ok.

-ifdef(TEST).

-spec test_delete_ets() -> ok.
test_delete_ets() ->
    ?MODULE:delete_all().

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
            Size;
        {error, not_found} ->
            _ = file:delete(?MODULE:dets_filename(RouteID)),
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
            {ok, OldSize};
        Other ->
            {error, Other}
    end.

-spec lookup_route(RouteID :: hpr_route:id()) ->
    list({{SessionKey :: binary(), Devaddr :: binary()}, MaxCopies :: non_neg_integer()}).
lookup_route(RouteID) ->
    case hpr_route_storage:lookup(RouteID) of
        {ok, RouteETS} ->
            SKFETS = hpr_route_ets:skf_ets(RouteETS),
            %% Tolerate a dangling reference: ets:tab2list/1 would raise badarg
            %% on a dead table.
            case ets:info(SKFETS, size) of
                undefined -> [];
                _ -> ets:tab2list(SKFETS)
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

-spec do_insert_skf(ets:table(), hpr_skf:skf()) -> ok.
do_insert_skf(SKFETS, SKF) ->
    DevAddr = hpr_skf:devaddr(SKF),
    SessionKey = hpr_skf:session_key(SKF),
    MaxCopies = hpr_skf:max_copies(SKF),
    try hpr_utils:hex_to_bin(SessionKey) of
        SessionKeyBin ->
            true = ets:insert(SKFETS, {{SessionKeyBin, DevAddr}, MaxCopies})
    catch
        _E:_R ->
            lager:warning("failed to insert ~p ~p", [{{SessionKey, DevAddr}, MaxCopies}, _R])
    end,
    ok.

%% @doc The ETS key for an SKF, matching the entry inserted by do_insert_skf/2.
%% Returns `undefined' for a malformed session key (which do_insert_skf/2 skips),
%% a harmless sentinel that never matches a real key.
-spec new_skf_key(hpr_skf:skf()) -> {binary(), non_neg_integer()} | undefined.
new_skf_key(SKF) ->
    DevAddr = hpr_skf:devaddr(SKF),
    SessionKey = hpr_skf:session_key(SKF),
    try hpr_utils:hex_to_bin(SessionKey) of
        SessionKeyBin ->
            {SessionKeyBin, DevAddr}
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
