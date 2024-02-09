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
-define(DETS_FILENAME(ROUTE_ID), io_lib:format("hpr_skf_~s.dets", [ROUTE_ID])).

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
        [] = dets:traverse(Filename, fun(SKF) ->
            ok = do_rehydrate_insert_skf(EtsRef, SKF),
            continue
        end)
    end).

-spec lookup(ETS :: ets:table(), DevAddr :: non_neg_integer()) ->
    [{SessionKey :: binary(), MaxCopies :: non_neg_integer()}].
lookup(ETS, DevAddr) ->
    MS = [{{'$1', {DevAddr, '$2'}}, [], [{{'$1', '$2'}}]}],
    ets:select(ETS, MS).

-spec select(Continuation :: ets:continuation()) ->
    {[{binary(), string(), non_neg_integer()}], ets:continuation()} | '$end_of_table'.
select(Continuation) ->
    ets:select(Continuation).

-spec select(ETS :: ets:table(), DevAddr :: non_neg_integer() | ets:continuation()) ->
    {[{SessionKey :: binary(), MaxCopies :: non_neg_integer()}], ets:continuation()}
    | '$end_of_table'.
select(ETS, DevAddr) ->
    MS = [{{'$1', {DevAddr, '$2'}}, [], [{{'$1', '$2'}}]}],
    ets:select(ETS, MS, 100).

-spec insert(SKF :: hpr_skf:skf()) -> ok.
insert(SKF) ->
    RouteID = hpr_skf:route_id(SKF),
    MD = skf_md(RouteID, SKF),
    case hpr_route_storage:lookup(RouteID) of
        {ok, RouteETS} ->
            SKFETS = hpr_route_ets:skf_ets(RouteETS),
            do_insert_skf(SKFETS, SKF),
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
            true = ets:delete(SKFETS, hpr_utils:hex_to_bin(SessionKey)),
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
            Size = ets:info(SKFETS, size),
            ets:delete(SKFETS),
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

-spec replace_route(hpr_route:id(), list(hpr_skf:skf())) ->
    {ok, non_neg_integer()} | {error, any()}.
replace_route(RouteID, NewSKFs) ->
    case hpr_route_storage:lookup(RouteID) of
        {ok, RouteETS} ->
            OldTab = hpr_route_ets:skf_ets(RouteETS),
            NewTab = make_ets(RouteID),
            lists:foreach(fun(SKF) -> do_insert_skf(NewTab, SKF) end, NewSKFs),

            ok = hpr_route_storage:insert(
                hpr_route_ets:route(RouteETS),
                NewTab,
                hpr_route_ets:backoff(RouteETS)
            ),

            OldSize = ets:info(OldTab, size),

            ets:delete(OldTab),
            {ok, OldSize};
        Other ->
            {error, Other}
    end.

-spec lookup_route(RouteID :: hpr_route:id()) ->
    list({SessionKey :: binary(), {Devaddr :: binary(), MaxCopies :: non_neg_integer()}}).
lookup_route(RouteID) ->
    case hpr_route_storage:lookup(RouteID) of
        {ok, RouteETS} ->
            SKFETS = hpr_route_ets:skf_ets(RouteETS),
            ets:tab2list(SKFETS);
        {error, not_found} ->
            []
    end.

-spec count_route(RouteID :: hpr_route:id()) -> non_neg_integer().
count_route(RouteID) ->
    case hpr_route_storage:lookup(RouteID) of
        {ok, RouteETS} ->
            SKFETS = hpr_route_ets:skf_ets(RouteETS),
            ets:info(SKFETS, size);
        {error, not_found} ->
            []
    end.

%% -------------------------------------------------------------------
%% Internal Functions
%% -------------------------------------------------------------------

-spec do_insert_skf(ets:table(), hpr_skf:skf()) -> ok.
do_insert_skf(SKFETS, SKF) ->
    DevAddr = hpr_skf:devaddr(SKF),
    SessionKey = hpr_skf:session_key(SKF),
    MaxCopies = hpr_skf:max_copies(SKF),

    true = ets:insert(SKFETS, {hpr_utils:hex_to_bin(SessionKey), {DevAddr, MaxCopies}}),
    ok.

-spec do_rehydrate_insert_skf(
    Table :: ets:table(),
    Entry :: {SessionKey :: binary(), {DevAddr :: binary(), MaxCopies :: non_neg_integer()}}
) -> ok.
do_rehydrate_insert_skf(SKFETS, SKF) ->
    true = ets:insert(SKFETS, SKF),
    ok.

-spec skf_md(hpr_route:id(), hpr_skf:skf()) -> proplists:proplist().
skf_md(RouteID, SKF) ->
    [
        {route_id, RouteID},
        {devaddr, hpr_utils:int_to_hex_string(hpr_skf:devaddr(SKF))},
        {session_key, hpr_skf:session_key(SKF)},
        {max_copies, hpr_skf:max_copies(SKF)}
    ].
