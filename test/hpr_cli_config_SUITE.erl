-module(hpr_cli_config_SUITE).

-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    sync_new_route_test/1,
    sync_remove_route_test/1,
    sync_new_remove_route_test/1,
    sync_oui_only_test/1,
    route_activate_test/1,
    route_deactivate_test/1,
    oui_activate_test/1,
    oui_deactivate_test/1
]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        sync_new_route_test,
        sync_remove_route_test,
        sync_new_remove_route_test,
        sync_oui_only_test,
        route_activate_test,
        route_deactivate_test,
        oui_activate_test,
        oui_deactivate_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    meck:unload(),
    test_utils:end_per_testcase(TestCase, Config),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

sync_oui_only_test(_Config) ->
    application:set_env(hpr, test_org_service_orgs, [
        hpr_org:test_new(#{oui => 1}),
        hpr_org:test_new(#{oui => 2})
    ]),

    #{
        route_id := Route1ID,
        route := Route1,
        eui_pair := EUIPair1,
        devaddr_range := DevAddrRange1,
        skf := SessionKeyFilter1
    } = test_data("7d502f32-4d58-4746-965e-001"),

    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route1}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {eui_pair, EUIPair1}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {devaddr_range, DevAddrRange1}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {skf, SessionKeyFilter1}})
    ),
    ok = check_config_counts(Route1ID, 1, 1, 1, 1),

    %% Ensure a different route is setup to come back, removing the original,
    %% and adding the new.
    #{
        route_id := Route2ID,
        route := Route2,
        eui_pair := EUIPair2,
        devaddr_range := DevAddrRange2,
        skf := SessionKeyFilter2
    } = test_data("7d502f32-4d58-4746-965e-002", 2),
    application:set_env(hpr, test_route_list, [Route2]),
    application:set_env(hpr, test_route_get_euis, [EUIPair2]),
    application:set_env(hpr, test_route_get_devaddr_ranges, [DevAddrRange2]),
    application:set_env(hpr, test_route_list_skfs, [SessionKeyFilter2]),

    %% Syncing Routes removes the route that no longer exists
    [{list, _Output}] = hpr_cli_config:config_route_sync(["config", "route", "sync"], [], [
        {oui, "2"}
    ]),
    %% ct:print("~s", [_Output]),

    % Route 1 was not removed
    ok = check_config_counts(Route1ID, 2, 2, 2, 1),
    ok = check_config_counts(Route2ID, 2, 2, 2, 1),

    ok.

