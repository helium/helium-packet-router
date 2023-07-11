-module(hpr_route_ets).

-export([
    init/0,

    insert_route/1,
    delete_route/1,
    lookup_route/1,

    insert_eui_pair/1,
    delete_eui_pair/1,
    lookup_eui_pair/2,

    insert_devaddr_range/1,
    delete_devaddr_range/1,
    lookup_devaddr_range/1,

    insert_skf/1,
    update_skf/4,
    delete_skf/1,
    lookup_skf/2,
    select_skf/1, select_skf/2,

    delete_all/0
]).

%% CLI exports
-export([
    all_routes/0,
    oui_routes/1,
    eui_pairs_for_route/1,
    eui_pairs_count_for_route/1,
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

-spec init() -> ok.
init() ->
    ?ETS_DEVADDR_RANGES = ets:new(?ETS_DEVADDR_RANGES, [
        public, named_table, bag, {read_concurrency, true}
    ]),
    ?ETS_EUI_PAIRS = ets:new(?ETS_EUI_PAIRS, [public, named_table, bag, {read_concurrency, true}]),
    ?ETS_ROUTES = ets:new(?ETS_ROUTES, [public, named_table, set, {read_concurrency, true}]),
    ok.

-spec insert_route(Route :: hpr_route:route()) -> ok.
insert_route(Route) ->
    RouteID = hpr_route:id(Route),
    SKFETS =
        case ?MODULE:lookup_route(RouteID) of
            [{_, ETS}] ->
                ETS;
            _Other ->
                ets:new(?ETS_SKFS, [
                    public,
                    ordered_set,
                    {read_concurrency, true},
                    {write_concurrency, true},
                    {heir, erlang:whereis(?SKF_HEIR), RouteID}
                ])
        end,
    true = ets:insert(?ETS_ROUTES, {RouteID, {Route, SKFETS}}),
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
        {skf_ets, SKFETS}
    ],
    lager:info(RouteFields, "inserting route"),
    ok.

-spec delete_route(Route :: hpr_route:route()) -> ok.
delete_route(Route) ->
    RouteID = hpr_route:id(Route),
    MS1 = [{{'_', RouteID}, [], [true]}],
    DevAddrEntries = ets:select_delete(?ETS_DEVADDR_RANGES, MS1),
    MS2 = [{{'_', RouteID}, [], [true]}],
    EUIsEntries = ets:select_delete(?ETS_EUI_PAIRS, MS2),
    case ?MODULE:lookup_route(RouteID) of
        [{_, SKFETS}] ->
            ets:delete(SKFETS);
        _Other ->
            lager:warning("failed to delete skf table ~p for ~s", [
                _Other, RouteID
            ])
    end,
    true = ets:delete(?ETS_ROUTES, RouteID),
    lager:info(
        [{devaddr, DevAddrEntries}, {euis, EUIsEntries}, {route_id, RouteID}],
        "route deleted"
    ),
    ok.

-spec lookup_route(ID :: string()) -> [{hpr_route:route(), ets:table()}].
lookup_route(ID) ->
    Routes = ets:lookup(?ETS_ROUTES, ID),
    [RouteAndETS || {_ID, RouteAndETS} <- Routes].

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
    [hpr_route:route()].
lookup_eui_pair(AppEUI, 0) ->
    EUIPairs = ets:lookup(?ETS_EUI_PAIRS, {AppEUI, 0}),
    [
        Route
     || {Route, _SKFETS} <- lists:flatten([
            ?MODULE:lookup_route(RouteID)
         || {_, RouteID} <- EUIPairs
        ])
    ];
lookup_eui_pair(AppEUI, DevEUI) ->
    EUIPairs = ets:lookup(?ETS_EUI_PAIRS, {AppEUI, DevEUI}),
    lists:usort(
        [
            Route
         || {Route, _SKFETS} <- lists:flatten([
                ?MODULE:lookup_route(RouteID)
             || {_, RouteID} <- EUIPairs
            ])
        ] ++
            lookup_eui_pair(AppEUI, 0)
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

-spec lookup_devaddr_range(DevAddr :: non_neg_integer()) -> [{hpr_route:route(), ets:table()}].
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
    case ?MODULE:lookup_route(RouteID) of
        [{_, SKFETS}] ->
            DevAddr = hpr_skf:devaddr(SKF),
            SessionKey = hpr_skf:session_key(SKF),
            MaxCopies = hpr_skf:max_copies(SKF),
            %% This is negative to make newest time on top
            Now = erlang:system_time(millisecond) * -1,
            true = ets:insert(SKFETS, {
                {Now, hpr_utils:hex_to_bin(SessionKey)}, {DevAddr, MaxCopies}
            }),
            lager:debug(
                [
                    {route_id, RouteID},
                    {devaddr, hpr_utils:int_to_hex_string(DevAddr)},
                    {session_key, SessionKey},
                    {max_copies, MaxCopies}
                ],
                "inserting SKF"
            );
        _Other ->
            lager:error("failed to insert skf table not found ~p for ~s", [
                _Other, RouteID
            ])
    end,
    ok.

-spec update_skf(
    DevAddr :: non_neg_integer(),
    SessionKey :: binary(),
    RouteID :: string(),
    MaxCopies :: non_neg_integer()
) -> ok.
update_skf(DevAddr, SessionKey, RouteID, MaxCopies) ->
    SKF = hpr_skf:new(#{
        route_id => RouteID,
        devaddr => DevAddr,
        session_key => hpr_utils:bin_to_hex_string(SessionKey),
        max_copies => MaxCopies
    }),
    ok = delete_skf(SKF),
    ok = insert_skf(SKF),
    ok.

-spec delete_skf(SKF :: hpr_skf:skf()) -> ok.
delete_skf(SKF) ->
    RouteID = hpr_skf:route_id(SKF),
    case ?MODULE:lookup_route(RouteID) of
        [{_, SKFETS}] ->
            DevAddr = hpr_skf:devaddr(SKF),
            SessionKey = hpr_skf:session_key(SKF),
            MaxCopies = hpr_skf:max_copies(SKF),
            %% Here we ignore max_copies
            MS = [{{{'_', hpr_utils:hex_to_bin(SessionKey)}, {DevAddr, '_'}}, [], [true]}],
            Deleted = ets:select_delete(SKFETS, MS),
            lager:debug(
                [
                    {route_id, RouteID},
                    {devaddr, hpr_utils:int_to_hex_string(DevAddr)},
                    {session_key, SessionKey},
                    {max_copies, MaxCopies}
                ],
                "deleted ~p SKF",
                [Deleted]
            );
        _Other ->
            lager:warning("failed to delete skf not found ~p for ~s", [
                _Other, RouteID
            ])
    end,
    ok.

-spec lookup_skf(ETS :: ets:table(), DevAddr :: non_neg_integer()) ->
    [{SessionKey :: binary(), Timestamp :: integer(), MaxCopies :: non_neg_integer()}].
lookup_skf(ETS, DevAddr) ->
    MS = [{{{'$1', '$2'}, {DevAddr, '$3'}}, [], [{{'$2', '$1', '$3'}}]}],
    ets:select(ETS, MS).

-spec select_skf(Continuation :: ets:continuation()) ->
    {[{binary(), string(), non_neg_integer()}], ets:continuation()} | '$end_of_table'.
select_skf(Continuation) ->
    ets:select(Continuation).

-spec select_skf(ETS :: ets:table(), DevAddr :: non_neg_integer() | ets:continuation()) ->
    {[{binary(), integer(), non_neg_integer()}], ets:continuation()} | '$end_of_table'.
select_skf(ETS, DevAddr) ->
    MS = [{{{'$1', '$2'}, {DevAddr, '$3'}}, [], [{{'$2', '$1', '$3'}}]}],
    ets:select(ETS, MS, 100).

-spec delete_all() -> ok.
delete_all() ->
    ets:delete_all_objects(?ETS_DEVADDR_RANGES),
    ets:delete_all_objects(?ETS_EUI_PAIRS),
    lists:foreach(
        fun({_, {_, SKFETS}}) ->
            ets:delete(SKFETS)
        end,
        ets:tab2list(?ETS_ROUTES)
    ),
    ets:delete_all_objects(?ETS_ROUTES),
    ok.

%% ------------------------------------------------------------------
%% CLI Functions
%% ------------------------------------------------------------------

-spec all_routes() -> list(hpr_route:route()).
all_routes() ->
    [Route || {_ID, {Route, _ETS}} <- ets:tab2list(?ETS_ROUTES)].

-spec oui_routes(OUI :: non_neg_integer()) -> list(hpr_route:route()).
oui_routes(OUI) ->
    [Route || {_ID, {Route, _}} <- ets:tab2list(?ETS_ROUTES), OUI == hpr_route:oui(Route)].

-spec eui_pairs_for_route(RouteID :: string()) -> list({non_neg_integer(), non_neg_integer()}).
eui_pairs_for_route(RouteID) ->
    MS = [{{{'$1', '$2'}, RouteID}, [], [{{'$1', '$2'}}]}],
    ets:select(?ETS_EUI_PAIRS, MS).

-spec eui_pairs_count_for_route(RouteID :: string()) -> non_neg_integer().
eui_pairs_count_for_route(RouteID) ->
    MS = [{{{'$1', '$2'}, RouteID}, [], [{{'$1', '$2'}}]}],
    ets:select_count(?ETS_EUI_PAIRS, MS).

-spec devaddr_ranges_for_route(RouteID :: string()) -> list({non_neg_integer(), non_neg_integer()}).
devaddr_ranges_for_route(RouteID) ->
    MS = [{{{'$1', '$2'}, RouteID}, [], [{{'$1', '$2'}}]}],
    ets:select(?ETS_DEVADDR_RANGES, MS).

-spec devaddr_ranges_count_for_route(RouteID :: string()) -> non_neg_integer().
devaddr_ranges_count_for_route(RouteID) ->
    MS = [{{{'$1', '$2'}, RouteID}, [], [{{'$1', '$2'}}]}],
    ets:select_count(?ETS_DEVADDR_RANGES, MS).

-spec skfs_for_route(RouteID :: string()) ->
    [{{integer(), binary()}, {non_neg_integer(), non_neg_integer()}}].
skfs_for_route(RouteID) ->
    case ?MODULE:lookup_route(RouteID) of
        [{_, SKFETS}] ->
            ets:tab2list(SKFETS);
        _Other ->
            []
    end.

-spec skfs_count_for_route(RouteID :: string()) -> non_neg_integer().
skfs_count_for_route(RouteID) ->
    case ?MODULE:lookup_route(RouteID) of
        [{_, SKFETS}] ->
            ets:info(SKFETS, size);
        _Other ->
            0
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

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
        fun({_, {_, SKFETS}}) ->
            ets:delete(SKFETS)
        end,
        ets:tab2list(?ETS_ROUTES)
    ),
    ets:delete(?ETS_ROUTES),
    true = erlang:unregister(?SKF_HEIR),
    ok.

