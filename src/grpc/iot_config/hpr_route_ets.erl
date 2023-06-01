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
    update_skf/3,
    delete_skf/1,
    lookup_skf/1,
    select_skf/1,

    delete_all/0
]).

%% CLI exports
-export([
    all_routes/0,
    oui_routes/1,
    eui_pairs_for_route/1,
    devaddr_ranges_for_route/1,
    skfs_for_route/1
]).

-define(ETS_ROUTES, hpr_routes_ets).
-define(ETS_EUI_PAIRS, hpr_route_eui_pairs_ets).
-define(ETS_DEVADDR_RANGES, hpr_route_devaddr_ranges_ets).
-define(ETS_SKFS, hpr_route_skfs_ets).

-spec init() -> ok.
init() ->
    ?ETS_DEVADDR_RANGES = ets:new(?ETS_DEVADDR_RANGES, [
        public, named_table, bag, {read_concurrency, true}
    ]),
    ?ETS_EUI_PAIRS = ets:new(?ETS_EUI_PAIRS, [public, named_table, bag, {read_concurrency, true}]),
    ?ETS_ROUTES = ets:new(?ETS_ROUTES, [public, named_table, set, {read_concurrency, true}]),
    ?ETS_SKFS = ets:new(?ETS_SKFS, [
        public,
        named_table,
        ordered_set,
        {read_concurrency, true}
    ]),
    ok.

-spec insert_route(Route :: hpr_route:route()) -> ok.
insert_route(Route) ->
    true = ets:insert(?ETS_ROUTES, {hpr_route:id(Route), Route}),
    Server = hpr_route:server(Route),
    RouteFields = [
        {id, hpr_route:id(Route)},
        {net_id, hpr_utils:net_id_display(hpr_route:net_id(Route))},
        {oui, hpr_route:oui(Route)},
        {protocol, hpr_route:protocol_type(Server)},
        {max_copies, hpr_route:max_copies(Route)}
    ],
    lager:info(RouteFields, "inserting route"),
    ok.

-spec delete_route(Route :: hpr_route:route()) -> ok.
delete_route(Route) ->
    RouteID = hpr_route:id(Route),
    MS1 = [{{'_', RouteID}, [], [true]}],
    DevAddrEntries = ets:select_delete(?ETS_DEVADDR_RANGES, MS1),
    MS2 = [{{'_', RouteID}, [], [true]}],
    EUISEntries = ets:select_delete(?ETS_EUI_PAIRS, MS2),
    MS3 = [{{'_', {'_', RouteID, '_'}}, [], [true]}],
    SKFsEntries = ets:select_delete(?ETS_SKFS, MS3),
    true = ets:delete(?ETS_ROUTES, RouteID),
    lager:info("deleted ~w DevAddr Entries, ~w EUIS Entries, ~w SKFs Entries for ~s", [
        DevAddrEntries, EUISEntries, SKFsEntries, RouteID
    ]),
    ok.

-spec lookup_route(ID :: string()) -> [hpr_route:route()].
lookup_route(ID) ->
    Routes = ets:lookup(?ETS_ROUTES, ID),
    [Route || {_ID, Route} <- Routes].

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
    lists:flatten([?MODULE:lookup_route(RouteID) || {_, RouteID} <- EUIPairs]);
lookup_eui_pair(AppEUI, DevEUI) ->
    EUIPairs = ets:lookup(?ETS_EUI_PAIRS, {AppEUI, DevEUI}),
    lists:usort(
        lists:flatten([
            ?MODULE:lookup_route(RouteID)
         || {_, RouteID} <- EUIPairs
        ]) ++
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

-spec lookup_devaddr_range(DevAddr :: non_neg_integer()) -> [hpr_route:route()].
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
    DevAddr = hpr_skf:devaddr(SKF),
    SessionKey = hpr_skf:session_key(SKF),
    Key = {erlang:system_time(millisecond), hpr_utils:hex_to_bin(SessionKey)},
    MaxCopies = hpr_skf:max_copies(SKF),
    Value = {DevAddr, RouteID, MaxCopies},
    true = ets:insert(?ETS_SKFS, {Key, Value}),
    lager:debug(
        [
            {route_id, RouteID},
            {devaddr, hpr_utils:int_to_hex_string(DevAddr)},
            {session_key, SessionKey},
            {max_copies, MaxCopies}
        ],
        "inserting SKF"
    ),
    ok.

-spec update_skf(DevAddr :: non_neg_integer(), SessionKey :: binary(), RouteID :: string()) -> ok.
update_skf(DevAddr, SessionKey, RouteID) ->
    SKF = hpr_skf:new(#{
        route_id => RouteID,
        devaddr => DevAddr,
        session_key => hpr_utils:bin_to_hex_string(SessionKey)
    }),
    ok = delete_skf(SKF),
    ok = insert_skf(SKF),
    ok.