sync_new_route_test(_Config) ->
    application:set_env(hpr, test_org_service_orgs, [
        hpr_org:test_new(#{oui => 1}),
        hpr_org:test_new(#{oui => 2})
    ]),

    %% Route does not exist locally. It will be added when
    %% hpr_route_stream_worker:sync_routes() is called.
    #{
        route_id := RouteID,
        route := Route,
        eui_pair := EUIPair,
        devaddr := DevAddr,
        devaddr_range := DevAddrRange,
        session_key := SessionKey,
        skf := SessionKeyFilter
    } = test_data("7d502f32-4d58-4746-965e-001"),

    ok = application:set_env(hpr, test_route_list, [Route]),
    ok = application:set_env(hpr, test_route_get_euis, [EUIPair]),
    ok = application:set_env(hpr, test_route_get_devaddr_ranges, [DevAddrRange]),
    ok = application:set_env(hpr, test_route_list_skfs, [SessionKeyFilter]),

    [{list, _Output}] = hpr_cli_config:config_route_sync(["config", "route", "sync"], [], []),
    %% ct:print("~s", [_Output]),
    {ok, RouteETS} = hpr_route_storage:lookup(RouteID),

    ?assertEqual([RouteETS], hpr_devaddr_range_storage:lookup(16#00000005)),
    ?assertEqual([RouteETS], hpr_eui_pair_storage:lookup(1, 12)),
    SK1 = hpr_utils:hex_to_bin(SessionKey),
    SKFEts = hpr_route_ets:skf_ets(RouteETS),
    ?assertEqual([{SK1, 1}], hpr_skf_storage:lookup(SKFEts, DevAddr)),

    ok.

sync_new_remove_route_test(_Config) ->
    application:set_env(hpr, test_org_service_orgs, [
        hpr_org:test_new(#{oui => 1}),
        hpr_org:test_new(#{oui => 2})
    ]),

    #{
        route_id := Route1ID,
        route := Route1,
        eui_pair := EUIPair1,
        devaddr := DevAddr1,
        devaddr_range := DevAddrRange1,
        skf := SessionKeyFilter1
    } = test_data("7d502f32-4d58-4746-965e-001"),

    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route1}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {eui_pair, EUIPair1}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {devaddr_range, DevAddrRange1}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {skf, SessionKeyFilter1}})
    ),
    ok = check_config_counts(Route1ID, 1, 1, 1, 1),

    %% Ensure a different route is setup to come back, removing the original,
    %% and adding the new.
    #{
        route_id := Route2ID,
        route := Route2,
        eui_pair := EUIPair2,
        devaddr := DevAddr2,
        devaddr_range := DevAddrRange2,
        skf := SessionKeyFilter2
    } = test_data("7d502f32-4d58-4746-965e-002", 2),
    application:set_env(hpr, test_route_list, [Route2]),
    application:set_env(hpr, test_route_get_euis, [EUIPair2]),
    application:set_env(hpr, test_route_get_devaddr_ranges, [DevAddrRange2]),
    application:set_env(hpr, test_route_list_skfs, [SessionKeyFilter2]),

    %% Syncing Routes removes the route that no longer exists
    [{list, _Output}] = hpr_cli_config:config_route_sync(["config", "route", "sync"], [], []),
    %% ct:print("~s", [_Output]),
    ok = check_config_counts(Route2ID, 1, 1, 1, 1),

    ?assertEqual({error, not_found}, hpr_route_storage:lookup(Route1ID)),
    %% New route uses same values as the old one, except for ID.
    {ok, RouteETS2} = hpr_route_storage:lookup(Route2ID),
    ?assertEqual([RouteETS2], hpr_devaddr_range_storage:lookup(DevAddr1)),
    ?assertEqual([RouteETS2], hpr_eui_pair_storage:lookup(1, 12)),

    SK2_0 = hpr_skf:session_key(SessionKeyFilter2),
    SK2 = hpr_utils:hex_to_bin(SK2_0),
    SKFEts = hpr_route_ets:skf_ets(RouteETS2),
    ?assertEqual([{SK2, 1}], hpr_skf_storage:lookup(SKFEts, DevAddr2)),

    ok.

sync_remove_route_test(_Config) ->
    application:set_env(hpr, test_org_service_orgs, [
        hpr_org:test_new(#{oui => 1}),
        hpr_org:test_new(#{oui => 2})
    ]),

    Route1ID = "7d502f32-4d58-4746-965e-001",
    Route1 = hpr_route:test_new(#{
        id => Route1ID,
        net_id => 0,
        oui => 1,
        server => #{
            host => "localhost",
            port => 8080,
            protocol => {packet_router, #{}}
        },
        max_copies => 10
    }),
    EUIPair1 = hpr_eui_pair:test_new(#{route_id => Route1ID, app_eui => 1, dev_eui => 0}),
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => Route1ID, start_addr => 16#00000001, end_addr => 16#0000000A
    }),
    DevAddr1 = 16#00000001,
    SessionKey1 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SessionKeyFilter1 = hpr_skf:new(#{
        route_id => Route1ID, devaddr => DevAddr1, session_key => SessionKey1, max_copies => 1
    }),

    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route1}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {eui_pair, EUIPair1}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {devaddr_range, DevAddrRange1}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {skf, SessionKeyFilter1}})
    ),
    ok = check_config_counts(Route1ID, 1, 1, 1, 1),

    %% Ensure nothing is meant to come back from the config service when syncing.
    application:set_env(hpr, test_route_list, []),
    application:set_env(hpr, test_route_get_euis, []),
    application:set_env(hpr, test_route_get_devaddr_ranges, []),
    application:set_env(hpr, test_route_list_skfs, []),

    %% Syncing Routes removes the route that no longer exists
    [{list, _Output}] = hpr_cli_config:config_route_sync(["config", "route", "sync"], [], []),
    %% ct:print("~s", [_Output]),
    ?assertEqual({error, not_found}, hpr_route_storage:lookup(Route1ID)),
    ?assertEqual([], hpr_devaddr_range_storage:lookup(DevAddr1)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(1, 12)),
    ?assertEqual([], hpr_skf_storage:lookup_route(Route1ID)),

    ok.

