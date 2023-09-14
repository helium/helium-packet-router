-module(hpr_route_ets).

-export([
    init/0,

    route/1,
    skf_ets/1,
    backoff/1,
    update_backoff/2,
    inc_backoff/1,
    reset_backoff/1,

    insert_route/1, insert_route/2, insert_route/3,
    delete_route/1,
    lookup_route/1,

    insert_eui_pair/1,
    delete_eui_pair/1,
    lookup_eui_pair/2,

    insert_devaddr_range/1,
    delete_devaddr_range/1,
    lookup_devaddr_range/1,

    insert_skf/1,
    insert_new_skf/1,
    update_skf/4,
    delete_skf/1,
    lookup_skf/2,
    select_skf/1, select_skf/2,

    delete_all/0
]).

%% Route Stream helpers
-export([
    delete_route_devaddrs/1,
    replace_route_devaddrs/2,
    delete_route_euis/1,
    replace_route_euis/2,
    delete_route_skfs/1,
    replace_route_skfs/2
]).

%% CLI exports
-export([
    all_routes/0,
    all_route_ets/0,
    oui_routes/1,
    eui_pairs_for_route/1,
    eui_pairs_count_for_route/1,
    lookup_dev_eui/1,
    lookup_app_eui/1,
    devaddr_ranges_for_route/1,
    devaddr_ranges_count_for_route/1,
    skfs_for_route/1,
    skfs_count_for_route/1
]).

-define(ETS_ROUTES, hpr_routes_ets).
-define(ETS_EUI_PAIRS, hpr_route_eui_pairs_ets).
-define(ETS_DEVADDR_RANGES, hpr_route_devaddr_ranges_ets).
-define(ETS_SKFS, hpr_route_skfs_ets).

-define(SKF_HEIR, hpr_sup).

-define(BACKOFF_MIN, timer:seconds(1)).
-define(BACKOFF_MAX, timer:minutes(15)).

-record(hpr_route_ets, {
    id :: hpr_route:id(),
    route :: hpr_route:route(),
    skf_ets :: ets:tid(),
    backoff :: backoff()
}).

-type backoff() :: undefined | {non_neg_integer(), backoff:backoff()}.
-type route() :: #hpr_route_ets{}.

-export_type([route/0, backoff/0]).

-spec init() -> ok.
init() ->
    ?ETS_ROUTES = ets:new(?ETS_ROUTES, [
        public, named_table, set, {keypos, #hpr_route_ets.id}, {read_concurrency, true}
    ]),
    ?ETS_DEVADDR_RANGES = ets:new(?ETS_DEVADDR_RANGES, [
        public, named_table, bag, {read_concurrency, true}
    ]),
    ?ETS_EUI_PAIRS = ets:new(?ETS_EUI_PAIRS, [public, named_table, bag, {read_concurrency, true}]),
    ok.

-spec make_skf_ets(hpr_route:id()) -> ets:tab().
make_skf_ets(RouteID) ->
    ets:new(?ETS_SKFS, [
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true},
        {heir, erlang:whereis(?SKF_HEIR), RouteID}
    ]).

-spec route(RouteETS :: route()) -> hpr_route:route().
route(RouteETS) ->
    RouteETS#hpr_route_ets.route.

-spec skf_ets(RouteETS :: route()) -> ets:table().
skf_ets(RouteETS) ->
    RouteETS#hpr_route_ets.skf_ets.

-spec backoff(RouteETS :: route()) -> backoff().
backoff(RouteETS) ->
    RouteETS#hpr_route_ets.backoff.