-spec delete_skf(SKF :: hpr_skf:skf()) -> ok.
delete_skf(SKF) ->
    RouteID = hpr_skf:route_id(SKF),
    DevAddr = hpr_skf:devaddr(SKF),
    SessionKey = hpr_skf:session_key(SKF),
    MaxCopies = hpr_skf:max_copies(SKF),
    %% We ignore max copies here
    MS = [{{{'_', hpr_utils:hex_to_bin(SessionKey)}, {DevAddr, RouteID, '_'}}, [], [true]}],
    Deleted = ets:select_delete(?ETS_SKFS, MS),
    lager:debug(
        [
            {route_id, RouteID},
            {devaddr, hpr_utils:int_to_hex_string(DevAddr)},
            {session_key, SessionKey},
            {max_copies, MaxCopies}
        ],
        "deleted ~p SKF",
        [Deleted]
    ),
    ok.

-spec lookup_skf(DevAddr :: non_neg_integer()) ->
    [{binary(), string(), non_neg_integer(), non_neg_integer()}].
lookup_skf(DevAddr) ->
    MS = [{{{'$1', '$2'}, {DevAddr, '$3', '$4'}}, [], [{{'$2', '$3', '$4', '$1'}}]}],
    ets:select(?ETS_SKFS, MS).

-spec select_skf(DevAddr :: non_neg_integer() | ets:continuation()) ->
    {[{binary(), string(), non_neg_integer(), non_neg_integer()}], ets:continuation()}
    | '$end_of_table'.
select_skf(DevAddr) when is_integer(DevAddr) ->
    MS = [{{{'$1', '$2'}, {DevAddr, '$3', '$4'}}, [], [{{'$2', '$3', '$4', '$1'}}]}],
    ets:select(?ETS_SKFS, MS, 100);
select_skf(Continuation) ->
    ets:select(Continuation).

-spec delete_all() -> ok.
delete_all() ->
    ets:delete_all_objects(?ETS_SKFS),
    ets:delete_all_objects(?ETS_DEVADDR_RANGES),
    ets:delete_all_objects(?ETS_EUI_PAIRS),
    ets:delete_all_objects(?ETS_ROUTES),
    ok.

%% ------------------------------------------------------------------
%% CLI Functions
%% ------------------------------------------------------------------

-spec all_routes() -> list(hpr_route:route()).
all_routes() ->
    [Route || {_ID, Route} <- ets:tab2list(?ETS_ROUTES)].

-spec oui_routes(OUI :: non_neg_integer()) -> list(hpr_route:route()).
oui_routes(OUI) ->
    [Route || {_ID, Route} <- ets:tab2list(?ETS_ROUTES), OUI == hpr_route:oui(Route)].

-spec eui_pairs_for_route(RouteID :: string()) -> list({non_neg_integer(), non_neg_integer()}).
eui_pairs_for_route(RouteID) ->
    MS = [{{{'$1', '$2'}, RouteID}, [], [{{'$1', '$2'}}]}],
    ets:select(?ETS_EUI_PAIRS, MS).

-spec devaddr_ranges_for_route(RouteID :: string()) -> list({non_neg_integer(), non_neg_integer()}).
devaddr_ranges_for_route(RouteID) ->
    MS = [{{{'$1', '$2'}, RouteID}, [], [{{'$1', '$2'}}]}],
    ets:select(?ETS_DEVADDR_RANGES, MS).

-spec skfs_for_route(RouteID :: string()) -> list({non_neg_integer(), binary(), non_neg_integer()}).
skfs_for_route(RouteID) ->
    MS = [{{{'_', '$1'}, {'$2', RouteID, '$3'}}, [], [{{'$2', '$1', '$3'}}]}],
    ets:select(?ETS_SKFS, MS).

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
    init(),
    ok.