route_deactivate_test(_Config) ->
    %% Setup: Create a route with SKFs, EUIs, and DevAddr ranges
    #{
        route_id := RouteID,
        route := Route,
        eui_pair := EUIPair,
        devaddr := DevAddr,
        devaddr_range := DevAddrRange,
        skf := SessionKeyFilter
    } = test_data("route-deactivate-test-001"),

    %% Insert route and all its data
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {eui_pair, EUIPair}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {devaddr_range, DevAddrRange}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {skf, SessionKeyFilter}})
    ),

    %% Verify data exists
    ok = check_config_counts(RouteID, 1, 1, 1, 1),
    {ok, RouteETSBefore} = hpr_route_storage:lookup(RouteID),
    ?assert(hpr_route:active(hpr_route_ets:route(RouteETSBefore))),

    %% Deactivate the route
    [{text, [_Text]}] = hpr_cli_config:config_route_deactivate(
        ["config", "route", "deactivate", RouteID],
        [],
        []
    ),

    %% Verify route is deactivated and data is removed
    {ok, RouteETSAfter} = hpr_route_storage:lookup(RouteID),
    RouteAfter = hpr_route_ets:route(RouteETSAfter),
    ?assertNot(hpr_route:active(RouteAfter)),

    %% Verify all EUIs and DevAddr ranges are removed
    %% Note: We can't check SKFs directly as the ETS table is deleted
    ?assertEqual([], hpr_devaddr_range_storage:lookup(DevAddr)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(1, 0)),

    ok.

route_activate_test(_Config) ->
    %% Setup: Create a deactivated route
    RouteID = "route-activate-test-001",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 0,
        oui => 1,
        server => #{
            host => "localhost",
            port => 8080,
            protocol => {packet_router, #{}}
        },
        max_copies => 10,
        active => false
    }),

    %% Insert deactivated route
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route}})
    ),

    %% Verify route exists and is deactivated
    ok = test_utils:wait_until(fun() ->
        case hpr_route_storage:lookup(RouteID) of
            {ok, RouteETS} ->
                not hpr_route:active(hpr_route_ets:route(RouteETS));
            _ ->
                false
        end
    end),

    %% Setup test data to be returned by refresh
    EUIPair = hpr_eui_pair:test_new(#{route_id => RouteID, app_eui => 1, dev_eui => 0}),
    DevAddrRange = hpr_devaddr_range:test_new(#{
        route_id => RouteID, start_addr => 16#00000001, end_addr => 16#0000000A
    }),
    DevAddr = 16#00000001,
    SessionKey = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SessionKeyFilter = hpr_skf:new(#{
        route_id => RouteID, devaddr => DevAddr, session_key => SessionKey, max_copies => 1
    }),

    application:set_env(hpr, test_route_get_euis, [EUIPair]),
    application:set_env(hpr, test_route_get_devaddr_ranges, [DevAddrRange]),
    application:set_env(hpr, test_route_list_skfs, [SessionKeyFilter]),

    %% Activate the route
    [{text, [_Text]}] = hpr_cli_config:config_route_activate(
        ["config", "route", "activate", RouteID],
        [],
        []
    ),

    %% Verify route is activated
    ok = test_utils:wait_until(fun() ->
        case hpr_route_storage:lookup(RouteID) of
            {ok, RouteETS} ->
                hpr_route:active(hpr_route_ets:route(RouteETS));
            _ ->
                false
        end
    end),

    %% Verify data was refreshed (SKFs, EUIs, DevAddr ranges added)
    ok = check_config_counts(RouteID, 1, 1, 1, 1),

    ok.