test_route() ->
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

    %% Create
    ?assertEqual(ok, ?MODULE:insert_route(Route)),
    [{LookupRoute, SKFETS}] = ?MODULE:lookup_route(RouteID),
    ?assertEqual(Route, LookupRoute),
    ?assert(erlang:is_reference(SKFETS)),
    ?assert(erlang:is_list(ets:info(SKFETS))),

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
    [{LookupRoute1, SKFETS1}] = ?MODULE:lookup_route(RouteID),
    ?assertEqual(Route1, LookupRoute1),
    ?assert(erlang:is_reference(SKFETS1)),
    ?assert(erlang:is_list(ets:info(SKFETS1))),

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

    ?assertEqual([Route1], ?MODULE:lookup_eui_pair(1, 1)),
    ?assertEqual([], ?MODULE:lookup_eui_pair(1, 2)),
    ?assertEqual([Route1], ?MODULE:lookup_eui_pair(2, 1)),
    ?assertEqual([Route1, Route2], ?MODULE:lookup_eui_pair(2, 2)),

    EUIPair4 = hpr_eui_pair:test_new(#{route_id => RouteID1, app_eui => 1, dev_eui => 0}),
    ?assertEqual(ok, ?MODULE:insert_eui_pair(EUIPair4)),
    ?assertEqual([Route1], ?MODULE:lookup_eui_pair(1, 1)),
    ?assertEqual(ok, ?MODULE:delete_eui_pair(EUIPair1)),
    ?assertEqual([Route1], ?MODULE:lookup_eui_pair(1, 1)),
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

    ?assertMatch([{Route1, X}] when is_reference(X), ?MODULE:lookup_devaddr_range(16#00000005)),
    ?assertMatch([{Route2, X}] when is_reference(X), ?MODULE:lookup_devaddr_range(16#00000010)),
    ?assertMatch([{Route2, X}] when is_reference(X), ?MODULE:lookup_devaddr_range(16#0000001A)),
    ?assertMatch(
        [{Route1, X}, {Route2, Y}] when is_reference(X) andalso is_reference(Y),
        ?MODULE:lookup_devaddr_range(16#00000002)
    ),
    ?assertEqual(
        ok, ?MODULE:delete_devaddr_range(DevAddrRange1)
    ),
    ?assertEqual([], ?MODULE:lookup_devaddr_range(16#00000005)),
    ?assertMatch([{Route2, X}] when is_reference(X), ?MODULE:lookup_devaddr_range(16#00000002)),

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

    [{Route1, SKFETS1}] = ?MODULE:lookup_devaddr_range(DevAddr1),
    [{Route2, SKFETS2}] = ?MODULE:lookup_devaddr_range(DevAddr2),

    SK1 = hpr_utils:hex_to_bin(SessionKey1),
    ?assertMatch([{SK1, X, 1}] when X < 0, ?MODULE:lookup_skf(SKFETS1, DevAddr1)),
    SK2 = hpr_utils:hex_to_bin(SessionKey2),
    ?assertMatch([{SK2, X, 2}] when X < 0, ?MODULE:lookup_skf(SKFETS2, DevAddr2)),

    T1 = erlang:system_time(millisecond) * -1,
    timer:sleep(2),
    ?assertEqual(ok, ?MODULE:update_skf(DevAddr1, SK1, RouteID1, 11)),
    ?assertMatch([{SK1, X, 11}] when X < T1, ?MODULE:lookup_skf(SKFETS1, DevAddr1)),

    SessionKey3 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SKF3 = hpr_skf:new(#{
        route_id => RouteID1, devaddr => DevAddr1, session_key => SessionKey3, max_copies => 3
    }),
    timer:sleep(1),
    ?assertEqual(ok, ?MODULE:insert_skf(SKF3)),

    SK3 = hpr_utils:hex_to_bin(SessionKey3),
    ?assertMatch([{SK3, X, 3}, {SK1, Y, 11}] when X < Y, ?MODULE:lookup_skf(SKFETS1, DevAddr1)),

    ?assertEqual(ok, ?MODULE:delete_skf(SKF1)),
    ?assertEqual(ok, ?MODULE:delete_skf(SKF3)),
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

    [{Route, SKFETS}] = ?MODULE:lookup_devaddr_range(DevAddr),
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

    [{Route1, SKFETS1}] = ?MODULE:lookup_devaddr_range(DevAddr1),
    ?assertEqual(1, erlang:length(ets:tab2list(SKFETS1))),
    [{Route2, SKFETS2}] = ?MODULE:lookup_devaddr_range(DevAddr2),
    ?assertEqual(1, erlang:length(ets:tab2list(SKFETS2))),

    ?assertEqual(ok, ?MODULE:delete_route(Route1)),

    ?assertEqual([{{AppEUI2, DevEUI2}, RouteID2}], ets:tab2list(?ETS_EUI_PAIRS)),
    ?assertEqual(
        [{{StartAddr2, EndAddr2}, RouteID2}], ets:tab2list(?ETS_DEVADDR_RANGES)
    ),
    ?assertMatch([{RouteID2, {Route2, X}}] when is_reference(X), ets:tab2list(?ETS_ROUTES)),
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
