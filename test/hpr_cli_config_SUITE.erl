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
    sync_oui_only_test/1
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
        sync_oui_only_test
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