-spec inc_backoff(RouteID :: hpr_route:id()) -> ok.
inc_backoff(RouteID) ->
    Now = erlang:system_time(millisecond),
    case ?MODULE:lookup_route(RouteID) of
        [#hpr_route_ets{backoff = undefined}] ->
            Backoff = backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX),
            Delay = backoff:get(Backoff),
            ?MODULE:update_backoff(RouteID, {Now + Delay, Backoff});
        [#hpr_route_ets{backoff = {_, Backoff0}}] ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            ?MODULE:update_backoff(RouteID, {Now + Delay, Backoff1});
        _Other ->
            ok
    end.

-spec reset_backoff(RouteID :: hpr_route:id()) -> ok.
reset_backoff(RouteID) ->
    case ?MODULE:lookup_route(RouteID) of
        [#hpr_route_ets{backoff = undefined}] ->
            ok;
        [#hpr_route_ets{backoff = _}] ->
            ?MODULE:update_backoff(RouteID, undefined);
        _Other ->
            ok
    end.

-spec update_backoff(RouteID :: hpr_route:id(), Backoff :: backoff()) -> ok.
update_backoff(RouteID, Backoff) ->
    true = ets:update_element(?ETS_ROUTES, RouteID, {5, Backoff}),
    ok.

-spec insert_route(Route :: hpr_route:route()) -> ok.
insert_route(Route) ->
    RouteID = hpr_route:id(Route),
    SKFETS =
        case ?MODULE:lookup_route(RouteID) of
            [#hpr_route_ets{skf_ets = ETS}] ->
                ETS;
            _Other ->
                make_skf_ets(RouteID)
        end,
    ?MODULE:insert_route(Route, SKFETS).

-spec insert_route(Route :: hpr_route:route(), SKFETS :: ets:table()) -> ok.
insert_route(Route, SKFETS) ->
    ?MODULE:insert_route(Route, SKFETS, undefined).

-spec insert_route(Route :: hpr_route:route(), SKFETS :: ets:table(), Backoff :: backoff()) -> ok.
insert_route(Route, SKFETS, Backoff) ->
    RouteID = hpr_route:id(Route),
    RouteETS = #hpr_route_ets{
        id = RouteID,
        route = Route,
        skf_ets = SKFETS,
        backoff = Backoff
    },
    true = ets:insert(?ETS_ROUTES, RouteETS),
    Server = hpr_route:server(Route),
    RouteFields = [
        {id, RouteID},
        {net_id, hpr_utils:net_id_display(hpr_route:net_id(Route))},
        {oui, hpr_route:oui(Route)},
        {protocol, hpr_route:protocol_type(Server)},
        {max_copies, hpr_route:max_copies(Route)},
        {active, hpr_route:active(Route)},
        {locked, hpr_route:locked(Route)},
        {ignore_empty_skf, hpr_route:ignore_empty_skf(Route)},
        {skf_ets, SKFETS},
        {backoff, Backoff}
    ],
    lager:info(RouteFields, "inserting route"),
    ok.

-spec delete_route(Route :: hpr_route:route()) -> ok.
delete_route(Route) ->
    RouteID = hpr_route:id(Route),
    DevAddrEntries = ?MODULE:delete_route_devaddrs(RouteID),
    EUIsEntries = ?MODULE:delete_route_euis(RouteID),
    SKFEntries = ?MODULE:delete_route_skfs(RouteID),

    true = ets:delete(?ETS_ROUTES, RouteID),
    lager:info(
        [{devaddr, DevAddrEntries}, {euis, EUIsEntries}, {skfs, SKFEntries}, {route_id, RouteID}],
        "route deleted"
    ),
    ok.

-spec lookup_route(ID :: hpr_route:id()) -> [route()].
lookup_route(ID) ->
    ets:lookup(?ETS_ROUTES, ID).

-spec insert_eui_pair(EUIPair :: hpr_eui_pair:eui_pair()) -> ok.
insert_eui_pair(EUIPair) ->
    true = ets:insert(?ETS_EUI_PAIRS, [
        {
            {hpr_eui_pair:app_eui(EUIPair), hpr_eui_pair:dev_eui(EUIPair)},
            hpr_eui_pair:route_id(EUIPair)
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

-spec delete_eui_pair(EUIPair :: hpr_eui_pair:eui_pair()) -> ok.
delete_eui_pair(EUIPair) ->
    true = ets:delete_object(?ETS_EUI_PAIRS, {
        {hpr_eui_pair:app_eui(EUIPair), hpr_eui_pair:dev_eui(EUIPair)},
        hpr_eui_pair:route_id(EUIPair)
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

-spec lookup_eui_pair(AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()) ->
    [route()].
lookup_eui_pair(AppEUI, 0) ->
    EUIPairs = ets:lookup(?ETS_EUI_PAIRS, {AppEUI, 0}),
    lists:flatten([
        ?MODULE:lookup_route(RouteID)
     || {_, RouteID} <- EUIPairs
    ]);
lookup_eui_pair(AppEUI, DevEUI) ->
    EUIPairs = ets:lookup(?ETS_EUI_PAIRS, {AppEUI, DevEUI}),
    lists:usort(
        lists:flatten([
            ?MODULE:lookup_route(RouteID)
         || {_, RouteID} <- EUIPairs
        ]) ++ lookup_eui_pair(AppEUI, 0)
    ).

-spec insert_devaddr_range(DevAddrRange :: hpr_devaddr_range:devaddr_range()) -> ok.
insert_devaddr_range(DevAddrRange) ->
    true = ets:insert(?ETS_DEVADDR_RANGES, [
        {
            {hpr_devaddr_range:start_addr(DevAddrRange), hpr_devaddr_range:end_addr(DevAddrRange)},
            hpr_devaddr_range:route_id(DevAddrRange)
        }
    ]),
    lager:debug(
        [
            {start_addr, hpr_utils:int_to_hex_string(hpr_devaddr_range:start_addr(DevAddrRange))},
            {end_addr, hpr_utils:int_to_hex_string(hpr_devaddr_range:end_addr(DevAddrRange))},
            {route_id, hpr_devaddr_range:route_id(DevAddrRange)}
        ],
        "inserted devaddr range"
    ),
    ok.

-spec delete_devaddr_range(DevAddrRange :: hpr_devaddr_range:devaddr_range()) -> ok.
delete_devaddr_range(DevAddrRange) ->
    true = ets:delete_object(?ETS_DEVADDR_RANGES, {
        {hpr_devaddr_range:start_addr(DevAddrRange), hpr_devaddr_range:end_addr(DevAddrRange)},
        hpr_devaddr_range:route_id(DevAddrRange)
    }),
    lager:debug(
        [
            {start_addr, hpr_utils:int_to_hex_string(hpr_devaddr_range:start_addr(DevAddrRange))},
            {end_addr, hpr_utils:int_to_hex_string(hpr_devaddr_range:end_addr(DevAddrRange))},
            {route_id, hpr_devaddr_range:route_id(DevAddrRange)}
        ],
        "deleted devaddr range"
    ),
    ok.

-spec lookup_devaddr_range(DevAddr :: non_neg_integer()) -> [route()].
lookup_devaddr_range(DevAddr) ->
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
            ?MODULE:lookup_route(RouteID)
         || RouteID <- RouteIDs
        ])
    ).

-spec insert_skf(SKF :: hpr_skf:skf()) -> ok.
insert_skf(SKF) ->
    RouteID = hpr_skf:route_id(SKF),
    MD = skf_md(RouteID, SKF),
    case ?MODULE:lookup_route(RouteID) of
        [#hpr_route_ets{skf_ets = SKFETS}] ->
            do_insert_skf(SKFETS, SKF),
            lager:debug(MD, "updated SKF");
        _Other ->
            lager:error(MD, "failed to insert skf table not found ~p", [
                _Other
            ])
    end,
    ok.

-spec insert_new_skf(SKF :: hpr_skf:skf()) -> ok.
insert_new_skf(SKF) ->
    RouteID = hpr_skf:route_id(SKF),
    MD = skf_md(RouteID, SKF),
    case ?MODULE:lookup_route(RouteID) of
        [#hpr_route_ets{skf_ets = SKFETS}] ->
            do_insert_skf(SKFETS, SKF),
            lager:debug(MD, "inserted SKF");
        _Other ->
            lager:error(MD, "failed to insert new skf, tabl not found ~p", [
                _Other
            ])
    end,
    ok.

-spec update_skf(
    DevAddr :: non_neg_integer(),
    SessionKey :: binary(),
    RouteID :: hpr_route:id(),
    MaxCopies :: non_neg_integer()
) -> ok.
update_skf(DevAddr, SessionKey, RouteID, MaxCopies) ->
    SKF = hpr_skf:new(#{
        route_id => RouteID,
        devaddr => DevAddr,
        session_key => hpr_utils:bin_to_hex_string(SessionKey),
        max_copies => MaxCopies
    }),
    ok = insert_skf(SKF),
    ok.

-spec delete_skf(SKF :: hpr_skf:skf()) -> ok.
delete_skf(SKF) ->
    RouteID = hpr_skf:route_id(SKF),
    case ?MODULE:lookup_route(RouteID) of
        [#hpr_route_ets{skf_ets = SKFETS}] ->
            DevAddr = hpr_skf:devaddr(SKF),
            SessionKey = hpr_skf:session_key(SKF),
            MaxCopies = hpr_skf:max_copies(SKF),
            %% Here we ignore max_copies
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

-spec lookup_skf(ETS :: ets:table(), DevAddr :: non_neg_integer()) ->
    [{SessionKey :: binary(), MaxCopies :: non_neg_integer()}].
lookup_skf(ETS, DevAddr) ->
    MS = [{{'$1', {DevAddr, '$2'}}, [], [{{'$1', '$2'}}]}],
    ets:select(ETS, MS).

-spec select_skf(Continuation :: ets:continuation()) ->
    {[{binary(), string(), non_neg_integer()}], ets:continuation()} | '$end_of_table'.
select_skf(Continuation) ->
    ets:select(Continuation).

-spec select_skf(ETS :: ets:table(), DevAddr :: non_neg_integer() | ets:continuation()) ->
    {[{SessionKey :: binary(), MaxCopies :: non_neg_integer()}], ets:continuation()}
    | '$end_of_table'.
select_skf(ETS, DevAddr) ->
    MS = [{{'$1', {DevAddr, '$2'}}, [], [{{'$1', '$2'}}]}],
    ets:select(ETS, MS, 100).

-spec delete_all() -> ok.
delete_all() ->
    ets:delete_all_objects(?ETS_DEVADDR_RANGES),
    ets:delete_all_objects(?ETS_EUI_PAIRS),
    lists:foreach(
        fun(#hpr_route_ets{skf_ets = SKFETS}) ->
            ets:delete(SKFETS)
        end,
        ets:tab2list(?ETS_ROUTES)
    ),
    ets:delete_all_objects(?ETS_ROUTES),
    ok.

%% ------------------------------------------------------------------
%% Route Stream Helpers
%% ------------------------------------------------------------------

-spec delete_route_devaddrs(hpr_route:id()) -> non_neg_integer().
delete_route_devaddrs(RouteID) ->
    MS1 = [{{'_', RouteID}, [], [true]}],
    ets:select_delete(?ETS_DEVADDR_RANGES, MS1).

-spec delete_route_euis(hpr_route:id()) -> non_neg_integer().
delete_route_euis(RouteID) ->
    MS2 = [{{'_', RouteID}, [], [true]}],
    ets:select_delete(?ETS_EUI_PAIRS, MS2).

-spec delete_route_skfs(hpr_route:id()) -> non_neg_integer().
delete_route_skfs(RouteID) ->
    case ?MODULE:lookup_route(RouteID) of
        [#hpr_route_ets{skf_ets = SKFETS}] ->
            Size = ets:info(SKFETS, size),
            ets:delete(SKFETS),
            Size;
        Other ->
            lager:warning("failed to delete skf table ~p for ~s", [Other, RouteID]),
            {error, Other}
    end.

-spec replace_route_euis(
    RouteID :: hpr_route:id(),
    EUIs :: list(hpr_eui_pair:eui_pair())
) -> non_neg_integer().
replace_route_euis(RouteID, EUIs) ->
    Removed = ?MODULE:delete_route_euis(RouteID),
    lists:foreach(fun insert_eui_pair/1, EUIs),
    Removed.

-spec replace_route_devaddrs(
    RouteID :: hpr_route:id(),
    DevAddrRanges :: list(hpr_devaddr_range:devaddr_range())
) -> non_neg_integer().
replace_route_devaddrs(RouteID, DevAddrRanges) ->
    Removed = ?MODULE:delete_route_devaddrs(RouteID),
    lists:foreach(fun insert_devaddr_range/1, DevAddrRanges),
    Removed.

-spec replace_route_skfs(hpr_route:id(), list(hpr_skf:skf())) ->
    {ok, non_neg_integer()} | {error, any()}.
replace_route_skfs(RouteID, NewSKFs) ->
    case ?MODULE:lookup_route(RouteID) of
        [#hpr_route_ets{skf_ets = OldTab} = Route] ->
            NewTab = make_skf_ets(RouteID),
            lists:foreach(fun(SKF) -> do_insert_skf(NewTab, SKF) end, NewSKFs),
            true = ets:insert(?ETS_ROUTES, Route#hpr_route_ets{skf_ets = NewTab}),

            OldSize = ets:info(OldTab, size),
            ets:delete(OldTab),
            {ok, OldSize};
        Other ->
            {error, Other}
    end.

%% ------------------------------------------------------------------
%% CLI Functions
%% ------------------------------------------------------------------

-spec all_routes() -> list(hpr_route:route()).
all_routes() ->
    [hpr_route_ets:route(R) || R <- ets:tab2list(?ETS_ROUTES)].

-spec all_route_ets() -> list(route()).
all_route_ets() ->
    ets:tab2list(?ETS_ROUTES).

-spec oui_routes(OUI :: non_neg_integer()) -> list(route()).
oui_routes(OUI) ->
    [
        RouteETS
     || RouteETS <- ets:tab2list(?ETS_ROUTES), OUI == hpr_route:oui(?MODULE:route(RouteETS))
    ].

-spec lookup_dev_eui(DevEUI :: non_neg_integer()) ->
    list({AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()}).
lookup_dev_eui(DevEUI) ->
    MS = [{{{'$1', DevEUI}, '_'}, [], [{{'$1', DevEUI}}]}],
    ets:select(?ETS_EUI_PAIRS, MS).

-spec lookup_app_eui(AppEUI :: non_neg_integer()) ->
    list({AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()}).
lookup_app_eui(AppEUI) ->
    MS = [{{{AppEUI, '$1'}, '_'}, [], [{{AppEUI, '$1'}}]}],
    ets:select(?ETS_EUI_PAIRS, MS).

-spec eui_pairs_for_route(RouteID :: hpr_route:id()) ->
    list({AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()}).
eui_pairs_for_route(RouteID) ->
    MS = [{{{'$1', '$2'}, RouteID}, [], [{{'$1', '$2'}}]}],
    ets:select(?ETS_EUI_PAIRS, MS).

-spec eui_pairs_count_for_route(RouteID :: hpr_route:id()) -> non_neg_integer().
eui_pairs_count_for_route(RouteID) ->
    MS = [{{'_', RouteID}, [], [true]}],
    ets:select_count(?ETS_EUI_PAIRS, MS).

-spec devaddr_ranges_for_route(RouteID :: hpr_route:id()) ->
    list({non_neg_integer(), non_neg_integer()}).
devaddr_ranges_for_route(RouteID) ->
    MS = [{{{'$1', '$2'}, RouteID}, [], [{{'$1', '$2'}}]}],
    ets:select(?ETS_DEVADDR_RANGES, MS).

-spec devaddr_ranges_count_for_route(RouteID :: hpr_route:id()) -> non_neg_integer().
devaddr_ranges_count_for_route(RouteID) ->
    MS = [{{'_', RouteID}, [], [true]}],
    ets:select_count(?ETS_DEVADDR_RANGES, MS).

-spec skfs_for_route(RouteID :: hpr_route:id()) ->
    list({
        Key :: {Timestamp :: integer(), SessionKey :: binary()},
        Vals :: {Devaddr :: non_neg_integer(), MaxCopies :: non_neg_integer()}
    }).
skfs_for_route(RouteID) ->
    case ?MODULE:lookup_route(RouteID) of
        [#hpr_route_ets{skf_ets = SKFETS}] ->
            ets:tab2list(SKFETS);
        _Other ->
            []
    end.

-spec skfs_count_for_route(RouteID :: hpr_route:id()) -> non_neg_integer().
skfs_count_for_route(RouteID) ->
    case ?MODULE:lookup_route(RouteID) of
        [#hpr_route_ets{skf_ets = SKFETS}] ->
            ets:info(SKFETS, size);
        _Other ->
            0
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

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

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        ?_test(test_route()),
        ?_test(test_eui_pair()),
        ?_test(test_devaddr_range()),
        ?_test(test_skf()),
        ?_test(test_select_skf()),
        ?_test(test_delete_route()),
        ?_test(test_delete_all())
    ]}.

foreach_setup() ->
    true = erlang:register(?SKF_HEIR, self()),
    ?MODULE:init(),
    ok.

foreach_cleanup(ok) ->
    ets:delete(?ETS_DEVADDR_RANGES),
    ets:delete(?ETS_EUI_PAIRS),
    lists:foreach(
        fun(#hpr_route_ets{skf_ets = SKFETS}) ->
            ets:delete(SKFETS)
        end,
        ets:tab2list(?ETS_ROUTES)
    ),
    ets:delete(?ETS_ROUTES),
    true = erlang:unregister(?SKF_HEIR),
    ok.

test_route() ->
    Route0 = hpr_route:test_new(#{
        id => "11ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    RouteID = hpr_route:id(Route0),

    %% Create
    ?assertEqual(ok, ?MODULE:insert_route(Route0)),
    [RouteETS0] = ?MODULE:lookup_route(RouteID),
    ?assertEqual(RouteID, RouteETS0#hpr_route_ets.id),
    ?assertEqual(Route0, ?MODULE:route(RouteETS0)),
    SKFETS0 = ?MODULE:skf_ets(RouteETS0),
    ?assert(erlang:is_reference(SKFETS0)),
    ?assert(erlang:is_list(ets:info(SKFETS0))),
    ?assertEqual(undefined, ?MODULE:backoff(RouteETS0)),

    %% Update
    Route1 = hpr_route:test_new(#{
        id => RouteID,
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.update_domain.com",
            port => 432,
            protocol => {http_roaming, #{}}
        },
        max_copies => 22
    }),
    ?assertEqual(ok, ?MODULE:insert_route(Route1)),
    [RouteETS1] = ?MODULE:lookup_route(RouteID),
    ?assertEqual(RouteID, RouteETS1#hpr_route_ets.id),
    ?assertEqual(Route1, ?MODULE:route(RouteETS1)),
    SKFETS1 = ?MODULE:skf_ets(RouteETS0),
    ?assert(erlang:is_reference(SKFETS1)),
    ?assert(erlang:is_list(ets:info(SKFETS1))),
    ?assertEqual(SKFETS0, SKFETS1),
    ?assertEqual(undefined, ?MODULE:backoff(RouteETS1)),

    Backoff = {erlang:system_time(millisecond), backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX)},
    ?assertEqual(ok, ?MODULE:update_backoff(RouteID, Backoff)),
    [RouteETS2] = ?MODULE:lookup_route(RouteID),
    ?assertEqual(Backoff, ?MODULE:backoff(RouteETS2)),

    %% Delete
    ?assertEqual(ok, ?MODULE:delete_route(Route1)),
    ?assertEqual([], ?MODULE:lookup_route(RouteID)),
    ?assertEqual(undefined, ets:info(SKFETS1)),
    ok.

test_eui_pair() ->
    Route1 = hpr_route:test_new(#{
        id => "11ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    Route2 = hpr_route:test_new(#{
        id => "12345678a-3dce-4106-8980-d34007ab689b",
        net_id => 1,
        oui => 2,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    RouteID1 = hpr_route:id(Route1),
    RouteID2 = hpr_route:id(Route2),
    EUIPair1 = hpr_eui_pair:test_new(#{route_id => RouteID1, app_eui => 1, dev_eui => 1}),
    EUIPair2 = hpr_eui_pair:test_new(#{route_id => RouteID1, app_eui => 2, dev_eui => 0}),
    EUIPair3 = hpr_eui_pair:test_new(#{route_id => RouteID2, app_eui => 2, dev_eui => 2}),

    ?assertEqual(ok, ?MODULE:insert_route(Route1)),
    ?assertEqual(ok, ?MODULE:insert_route(Route2)),

    ?assertEqual(ok, ?MODULE:insert_eui_pair(EUIPair1)),
    ?assertEqual(ok, ?MODULE:insert_eui_pair(EUIPair2)),
    ?assertEqual(ok, ?MODULE:insert_eui_pair(EUIPair3)),

    [RouteETS1] = ?MODULE:lookup_eui_pair(1, 1),
    ?assertEqual(Route1, ?MODULE:route(RouteETS1)),
    ?assertEqual([], ?MODULE:lookup_eui_pair(1, 2)),
    [RouteETS2] = ?MODULE:lookup_eui_pair(2, 1),
    ?assertEqual(Route1, ?MODULE:route(RouteETS2)),
    [RouteETS3, RouteETS4] = ?MODULE:lookup_eui_pair(2, 2),

    ?assertEqual(Route1, ?MODULE:route(RouteETS3)),
    ?assertEqual(Route2, ?MODULE:route(RouteETS4)),

    EUIPair4 = hpr_eui_pair:test_new(#{route_id => RouteID1, app_eui => 1, dev_eui => 0}),
    ?assertEqual(ok, ?MODULE:insert_eui_pair(EUIPair4)),
    [RouteETS5] = ?MODULE:lookup_eui_pair(1, 1),
    ?assertEqual(Route1, ?MODULE:route(RouteETS5)),
    ?assertEqual(ok, ?MODULE:delete_eui_pair(EUIPair1)),
    [RouteETS6] = ?MODULE:lookup_eui_pair(1, 1),

    ?assertEqual(Route1, ?MODULE:route(RouteETS6)),
    ?assertEqual(ok, ?MODULE:delete_eui_pair(EUIPair4)),
    ?assertEqual([], ?MODULE:lookup_eui_pair(1, 1)),

    ?assertEqual(ok, ?MODULE:delete_eui_pair(EUIPair2)),
    ?assertEqual(ok, ?MODULE:delete_eui_pair(EUIPair3)),
    ?assertEqual([], ?MODULE:lookup_eui_pair(2, 1)),
    ?assertEqual([], ?MODULE:lookup_eui_pair(2, 2)),

    ok.

test_devaddr_range() ->
    Route1 = hpr_route:test_new(#{
        id => "11ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    Route2 = hpr_route:test_new(#{
        id => "12345678a-3dce-4106-8980-d34007ab689b",
        net_id => 1,
        oui => 2,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    RouteID1 = hpr_route:id(Route1),
    RouteID2 = hpr_route:id(Route2),
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000001, end_addr => 16#0000000A
    }),
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => RouteID2, start_addr => 16#00000010, end_addr => 16#0000001A
    }),
    DevAddrRange3 = hpr_devaddr_range:test_new(#{
        route_id => RouteID2, start_addr => 16#00000001, end_addr => 16#00000003
    }),

    ?assertEqual(ok, ?MODULE:insert_route(Route1)),
    ?assertEqual(ok, ?MODULE:insert_route(Route2)),
    ?assertEqual(ok, ?MODULE:insert_devaddr_range(DevAddrRange1)),
    ?assertEqual(ok, ?MODULE:insert_devaddr_range(DevAddrRange2)),
    ?assertEqual(ok, ?MODULE:insert_devaddr_range(DevAddrRange3)),

    [RouteETS1] = ?MODULE:lookup_devaddr_range(16#00000005),
    ?assertEqual(Route1, ?MODULE:route(RouteETS1)),
    [RouteETS2] = ?MODULE:lookup_devaddr_range(16#00000010),
    ?assertEqual(Route2, ?MODULE:route(RouteETS2)),
    [RouteETS3] = ?MODULE:lookup_devaddr_range(16#0000001A),
    ?assertEqual(Route2, ?MODULE:route(RouteETS3)),
    [RouteETS4, RouteETS5] = ?MODULE:lookup_devaddr_range(16#00000002),
    ?assertEqual(Route1, ?MODULE:route(RouteETS4)),
    ?assertEqual(Route2, ?MODULE:route(RouteETS5)),

    ?assertEqual(
        ok, ?MODULE:delete_devaddr_range(DevAddrRange1)
    ),
    ?assertEqual([], ?MODULE:lookup_devaddr_range(16#00000005)),
    [RouteETS6] = ?MODULE:lookup_devaddr_range(16#00000002),
    ?assertEqual(Route2, ?MODULE:route(RouteETS6)),

    ?assertEqual(ok, ?MODULE:delete_devaddr_range(DevAddrRange2)),
    ?assertEqual([], ?MODULE:lookup_devaddr_range(16#00000010)),
    ?assertEqual([], ?MODULE:lookup_devaddr_range(16#0000001A)),

    ?assertEqual(ok, ?MODULE:delete_devaddr_range(DevAddrRange3)),
    ?assertEqual([], ?MODULE:lookup_devaddr_range(16#00000002)),

    ok.

test_skf() ->
    Route1 = hpr_route:test_new(#{
        id => "11ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 10
    }),
    Route2 = hpr_route:test_new(#{
        id => "12345678a-3dce-4106-8980-d34007ab689b",
        net_id => 1,
        oui => 2,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 20
    }),
    RouteID1 = hpr_route:id(Route1),
    RouteID2 = hpr_route:id(Route2),

    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000001, end_addr => 16#0000000A
    }),
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => RouteID2, start_addr => 16#00000010, end_addr => 16#0000001A
    }),

    DevAddr1 = 16#00000001,
    SessionKey1 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SKF1 = hpr_skf:new(#{
        route_id => RouteID1, devaddr => DevAddr1, session_key => SessionKey1, max_copies => 1
    }),
    DevAddr2 = 16#00000010,
    SessionKey2 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SKF2 = hpr_skf:new(#{
        route_id => RouteID2, devaddr => DevAddr2, session_key => SessionKey2, max_copies => 2
    }),

    ?assertEqual(ok, ?MODULE:insert_route(Route1)),
    ?assertEqual(ok, ?MODULE:insert_route(Route2)),
    ?assertEqual(ok, ?MODULE:insert_devaddr_range(DevAddrRange1)),
    ?assertEqual(ok, ?MODULE:insert_devaddr_range(DevAddrRange2)),
    ?assertEqual(ok, ?MODULE:insert_skf(SKF1)),
    ?assertEqual(ok, ?MODULE:insert_skf(SKF2)),

    [RouteETS1] = ?MODULE:lookup_route(RouteID1),
    [RouteETS2] = ?MODULE:lookup_route(RouteID2),
    SKFETS1 = ?MODULE:skf_ets(RouteETS1),
    SKFETS2 = ?MODULE:skf_ets(RouteETS2),

    SK1 = hpr_utils:hex_to_bin(SessionKey1),
    ?assertMatch([{SK1, 1}], ?MODULE:lookup_skf(SKFETS1, DevAddr1)),
    SK2 = hpr_utils:hex_to_bin(SessionKey2),
    ?assertMatch([{SK2, 2}], ?MODULE:lookup_skf(SKFETS2, DevAddr2)),

    ?assertEqual(ok, ?MODULE:update_skf(DevAddr1, SK1, RouteID1, 11)),
    ?assertMatch([{SK1, 11}], ?MODULE:lookup_skf(SKFETS1, DevAddr1)),

    SessionKey3 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SKF3 = hpr_skf:new(#{
        route_id => RouteID1, devaddr => DevAddr1, session_key => SessionKey3, max_copies => 3
    }),
    ?assertEqual(ok, ?MODULE:insert_skf(SKF3)),

    SK3 = hpr_utils:hex_to_bin(SessionKey3),
    ?assertEqual([{SK3, 3}, {SK1, 11}], lists:keysort(2, ?MODULE:lookup_skf(SKFETS1, DevAddr1))),

    SKF4 = hpr_skf:new(#{
        route_id => RouteID1, devaddr => DevAddr1, session_key => SessionKey3, max_copies => 10
    }),

    ?assertEqual(ok, ?MODULE:insert_skf(SKF4)),
    ?assertEqual([{SK3, 10}, {SK1, 11}], lists:keysort(2, ?MODULE:lookup_skf(SKFETS1, DevAddr1))),

    ?assertEqual(ok, ?MODULE:delete_skf(SKF1)),
    ?assertEqual(ok, ?MODULE:delete_skf(SKF4)),
    ?assertEqual([], ?MODULE:lookup_skf(SKFETS1, DevAddr1)),

    ?assertEqual(ok, ?MODULE:delete_skf(SKF2)),
    ?assertEqual([], ?MODULE:lookup_skf(SKFETS2, DevAddr2)),

    ok.

test_select_skf() ->
    Route = hpr_route:test_new(#{
        id => "11ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    RouteID = hpr_route:id(Route),

    ?assertEqual(ok, ?MODULE:insert_route(Route)),

    DevAddr = 16#00000001,
    DevAddrRange = hpr_devaddr_range:test_new(#{
        route_id => RouteID, start_addr => 16#00000001, end_addr => 16#0000000A
    }),

    ?assertEqual(ok, ?MODULE:insert_devaddr_range(DevAddrRange)),

    lists:foreach(
        fun(_) ->
            SessionKey = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
            SKF = hpr_skf:new(#{
                route_id => RouteID, devaddr => DevAddr, session_key => SessionKey, max_copies => 1
            }),
            ?assertEqual(ok, ?MODULE:insert_skf(SKF))
        end,
        lists:seq(1, 200)
    ),

    [RouteETS] = ?MODULE:lookup_devaddr_range(DevAddr),
    ?assertEqual(Route, ?MODULE:route(RouteETS)),
    SKFETS = ?MODULE:skf_ets(RouteETS),
    {A, Continuation1} = ?MODULE:select_skf(SKFETS, DevAddr),
    {B, Continuation2} = ?MODULE:select_skf(Continuation1),
    '$end_of_table' = ?MODULE:select_skf(Continuation2),

    ?assertEqual(lists:usort(?MODULE:lookup_skf(SKFETS, DevAddr)), lists:usort(A ++ B)),
    ok.

test_delete_route() ->
    Route1 = hpr_route:test_new(#{
        id => "11ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    RouteID1 = hpr_route:id(Route1),
    EUIPair1 = hpr_eui_pair:test_new(#{route_id => RouteID1, app_eui => 1, dev_eui => 1}),
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000001, end_addr => 16#0000000A
    }),
    DevAddr1 = 16#00000001,
    SessionKey1 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SKF1 = hpr_skf:new(#{
        route_id => RouteID1, devaddr => DevAddr1, session_key => SessionKey1, max_copies => 1
    }),

    Route2 = hpr_route:test_new(#{
        id => "77ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns2.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    RouteID2 = hpr_route:id(Route2),

    AppEUI2 = 10,
    DevEUI2 = 20,
    EUIPair2 = hpr_eui_pair:test_new(#{
        route_id => RouteID2,
        app_eui => AppEUI2,
        dev_eui => DevEUI2
    }),
    StartAddr2 = 16#00000010,
    EndAddr2 = 16#000000A0,
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => RouteID2, start_addr => StartAddr2, end_addr => EndAddr2
    }),
    DevAddr2 = 16#00000010,
    SessionKey2 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SKF2 = hpr_skf:new(#{
        route_id => RouteID2, devaddr => DevAddr2, session_key => SessionKey2, max_copies => 1
    }),

    ?assertEqual(ok, ?MODULE:insert_route(Route1)),
    ?assertEqual(ok, ?MODULE:insert_eui_pair(EUIPair1)),
    ?assertEqual(ok, ?MODULE:insert_devaddr_range(DevAddrRange1)),
    ?assertEqual(ok, ?MODULE:insert_skf(SKF1)),
    ?assertEqual(ok, ?MODULE:insert_route(Route2)),
    ?assertEqual(ok, ?MODULE:insert_eui_pair(EUIPair2)),
    ?assertEqual(ok, ?MODULE:insert_devaddr_range(DevAddrRange2)),
    ?assertEqual(ok, ?MODULE:insert_skf(SKF2)),

    ?assertEqual(2, erlang:length(ets:tab2list(?ETS_EUI_PAIRS))),
    ?assertEqual(2, erlang:length(ets:tab2list(?ETS_DEVADDR_RANGES))),
    ?assertEqual(2, erlang:length(ets:tab2list(?ETS_ROUTES))),

    [RouteETS1] = ?MODULE:lookup_devaddr_range(DevAddr1),
    ?assertEqual(Route1, ?MODULE:route(RouteETS1)),
    SKFETS1 = ?MODULE:skf_ets(RouteETS1),
    ?assertEqual(1, erlang:length(ets:tab2list(SKFETS1))),

    [RouteETS2] = ?MODULE:lookup_devaddr_range(DevAddr2),
    ?assertEqual(Route2, ?MODULE:route(RouteETS2)),
    SKFETS2 = ?MODULE:skf_ets(RouteETS2),
    ?assertEqual(1, erlang:length(ets:tab2list(SKFETS2))),

    ?assertEqual(ok, ?MODULE:delete_route(Route1)),

    ?assertEqual([{{AppEUI2, DevEUI2}, RouteID2}], ets:tab2list(?ETS_EUI_PAIRS)),
    ?assertEqual(
        [{{StartAddr2, EndAddr2}, RouteID2}], ets:tab2list(?ETS_DEVADDR_RANGES)
    ),
    ?assertEqual([RouteETS2], ets:tab2list(?ETS_ROUTES)),
    ?assert(erlang:is_list(ets:info(SKFETS2))),
    ?assertEqual(undefined, ets:info(SKFETS1)),
    ok.

test_delete_all() ->
    Route = hpr_route:test_new(#{
        id => "11ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    RouteID = hpr_route:id(Route),
    EUIPair = hpr_eui_pair:test_new(#{route_id => RouteID, app_eui => 1, dev_eui => 1}),
    DevAddrRange = hpr_devaddr_range:test_new(#{
        route_id => RouteID, start_addr => 16#00000001, end_addr => 16#0000000A
    }),
    DevAddr = 16#00000001,
    SessionKey = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SKF = hpr_skf:new(#{
        route_id => RouteID, devaddr => DevAddr, session_key => SessionKey, max_copies => 1
    }),

    ?assertEqual(ok, ?MODULE:insert_route(Route)),
    ?assertEqual(ok, ?MODULE:insert_eui_pair(EUIPair)),
    ?assertEqual(ok, ?MODULE:insert_devaddr_range(DevAddrRange)),
    ?assertEqual(ok, ?MODULE:insert_skf(SKF)),
    ?assertEqual(ok, ?MODULE:delete_all()),
    ?assertEqual([], ets:tab2list(?ETS_DEVADDR_RANGES)),
    ?assertEqual([], ets:tab2list(?ETS_EUI_PAIRS)),
    ?assertEqual([], ets:tab2list(?ETS_ROUTES)),
    ok.

-endif.
