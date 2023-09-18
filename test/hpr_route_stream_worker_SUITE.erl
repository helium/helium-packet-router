-module(hpr_route_stream_worker_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/iot_config_pb.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    main_test/1,
    refresh_route_test/1
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
        main_test,
        refresh_route_test
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

main_test(_Config) ->
    %% Let it startup
    timer:sleep(500),

    %% Create route and send them from server
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
    EUIPair1 = hpr_eui_pair:test_new(#{
        route_id => Route1ID, app_eui => 1, dev_eui => 0
    }),
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => Route1ID, start_addr => 16#00000001, end_addr => 16#0000000A
    }),
    DevAddr1 = 16#00000001,
    SessionKey1 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SessionKeyFilter = hpr_skf:new(#{
        route_id => Route1ID,
        devaddr => DevAddr1,
        session_key => SessionKey1,
        max_copies => 1
    }),
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route1}})
    ),
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {eui_pair, EUIPair1}})
    ),
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {devaddr_range, DevAddrRange1}})
    ),
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {skf, SessionKeyFilter}})
    ),

    %% Let time to process new routes
    ok = test_utils:wait_until(
        fun() ->
            case hpr_route_ets:lookup_route(Route1ID) of
                [RouteETS] ->
                    1 =:= ets:info(hpr_routes_ets, size) andalso
                        1 =:= ets:info(hpr_route_eui_pairs_ets, size) andalso
                        1 =:= ets:info(hpr_route_devaddr_ranges_ets, size) andalso
                        1 =:= ets:info(hpr_route_ets:skf_ets(RouteETS), size);
                _ ->
                    false
            end
        end
    ),

    [RouteETS1] = hpr_route_ets:lookup_route(Route1ID),
    SKFETS1 = hpr_route_ets:skf_ets(RouteETS1),

    %% Check that we can query route via config
    ?assertMatch([RouteETS1], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([RouteETS1], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([RouteETS1], hpr_route_ets:lookup_eui_pair(1, 100)),
    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000020)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(3, 3)),
    SK1 = hpr_utils:hex_to_bin(SessionKey1),
    ?assertMatch(
        [{SK1, 1}], hpr_route_ets:lookup_skf(SKFETS1, DevAddr1)
    ),

    %% Delete EUI Pairs / DevAddr Ranges / SKF
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => remove, data => {eui_pair, EUIPair1}})
    ),

    ok = test_utils:wait_until(
        fun() ->
            0 =:= ets:info(hpr_route_eui_pairs_ets, size)
        end
    ),

    ?assertEqual([], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(1, 100)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(3, 3)),

    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => remove, data => {devaddr_range, DevAddrRange1}})
    ),

    ok = test_utils:wait_until(
        fun() ->
            0 =:= ets:info(hpr_route_devaddr_ranges_ets, size)
        end
    ),

    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000006)),
    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000020)),

    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => remove, data => {skf, SessionKeyFilter}})
    ),

    ok = test_utils:wait_until(
        fun() ->
            0 =:= ets:info(SKFETS1, size)
        end
    ),

    ?assertEqual([], hpr_route_ets:lookup_skf(SKFETS1, DevAddr1)),

    %% Add back euis, ranges and skf to test full route delete
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {eui_pair, EUIPair1}})
    ),
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {devaddr_range, DevAddrRange1}})
    ),
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {skf, SessionKeyFilter}})
    ),
    ok = test_utils:wait_until(
        fun() ->
            case hpr_route_ets:lookup_route(Route1ID) of
                [RouteETS] ->
                    1 =:= ets:info(hpr_routes_ets, size) andalso
                        1 =:= ets:info(hpr_route_eui_pairs_ets, size) andalso
                        1 =:= ets:info(hpr_route_devaddr_ranges_ets, size) andalso
                        1 =:= ets:info(hpr_route_ets:skf_ets(RouteETS), size);
                _ ->
                    false
            end
        end
    ),
    ?assertMatch([RouteETS1], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([RouteETS1], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([RouteETS1], hpr_route_ets:lookup_eui_pair(1, 100)),
    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000020)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(3, 3)),
    SK1 = hpr_utils:hex_to_bin(SessionKey1),
    ?assertMatch(
        [{SK1, 1}], hpr_route_ets:lookup_skf(SKFETS1, DevAddr1)
    ),

    %% Remove route should delete eveything
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => remove, data => {route, Route1}})
    ),

    ok = test_utils:wait_until(
        fun() ->
            0 =:= ets:info(hpr_routes_ets, size) andalso
                0 =:= ets:info(hpr_route_eui_pairs_ets, size) andalso
                0 =:= ets:info(hpr_route_devaddr_ranges_ets, size) andalso
                undefined =:= ets:info(SKFETS1)
        end
    ),

    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(1, 100)),
    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000020)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(3, 3)),

    ok.

