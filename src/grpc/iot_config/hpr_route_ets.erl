-module(hpr_route_ets).

-export([
    init/0,
    ets_keypos/0,

    new/3,
    route/1,
    skf_ets/1,
    backoff/1,
    inc_backoff/1,
    reset_backoff/1,

    delete_all/0
]).

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
    ok = hpr_route_storage:init_ets(),
    ok = hpr_devaddr_range_storage:init_ets(),
    %% SKF hydration is handled by route hydration
    ok = hpr_eui_pair_storage:init_ets(),
    ok.

-spec ets_keypos() -> non_neg_integer().
ets_keypos() ->
    #hpr_route_ets.id.

-spec new(Route :: hpr_route:route(), SKFETS :: ets:tid(), Backoff :: backoff()) -> route().
new(Route, SKFETS, Backoff) ->
    #hpr_route_ets{
        id = hpr_route:id(Route),
        route = Route,
        skf_ets = SKFETS,
        backoff = Backoff
    }.

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
    case hpr_route_storage:lookup(RouteID) of
        {ok, #hpr_route_ets{backoff = undefined}} ->
            Backoff = backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX),
            Delay = backoff:get(Backoff),
            hpr_route_storage:set_backoff(RouteID, {Now + Delay, Backoff});
        {ok, #hpr_route_ets{backoff = {_, Backoff0}}} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            hpr_route_storage:set_backoff(RouteID, {Now + Delay, Backoff1});
        {error, not_found} ->
            ok
    end.

-spec reset_backoff(RouteID :: hpr_route:id()) -> ok.
reset_backoff(RouteID) ->
    case hpr_route_storage:lookup(RouteID) of
        {ok, #hpr_route_ets{backoff = undefined}} ->
            ok;
        {ok, #hpr_route_ets{backoff = _}} ->
            hpr_route_storage:set_backoff(RouteID, undefined);
        {error, not_found} ->
            ok
    end.

-spec delete_all() -> ok.
delete_all() ->
    ok = hpr_devaddr_range_storage:delete_all(),
    ok = hpr_eui_pair_storage:delete_all(),
    ok = hpr_skf_storage:delete_all(),
    ok = hpr_route_storage:delete_all(),
    ok.

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
        {"test_route", ?_test(test_route())},
        {"test_eui_pair", ?_test(test_eui_pair())},
        {"test_devaddr_range", ?_test(test_devaddr_range())},
        {"test_skf", ?_test(test_skf())},
        {"test_select_skf", ?_test(test_select_skf())},
        {"test_delete_route", ?_test(test_delete_route())},
        {"test_delete_all", ?_test(test_delete_all())}
    ]}.

foreach_setup() ->
    BaseDirPath = filename:join([
        ?MODULE,
        erlang:integer_to_list(erlang:system_time(millisecond)),
        "data"
    ]),
    ok = application:set_env(hpr, data_dir, BaseDirPath),
    true = hpr_skf_storage:test_register_heir(),
    ?MODULE:init(),
    ok.

foreach_cleanup(ok) ->
    ok = hpr_devaddr_range_storage:test_delete_ets(),
    ok = hpr_eui_pair_storage:test_delete_ets(),
    ok = hpr_skf_storage:test_delete_ets(),
    ok = hpr_route_storage:test_delete_ets(),

    true = hpr_skf_storage:test_unregister_heir(),
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
    ?assertEqual(ok, hpr_route_storage:insert(Route0)),
    {ok, RouteETS0} = hpr_route_storage:lookup(RouteID),
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
    ?assertEqual(ok, hpr_route_storage:insert(Route1)),
    {ok, RouteETS1} = hpr_route_storage:lookup(RouteID),
    ?assertEqual(RouteID, RouteETS1#hpr_route_ets.id),
    ?assertEqual(Route1, ?MODULE:route(RouteETS1)),
    SKFETS1 = ?MODULE:skf_ets(RouteETS0),
    ?assert(erlang:is_reference(SKFETS1)),
    ?assert(erlang:is_list(ets:info(SKFETS1))),
    ?assertEqual(SKFETS0, SKFETS1),
    ?assertEqual(undefined, ?MODULE:backoff(RouteETS1)),

    Backoff = {erlang:system_time(millisecond), backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX)},
    ?assertEqual(ok, hpr_route_storage:set_backoff(RouteID, Backoff)),
    {ok, RouteETS2} = hpr_route_storage:lookup(RouteID),
    ?assertEqual(Backoff, ?MODULE:backoff(RouteETS2)),

    %% Delete
    ?assertEqual(ok, hpr_route_storage:delete(Route1)),
    ?assertEqual({error, not_found}, hpr_route_storage:lookup(RouteID)),
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

    ?assertEqual(ok, hpr_route_storage:insert(Route1)),
    ?assertEqual(ok, hpr_route_storage:insert(Route2)),

    ?assertEqual(ok, hpr_eui_pair_storage:insert(EUIPair1)),
    ?assertEqual(ok, hpr_eui_pair_storage:insert(EUIPair2)),
    ?assertEqual(ok, hpr_eui_pair_storage:insert(EUIPair3)),

    [RouteETS1] = hpr_eui_pair_storage:lookup(1, 1),
    ?assertEqual(Route1, ?MODULE:route(RouteETS1)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(1, 2)),
    [RouteETS2] = hpr_eui_pair_storage:lookup(2, 1),
    ?assertEqual(Route1, ?MODULE:route(RouteETS2)),
    [RouteETS3, RouteETS4] = hpr_eui_pair_storage:lookup(2, 2),

    ?assertEqual(Route1, ?MODULE:route(RouteETS3)),
    ?assertEqual(Route2, ?MODULE:route(RouteETS4)),

    EUIPair4 = hpr_eui_pair:test_new(#{route_id => RouteID1, app_eui => 1, dev_eui => 0}),
    ?assertEqual(ok, hpr_eui_pair_storage:insert(EUIPair4)),
    [RouteETS5] = hpr_eui_pair_storage:lookup(1, 1),
    ?assertEqual(Route1, ?MODULE:route(RouteETS5)),
    ?assertEqual(ok, hpr_eui_pair_storage:delete(EUIPair1)),
    [RouteETS6] = hpr_eui_pair_storage:lookup(1, 1),

    ?assertEqual(Route1, ?MODULE:route(RouteETS6)),
    ?assertEqual(ok, hpr_eui_pair_storage:delete(EUIPair4)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(1, 1)),

    ?assertEqual(ok, hpr_eui_pair_storage:delete(EUIPair2)),
    ?assertEqual(ok, hpr_eui_pair_storage:delete(EUIPair3)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(2, 1)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(2, 2)),

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

    ?assertEqual(ok, hpr_route_storage:insert(Route1)),
    ?assertEqual(ok, hpr_route_storage:insert(Route2)),
    ?assertEqual(ok, hpr_devaddr_range_storage:insert(DevAddrRange1)),
    ?assertEqual(ok, hpr_devaddr_range_storage:insert(DevAddrRange2)),
    ?assertEqual(ok, hpr_devaddr_range_storage:insert(DevAddrRange3)),

    [RouteETS1] = hpr_devaddr_range_storage:lookup(16#00000005),
    ?assertEqual(Route1, ?MODULE:route(RouteETS1)),
    [RouteETS2] = hpr_devaddr_range_storage:lookup(16#00000010),
    ?assertEqual(Route2, ?MODULE:route(RouteETS2)),
    [RouteETS3] = hpr_devaddr_range_storage:lookup(16#0000001A),
    ?assertEqual(Route2, ?MODULE:route(RouteETS3)),
    [RouteETS4, RouteETS5] = hpr_devaddr_range_storage:lookup(16#00000002),
    ?assertEqual(Route1, ?MODULE:route(RouteETS4)),
    ?assertEqual(Route2, ?MODULE:route(RouteETS5)),

    ?assertEqual(
        ok, hpr_devaddr_range_storage:delete(DevAddrRange1)
    ),
    ?assertEqual([], hpr_devaddr_range_storage:lookup(16#00000005)),
    [RouteETS6] = hpr_devaddr_range_storage:lookup(16#00000002),
    ?assertEqual(Route2, ?MODULE:route(RouteETS6)),

    ?assertEqual(ok, hpr_devaddr_range_storage:delete(DevAddrRange2)),
    ?assertEqual([], hpr_devaddr_range_storage:lookup(16#00000010)),
    ?assertEqual([], hpr_devaddr_range_storage:lookup(16#0000001A)),

    ?assertEqual(ok, hpr_devaddr_range_storage:delete(DevAddrRange3)),
    ?assertEqual([], hpr_devaddr_range_storage:lookup(16#00000002)),

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

    ?assertEqual(ok, hpr_route_storage:insert(Route1)),
    ?assertEqual(ok, hpr_route_storage:insert(Route2)),
    ?assertEqual(ok, hpr_devaddr_range_storage:insert(DevAddrRange1)),
    ?assertEqual(ok, hpr_devaddr_range_storage:insert(DevAddrRange2)),
    ?assertEqual(ok, hpr_skf_storage:insert(SKF1)),
    ?assertEqual(ok, hpr_skf_storage:insert(SKF2)),

    {ok, RouteETS1} = hpr_route_storage:lookup(RouteID1),
    {ok, RouteETS2} = hpr_route_storage:lookup(RouteID2),
    SKFETS1 = ?MODULE:skf_ets(RouteETS1),
    SKFETS2 = ?MODULE:skf_ets(RouteETS2),

    SK1 = hpr_utils:hex_to_bin(SessionKey1),
    ?assertMatch([{SK1, 1}], hpr_skf_storage:lookup(SKFETS1, DevAddr1)),
    SK2 = hpr_utils:hex_to_bin(SessionKey2),
    ?assertMatch([{SK2, 2}], hpr_skf_storage:lookup(SKFETS2, DevAddr2)),

    ?assertEqual(ok, hpr_skf_storage:update(DevAddr1, SK1, RouteID1, 11)),
    ?assertMatch([{SK1, 11}], hpr_skf_storage:lookup(SKFETS1, DevAddr1)),

    SessionKey3 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SKF3 = hpr_skf:new(#{
        route_id => RouteID1, devaddr => DevAddr1, session_key => SessionKey3, max_copies => 3
    }),
    ?assertEqual(ok, hpr_skf_storage:insert(SKF3)),

    SK3 = hpr_utils:hex_to_bin(SessionKey3),
    ?assertEqual(
        [{SK3, 3}, {SK1, 11}], lists:keysort(2, hpr_skf_storage:lookup(SKFETS1, DevAddr1))
    ),

    SKF4 = hpr_skf:new(#{
        route_id => RouteID1, devaddr => DevAddr1, session_key => SessionKey3, max_copies => 10
    }),

    ?assertEqual(ok, hpr_skf_storage:insert(SKF4)),
    ?assertEqual(
        [{SK3, 10}, {SK1, 11}], lists:keysort(2, hpr_skf_storage:lookup(SKFETS1, DevAddr1))
    ),

    ?assertEqual(ok, hpr_skf_storage:delete(SKF1)),
    ?assertEqual(ok, hpr_skf_storage:delete(SKF4)),
    ?assertEqual([], hpr_skf_storage:lookup(SKFETS1, DevAddr1)),

    ?assertEqual(ok, hpr_skf_storage:delete(SKF2)),
    ?assertEqual([], hpr_skf_storage:lookup(SKFETS2, DevAddr2)),

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

    ?assertEqual(ok, hpr_route_storage:insert(Route)),

    DevAddr = 16#00000001,
    DevAddrRange = hpr_devaddr_range:test_new(#{
        route_id => RouteID, start_addr => 16#00000001, end_addr => 16#0000000A
    }),

    ?assertEqual(ok, hpr_devaddr_range_storage:insert(DevAddrRange)),

    lists:foreach(
        fun(_) ->
            SessionKey = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
            SKF = hpr_skf:new(#{
                route_id => RouteID, devaddr => DevAddr, session_key => SessionKey, max_copies => 1
            }),
            ?assertEqual(ok, hpr_skf_storage:insert(SKF))
        end,
        lists:seq(1, 200)
    ),

    [RouteETS] = hpr_devaddr_range_storage:lookup(DevAddr),
    ?assertEqual(Route, ?MODULE:route(RouteETS)),
    SKFETS = ?MODULE:skf_ets(RouteETS),
    {A, Continuation1} = hpr_skf_storage:select(SKFETS, DevAddr),
    {B, Continuation2} = hpr_skf_storage:select(Continuation1),
    '$end_of_table' = hpr_skf_storage:select(Continuation2),

    ?assertEqual(lists:usort(hpr_skf_storage:lookup(SKFETS, DevAddr)), lists:usort(A ++ B)),
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

    ?assertEqual(ok, hpr_route_storage:insert(Route1)),
    ?assertEqual(ok, hpr_eui_pair_storage:insert(EUIPair1)),
    ?assertEqual(ok, hpr_devaddr_range_storage:insert(DevAddrRange1)),
    ?assertEqual(ok, hpr_skf_storage:insert(SKF1)),
    ?assertEqual(ok, hpr_route_storage:insert(Route2)),
    ?assertEqual(ok, hpr_eui_pair_storage:insert(EUIPair2)),
    ?assertEqual(ok, hpr_devaddr_range_storage:insert(DevAddrRange2)),
    ?assertEqual(ok, hpr_skf_storage:insert(SKF2)),

    ?assertEqual(2, hpr_eui_pair_storage:test_size()),
    ?assertEqual(2, hpr_devaddr_range_storage:test_size()),
    ?assertEqual(2, hpr_route_storage:test_size()),

    [RouteETS1] = hpr_devaddr_range_storage:lookup(DevAddr1),
    ?assertEqual(Route1, ?MODULE:route(RouteETS1)),
    SKFETS1 = ?MODULE:skf_ets(RouteETS1),
    ?assertEqual(1, hpr_skf_storage:test_size(SKFETS1)),

    [RouteETS2] = hpr_devaddr_range_storage:lookup(DevAddr2),
    ?assertEqual(Route2, ?MODULE:route(RouteETS2)),
    SKFETS2 = ?MODULE:skf_ets(RouteETS2),
    ?assertEqual(1, hpr_skf_storage:test_size(SKFETS2)),

    ?assertEqual(ok, hpr_route_storage:delete(Route1)),

    ?assertEqual(
        [{{AppEUI2, DevEUI2}, RouteID2}], ets:tab2list(hpr_eui_pair_storage:test_tab_name())
    ),
    ?assertEqual(
        [{{StartAddr2, EndAddr2}, RouteID2}],
        ets:tab2list(hpr_devaddr_range_storage:test_tab_name())
    ),
    ?assertEqual({ok, RouteETS2}, hpr_route_storage:lookup(hpr_route:id(Route2))),
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

    ?assertEqual(ok, hpr_route_storage:insert(Route)),
    ?assertEqual(ok, hpr_eui_pair_storage:insert(EUIPair)),
    ?assertEqual(ok, hpr_devaddr_range_storage:insert(DevAddrRange)),
    ?assertEqual(ok, hpr_skf_storage:insert(SKF)),
    ?assertEqual(ok, ?MODULE:delete_all()),
    ?assertEqual(0, hpr_devaddr_range_storage:test_size()),
    ?assertEqual(0, hpr_eui_pair_storage:test_size()),
    ?assertEqual(0, hpr_route_storage:test_size()),
    ok.

-endif.
