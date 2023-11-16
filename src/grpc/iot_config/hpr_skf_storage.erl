-module(hpr_skf_storage).

-export([
    make_ets/1,
    delete_route/1,
    replace_route/2,

    insert/1,
    update/4,
    delete/1
]).

-define(ETS_SKFS, hpr_route_skfs_ets).

-define(SKF_HEIR, hpr_sup).

-spec make_ets(hpr_route:id()) -> ets:tab().
make_ets(RouteID) ->
    ets:new(?ETS_SKFS, [
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true},
        {heir, erlang:whereis(?SKF_HEIR), RouteID}
    ]).

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
            Size;
        Other ->
            lager:warning("failed to delete skf table ~p for ~s", [Other, RouteID]),
            {error, Other}
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

            ct:print("replace on ~s: ~p", [RouteID, [{old, OldSize}, {new, length(NewSKFs)}]]),
            ets:delete(OldTab),
            {ok, OldSize};
        Other ->
            {error, Other}
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

-spec skf_md(hpr_route:id(), hpr_skf:skf()) -> proplists:proplist().
skf_md(RouteID, SKF) ->
    [
        {route_id, RouteID},
        {devaddr, hpr_utils:int_to_hex_string(hpr_skf:devaddr(SKF))},
        {session_key, hpr_skf:session_key(SKF)},
        {max_copies, hpr_skf:max_copies(SKF)}
    ].