foreach_cleanup(ok) ->
    true = ets:delete(?ETS_SKFS),
    true = ets:delete(?ETS_DEVADDR_RANGES),
    true = ets:delete(?ETS_EUI_PAIRS),
    true = ets:delete(?ETS_ROUTES),
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

    ?assertEqual(ok, ?MODULE:insert_route(Route)),
    ?assertEqual([Route], ?MODULE:lookup_route(RouteID)),
    ?assertEqual(ok, ?MODULE:delete_route(Route)),
    ?assertEqual([], ?MODULE:lookup_route(RouteID)),
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

    ?assertEqual([Route1], ?MODULE:lookup_devaddr_range(16#00000005)),
    ?assertEqual([Route2], ?MODULE:lookup_devaddr_range(16#00000010)),
    ?assertEqual([Route2], ?MODULE:lookup_devaddr_range(16#0000001A)),
    ?assertEqual([Route1, Route2], ?MODULE:lookup_devaddr_range(16#00000002)),

    ?assertEqual(ok, ?MODULE:delete_devaddr_range(DevAddrRange1)),
    ?assertEqual([], ?MODULE:lookup_devaddr_range(16#00000005)),
    ?assertEqual([Route2], ?MODULE:lookup_devaddr_range(16#00000002)),

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

    DevAddr1 = 16#00000001,
    SessionKey1 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SKF1 = hpr_skf:test_new(#{
        route_id => RouteID1, devaddr => DevAddr1, session_key => SessionKey1, max_copies => 1
    }),
    DevAddr2 = 16#00000002,
    SessionKey2 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SKF2 = hpr_skf:test_new(#{
        route_id => RouteID2, devaddr => DevAddr2, session_key => SessionKey2, max_copies => 1
    }),

    ?assertEqual(ok, ?MODULE:insert_route(Route1)),
    ?assertEqual(ok, ?MODULE:insert_route(Route2)),
    ?assertEqual(ok, ?MODULE:insert_skf(SKF1)),
    ?assertEqual(ok, ?MODULE:insert_skf(SKF2)),

    SK1 = hpr_utils:hex_to_bin(SessionKey1),
    ?assertMatch([{SK1, RouteID1, 1, X}] when X > 0, ?MODULE:lookup_skf(DevAddr1)),
    SK2 = hpr_utils:hex_to_bin(SessionKey2),
    ?assertMatch([{SK2, RouteID2, 1, X}] when X > 0, ?MODULE:lookup_skf(DevAddr2)),

    T1 = erlang:system_time(millisecond),
    timer:sleep(2),
    ?assertEqual(ok, ?MODULE:update_skf(DevAddr1, SK1, RouteID1)),
    ?assertMatch([{SK1, RouteID1, 1, X}] when X > T1, ?MODULE:lookup_skf(DevAddr1)),

    ?assertEqual(ok, ?MODULE:delete_skf(SKF1)),
    ?assertEqual([], ?MODULE:lookup_skf(DevAddr1)),

    ?assertEqual(ok, ?MODULE:delete_skf(SKF2)),
    ?assertEqual([], ?MODULE:lookup_skf(DevAddr2)),

    ok.

test_select_skf() ->
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

    ?assertEqual(ok, ?MODULE:insert_route(Route1)),

    DevAddr = 16#00000001,

    lists:foreach(
        fun(_) ->
            SessionKey = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
            SKF = hpr_skf:test_new(#{
                route_id => RouteID1, devaddr => DevAddr, session_key => SessionKey, max_copies => 1
            }),
            ?assertEqual(ok, ?MODULE:insert_skf(SKF))
        end,
        lists:seq(1, 200)
    ),

    {A, Continuation1} = ?MODULE:select_skf(DevAddr),
    {B, Continuation2} = ?MODULE:select_skf(Continuation1),
    '$end_of_table' = ?MODULE:select_skf(Continuation2),

    ?assertEqual(lists:usort(?MODULE:lookup_skf(DevAddr)), lists:usort(A ++ B)),
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
    SKF1 = hpr_skf:test_new(#{
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
    SKF2 = hpr_skf:test_new(#{
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
    ?assertEqual(2, erlang:length(ets:tab2list(?ETS_SKFS))),
    ?assertEqual(2, erlang:length(ets:tab2list(?ETS_ROUTES))),

    ?assertEqual(ok, ?MODULE:delete_route(Route1)),

    ?assertEqual([{{AppEUI2, DevEUI2}, RouteID2}], ets:tab2list(?ETS_EUI_PAIRS)),
    ?assertEqual(
        [{{StartAddr2, EndAddr2}, RouteID2}], ets:tab2list(?ETS_DEVADDR_RANGES)
    ),
    SK2 = hpr_utils:hex_to_bin(SessionKey2),
    ?assertMatch(
        [{{Timestamp, SK2}, {DevAddr2, RouteID2, 1}}] when Timestamp > 0,
        ets:tab2list(?ETS_SKFS)
    ),
    ?assertEqual([{RouteID2, Route2}], ets:tab2list(?ETS_ROUTES)),
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
    SKF = hpr_skf:test_new(#{
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
    ?assertEqual([], ets:tab2list(?ETS_SKFS)),
    ok.

-endif.