oui_deactivate_test(_Config) ->
    %% Setup: Create multiple routes for the same OUI
    OUI = 100,
    #{
        route_id := RouteID1,
        route := Route1,
        eui_pair := EUIPair1,
        devaddr_range := DevAddrRange1,
        skf := SKF1
    } = test_data("oui-deactivate-test-001", OUI),

    #{
        route_id := RouteID2,
        route := Route2,
        eui_pair := EUIPair2,
        devaddr_range := DevAddrRange2,
        skf := SKF2
    } = test_data("oui-deactivate-test-002", OUI),

    %% Insert both routes and their data
    lists:foreach(
        fun({Route, EUIPair, DevAddrRange, SKF}) ->
            ok = hpr_test_ics_route_service:stream_resp(
                hpr_route_stream_res:test_new(#{action => add, data => {route, Route}})
            ),
            ok = hpr_test_ics_route_service:stream_resp(
                hpr_route_stream_res:test_new(#{action => add, data => {eui_pair, EUIPair}})
            ),
            ok = hpr_test_ics_route_service:stream_resp(
                hpr_route_stream_res:test_new(#{
                    action => add, data => {devaddr_range, DevAddrRange}
                })
            ),
            ok = hpr_test_ics_route_service:stream_resp(
                hpr_route_stream_res:test_new(#{action => add, data => {skf, SKF}})
            )
        end,
        [{Route1, EUIPair1, DevAddrRange1, SKF1}, {Route2, EUIPair2, DevAddrRange2, SKF2}]
    ),

    %% Verify both routes exist with data
    ok = check_config_counts(RouteID1, 2, 2, 2, 1),
    ok = check_config_counts(RouteID2, 2, 2, 2, 1),

    %% Deactivate all routes for the OUI
    [{text, [_Text]}] = hpr_cli_config:config_oui_deactivate(
        ["config", "oui", "deactivate", integer_to_list(OUI)],
        [],
        []
    ),

    %% Verify both routes are deactivated and data is removed
    ok = test_utils:wait_until(fun() ->
        case {hpr_route_storage:lookup(RouteID1), hpr_route_storage:lookup(RouteID2)} of
            {{ok, ETS1}, {ok, ETS2}} ->
                Route1After = hpr_route_ets:route(ETS1),
                Route2After = hpr_route_ets:route(ETS2),
                not hpr_route:active(Route1After) andalso not hpr_route:active(Route2After);
            _ ->
                false
        end
    end),

    %% Verify all EUIs and DevAddr ranges are removed
    %% Note: We can't check SKFs directly as the ETS tables are deleted
    ?assertEqual(0, ets:info(hpr_route_eui_pairs_ets, size)),
    ?assertEqual(0, ets:info(hpr_route_devaddr_ranges_ets, size)),

    ok.

oui_activate_test(_Config) ->
    %% Setup: Create multiple deactivated routes for the same OUI
    OUI = 200,
    RouteID1 = "oui-activate-test-001",
    Route1 = hpr_route:test_new(#{
        id => RouteID1,
        net_id => 0,
        oui => OUI,
        server => #{
            host => "localhost",
            port => 8080,
            protocol => {packet_router, #{}}
        },
        max_copies => 10,
        active => false
    }),

    RouteID2 = "oui-activate-test-002",
    Route2 = hpr_route:test_new(#{
        id => RouteID2,
        net_id => 0,
        oui => OUI,
        server => #{
            host => "localhost",
            port => 8081,
            protocol => {packet_router, #{}}
        },
        max_copies => 10,
        active => false
    }),

    %% Insert both deactivated routes
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route1}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route2}})
    ),

    %% Verify routes exist and are deactivated
    ok = test_utils:wait_until(fun() ->
        case {hpr_route_storage:lookup(RouteID1), hpr_route_storage:lookup(RouteID2)} of
            {{ok, ETS1}, {ok, ETS2}} ->
                Route1Check = hpr_route_ets:route(ETS1),
                Route2Check = hpr_route_ets:route(ETS2),
                not hpr_route:active(Route1Check) andalso not hpr_route:active(Route2Check);
            _ ->
                false
        end
    end),

    %% Setup test data to be returned by refresh for both routes
    EUIPair1 = hpr_eui_pair:test_new(#{route_id => RouteID1, app_eui => 1, dev_eui => 0}),
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000001, end_addr => 16#0000000A
    }),
    SKF1 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => 16#00000001,
        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
        max_copies => 1
    }),

    EUIPair2 = hpr_eui_pair:test_new(#{route_id => RouteID2, app_eui => 2, dev_eui => 1}),
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => RouteID2, start_addr => 16#0000000B, end_addr => 16#00000014
    }),
    SKF2 = hpr_skf:new(#{
        route_id => RouteID2,
        devaddr => 16#0000000B,
        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
        max_copies => 1
    }),

    application:set_env(hpr, test_route_get_euis, [EUIPair1, EUIPair2]),
    application:set_env(hpr, test_route_get_devaddr_ranges, [DevAddrRange1, DevAddrRange2]),
    application:set_env(hpr, test_route_list_skfs, [SKF1, SKF2]),

    %% Activate all routes for the OUI
    [{text, [_Text]}] = hpr_cli_config:config_oui_activate(
        ["config", "oui", "activate", integer_to_list(OUI)],
        [],
        []
    ),

    %% Verify both routes are activated
    ok = test_utils:wait_until(fun() ->
        case {hpr_route_storage:lookup(RouteID1), hpr_route_storage:lookup(RouteID2)} of
            {{ok, ETS1}, {ok, ETS2}} ->
                Route1After = hpr_route_ets:route(ETS1),
                Route2After = hpr_route_ets:route(ETS2),
                hpr_route:active(Route1After) andalso hpr_route:active(Route2After);
            _ ->
                false
        end
    end),

    %% Verify data was refreshed for both routes
    %% Note: Both routes will get all the test data since we set it globally
    ok = test_utils:wait_until(fun() ->
        case {hpr_route_storage:lookup(RouteID1), hpr_route_storage:lookup(RouteID2)} of
            {{ok, ETS1}, {ok, ETS2}} ->
                %% Just verify that some data was added
                SKFCount1 = ets:info(hpr_route_ets:skf_ets(ETS1), size),
                SKFCount2 = ets:info(hpr_route_ets:skf_ets(ETS2), size),
                EUICount = ets:info(hpr_route_eui_pairs_ets, size),
                DevAddrCount = ets:info(hpr_route_devaddr_ranges_ets, size),
                SKFCount1 > 0 andalso SKFCount2 > 0 andalso EUICount > 0 andalso DevAddrCount > 0;
            _ ->
                false
        end
    end),

    ok.

