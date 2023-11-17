-module(hpr_route_ets).

-export([
    init/0,
    ets_keypos/0,

    new/3,
    route/1,
    skf_ets/1,
    backoff/1,
    update_backoff/2,
    inc_backoff/1,
    reset_backoff/1,

    delete_all/0
]).

-define(ETS_ROUTES, hpr_routes_ets).
-define(ETS_EUI_PAIRS, hpr_route_eui_pairs_ets).
-define(ETS_DEVADDR_RANGES, hpr_route_devaddr_ranges_ets).
%% -define(ETS_SKFS, hpr_route_skfs_ets).

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
    ok = hpr_route_storage:init_ets(),
    ok = hpr_devaddr_range_storage:init_ets(),
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
            ?MODULE:update_backoff(RouteID, {Now + Delay, Backoff});
        {ok, #hpr_route_ets{backoff = {_, Backoff0}}} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            ?MODULE:update_backoff(RouteID, {Now + Delay, Backoff1});
        {error, not_found} ->
            ok
    end.

-spec reset_backoff(RouteID :: hpr_route:id()) -> ok.
reset_backoff(RouteID) ->
    case hpr_route_storage:lookup(RouteID) of
        {ok, #hpr_route_ets{backoff = undefined}} ->
            ok;
        {ok, #hpr_route_ets{backoff = _}} ->
            ?MODULE:update_backoff(RouteID, undefined);
        {error, not_found} ->
            ok
    end.

-spec update_backoff(RouteID :: hpr_route:id(), Backoff :: backoff()) -> ok.
update_backoff(RouteID, Backoff) ->
    true = ets:update_element(?ETS_ROUTES, RouteID, {5, Backoff}),
    ok.

-spec delete_all() -> ok.
delete_all() ->
    ok = hpr_devaddr_range_storage:deletee_all(),
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
    {ok, RouteETS0} = ?MODULE:lookup_route(RouteID),
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
    {ok, RouteETS1} = ?MODULE:lookup_route(RouteID),
    ?assertEqual(RouteID, RouteETS1#hpr_route_ets.id),
    ?assertEqual(Route1, ?MODULE:route(RouteETS1)),
    SKFETS1 = ?MODULE:skf_ets(RouteETS0),
    ?assert(erlang:is_reference(SKFETS1)),
    ?assert(erlang:is_list(ets:info(SKFETS1))),
    ?assertEqual(SKFETS0, SKFETS1),
    ?assertEqual(undefined, ?MODULE:backoff(RouteETS1)),

    Backoff = {erlang:system_time(millisecond), backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX)},
    ?assertEqual(ok, ?MODULE:update_backoff(RouteID, Backoff)),
    {ok, RouteETS2} = ?MODULE:lookup_route(RouteID),
    ?assertEqual(Backoff, ?MODULE:backoff(RouteETS2)),

    %% Delete
    ?assertEqual(ok, ?MODULE:delete_route(Route1)),
    ?assertEqual({error, not_found}, ?MODULE:lookup_route(RouteID)),
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

    {ok, RouteETS1} = ?MODULE:lookup_route(RouteID1),
    {ok, RouteETS2} = ?MODULE:lookup_route(RouteID2),
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