refresh_route_test(_Config) ->
    %% Create route and send them from server
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

    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route1}})
    ),
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {eui_pair, EUIPair1}})
    ),
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {devaddr_range, DevAddrRange1}})
    ),
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {skf, SessionKeyFilter1}})
    ),

    %% Let time to process new routes
    ok = test_utils:wait_until(
        fun() ->
            case hpr_route_ets:lookup_route(Route1ID) of
                [RouteETS] ->
                    1 =:= ets:info(hpr_routes_ets, size) andalso
                        1 =:= ets:info(hpr_route_eui_pairs_ets, size) andalso
                        1 =:= ets:info(hpr_route_devaddr_ranges_ets, size) andalso
                        1 =:= ets:info(hpr_route_ets:skf_ets(RouteETS), size);
                _ ->
                    false
            end
        end
    ),

    [RouteETS1] = hpr_route_ets:lookup_route(Route1ID),
    SKFETS1 = hpr_route_ets:skf_ets(RouteETS1),

    %% Check that we can query route via config
    ?assertMatch([RouteETS1], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([RouteETS1], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([RouteETS1], hpr_route_ets:lookup_eui_pair(1, 100)),
    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000020)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(3, 3)),
    SK1 = hpr_utils:hex_to_bin(SessionKey1),
    ?assertMatch(
        [{SK1, 1}], hpr_route_ets:lookup_skf(SKFETS1, DevAddr1)
    ),

    %% ===================================================================
    %% Setup different routing information
    EUIPair2 = hpr_eui_pair:test_new(#{route_id => Route1ID, app_eui => 2, dev_eui => 0}),
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => Route1ID, start_addr => 16#00000007, end_addr => 16#0000000A
    }),
    DevAddr2 = 16#00000008,
    SessionKey2 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SessionKeyFilter2 = hpr_skf:new(#{
        route_id => Route1ID, devaddr => DevAddr2, session_key => SessionKey2, max_copies => 1
    }),

    application:set_env(hpr, test_route_get_euis, [EUIPair1, EUIPair2]),
    application:set_env(hpr, test_route_get_devaddr_ranges, [DevAddrRange1, DevAddrRange2]),
    application:set_env(hpr, test_route_list_skfs, [SessionKeyFilter1, SessionKeyFilter2]),

    %% ===================================================================
    {ok, Answer} = hpr_route_stream_worker:refresh_route("7d502f32-4d58-4746-965e-001"),
    test_utils:match_map(
        #{
            eui_before => 1,
            eui_after => 2,
            eui_removed => 0,
            eui_added => 1,
            %%
            skf_before => 1,
            skf_after => 2,
            skf_removed => 0,
            skf_added => 1,
            %%
            devaddr_before => 1,
            devaddr_after => 2,
            devaddr_removed => 0,
            devaddr_added => 1
        },
        Answer
    ),
    [RouteETS2] = hpr_route_ets:lookup_route(Route1ID),
    SKFETS2 = hpr_route_ets:skf_ets(RouteETS2),

    %% Old routing is removed
    ?assertMatch([RouteETS2], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([RouteETS2], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([RouteETS2], hpr_route_ets:lookup_eui_pair(1, 100)),
    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000020), "always out of range"),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(3, 3), "always out of range"),
    %% ?assertMatch([], hpr_route_ets:lookup_skf(SKFETS2, DevAddr1)),

    %% New details like magic
    ?assertMatch([RouteETS2], hpr_route_ets:lookup_devaddr_range(16#00000008)),
    ?assertEqual([RouteETS2], hpr_route_ets:lookup_eui_pair(2, 12)),
    ?assertEqual([RouteETS2], hpr_route_ets:lookup_eui_pair(2, 100)),
    SK2 = hpr_utils:hex_to_bin(SessionKey2),
    ?assertMatch(
        [{SK2, 1}], hpr_route_ets:lookup_skf(SKFETS2, DevAddr2)
    ),

    %% ===================================================================
    %% empty everything out and refresh
    application:set_env(hpr, test_route_get_euis, []),
    application:set_env(hpr, test_route_get_devaddr_ranges, []),
    application:set_env(hpr, test_route_list_skfs, []),

    ?assertEqual(
        {ok, #{
            eui_before => 2,
            eui_after => 0,
            eui_removed => 2,
            eui_added => 0,
            %%
            skf_before => 2,
            skf_after => 0,
            skf_removed => 2,
            skf_added => 0,
            %%
            devaddr_before => 2,
            devaddr_after => 0,
            devaddr_removed => 2,
            devaddr_added => 0
        }},
        hpr_route_stream_worker:refresh_route("7d502f32-4d58-4746-965e-001")
    ),

    %% Everything was removed
    [RouteETS3] = hpr_route_ets:lookup_route(Route1ID),
    SKFETS3 = hpr_route_ets:skf_ets(RouteETS3),
    ?assertMatch([], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(1, 100)),
    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000020), "always out of range"),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(3, 3), "always out of range"),
    ?assertEqual([], hpr_route_ets:lookup_skf(SKFETS3, DevAddr1)),

    ok.