%% ===================================================================
%% Helpers
%% ===================================================================

test_data(RouteID) ->
    test_data(RouteID, 1).

test_data(RouteID, OUI) ->
    Route1 = hpr_route:test_new(#{
        id => RouteID,
        net_id => 0,
        oui => OUI,
        server => #{
            host => "localhost",
            port => 8080,
            protocol => {packet_router, #{}}
        },
        max_copies => 10
    }),
    EUIPair1 = hpr_eui_pair:test_new(#{
        route_id => RouteID, app_eui => 1, dev_eui => 0
    }),
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID, start_addr => 16#00000001, end_addr => 16#0000000A
    }),
    DevAddr1 = 16#00000001,
    SessionKey1 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SessionKeyFilter1 = hpr_skf:new(#{
        route_id => RouteID,
        devaddr => DevAddr1,
        session_key => SessionKey1,
        max_copies => 1
    }),
    #{
        route_id => RouteID,
        route => Route1,
        eui_pair => EUIPair1,
        devaddr => DevAddr1,
        devaddr_range => DevAddrRange1,
        session_key => SessionKey1,
        skf => SessionKeyFilter1
    }.

check_config_counts(
    RouteID,
    ExpectedRouteCount,
    ExpectedEUIPairCount,
    ExpectedDevaddrRangeCount,
    %% NOTE: SKF are separated by Route, provide amount expected for RouteID
    ExpectedSKFCount
) ->
    ok = test_utils:wait_until(
        fun() ->
            case hpr_route_storage:lookup(RouteID) of
                {ok, RouteETS} ->
                    RouteCount = ets:info(hpr_routes_ets, size),
                    EUIPairCount = ets:info(hpr_route_eui_pairs_ets, size),
                    DevaddrRangeCount = ets:info(hpr_route_devaddr_ranges_ets, size),
                    SKFCount = ets:info(hpr_route_ets:skf_ets(RouteETS), size),

                    {
                        ExpectedRouteCount =:= RouteCount andalso
                            ExpectedEUIPairCount =:= EUIPairCount andalso
                            ExpectedDevaddrRangeCount =:= DevaddrRangeCount andalso
                            ExpectedSKFCount =:= SKFCount,
                        [
                            {route_id, RouteID},
                            {route, ExpectedRouteCount, RouteCount},
                            {eui_pair, ExpectedEUIPairCount, EUIPairCount},
                            {devaddr_range, ExpectedDevaddrRangeCount, DevaddrRangeCount},
                            {skf, ExpectedSKFCount, SKFCount},
                            {skf_items, ets:tab2list(hpr_route_ets:skf_ets(RouteETS))}
                        ]
                    };
                _ ->
                    {false, {route_not_found, RouteID},
                        {all_routes, [hpr_route_storage:all_routes()]}}
            end
        end
    ).
