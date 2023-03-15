-module(hpr_route_stream_worker_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/iot_config_pb.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    create_route_test/1,
    update_route_test/1,
    delete_route_test/1
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
        create_route_test,
        update_route_test,
        delete_route_test
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

create_route_test(_Config) ->
    %% Let it startup
    timer:sleep(500),

    %% Create route and send them from server
    RouteID = "7d502f32-4d58-4746-965e-001",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 0,
        oui => 1,
        server => #{
            host => "localhost",
            port => 8080,
            protocol => {packet_router, #{}}
        },
        max_copies => 1
    }),
    EUIPair = hpr_eui_pair:test_new(#{
        route_id => RouteID, app_eui => 1, dev_eui => 0
    }),
    DevAddrRange = hpr_devaddr_range:test_new(#{
        route_id => RouteID, start_addr => 16#00000001, end_addr => 16#0000000A
    }),

    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route}})
    ),

    %% Let time to process new routes
    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_route_ets_routes, size)
        end
    ),

    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {eui_pair, EUIPair}})
    ),

    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {devaddr_range, DevAddrRange}})
    ),

    %% Let time to process new routes
    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_route_ets_eui_pairs, size)
        end
    ),

    %% Let time to process new routes

    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_route_ets_devaddr_ranges, size)
        end
    ),

    %% Check that we can query route via config
    ?assertEqual(
        [Route], hpr_route_ets:lookup_devaddr_range(16#00000005)
    ),
    ?assertEqual([Route], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([Route], hpr_route_ets:lookup_eui_pair(1, 100)),
    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000020)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(3, 3)),
    ok.

update_route_test(_Config) ->
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
        max_copies => 1
    }),
    EUIPair1 = hpr_eui_pair:test_new(#{
        route_id => Route1ID, app_eui => 1, dev_eui => 0
    }),
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => Route1ID, start_addr => 16#00000001, end_addr => 16#0000000A
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

    %% Let time to process new route
    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_route_ets_routes, size)
        end
    ),

    %% Check that we can query route via config
    ?assertEqual([Route1], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([Route1], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([Route1], hpr_route_ets:lookup_eui_pair(1, 100)),

    %% Update our Route
    EUIPair2 = hpr_eui_pair:test_new(#{
        route_id => Route1ID, app_eui => 2, dev_eui => 2
    }),
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => Route1ID, start_addr => 16#0000000B, end_addr => 16#0000000C
    }),

    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {eui_pair, EUIPair2}})
    ),

    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {devaddr_range, DevAddrRange2}})
    ),

    ok = test_utils:wait_until(
        fun() ->
            2 =:= ets:info(hpr_route_ets_eui_pairs, size)
        end
    ),

    %% Check that we can query route via config
    ?assertEqual([Route1], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([Route1], hpr_route_ets:lookup_devaddr_range(16#0000000B)),
    ?assertEqual([Route1], hpr_route_ets:lookup_devaddr_range(16#0000000C)),
    ?assertEqual([Route1], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([Route1], hpr_route_ets:lookup_eui_pair(1, 100)),
    ?assertEqual([Route1], hpr_route_ets:lookup_eui_pair(2, 2)),

    ok.

delete_route_test(_Config) ->
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
        max_copies => 1
    }),
    EUIPair1 = hpr_eui_pair:test_new(#{
        route_id => Route1ID, app_eui => 1, dev_eui => 0
    }),
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => Route1ID, start_addr => 16#00000001, end_addr => 16#0000000A
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

    %% Let time to process new routes
    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_route_ets_routes, size)
        end
    ),

    %% Check that we can query route via config
    ?assertEqual([Route1], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([Route1], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([Route1], hpr_route_ets:lookup_eui_pair(1, 100)),

    %% Delete EUI Pairs / DevAddr Ranges
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => remove, data => {eui_pair, EUIPair1}})
    ),

    ok = test_utils:wait_until(
        fun() ->
            0 =:= ets:info(hpr_route_ets_eui_pairs, size)
        end
    ),

    ?assertEqual([], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(1, 100)),

    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => remove, data => {devaddr_range, DevAddrRange1}})
    ),

    ok = test_utils:wait_until(
        fun() ->
            0 =:= ets:info(hpr_route_ets_devaddr_ranges, size)
        end
    ),

    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000006)),

    %% Add back euis and ranges to test full route delete
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {eui_pair, EUIPair1}})
    ),
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {devaddr_range, DevAddrRange1}})
    ),
    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_route_ets_eui_pairs, size) andalso
                1 =:= ets:info(hpr_route_ets_devaddr_ranges, size)
        end
    ),
    ?assertEqual([Route1], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([Route1], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([Route1], hpr_route_ets:lookup_eui_pair(1, 100)),

    %% Remove route should delete eveything
    ok = hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => remove, data => {route, Route1}})
    ),

    ok = test_utils:wait_until(
        fun() ->
            0 =:= ets:info(hpr_route_ets_routes, size)
        end
    ),

    ok = test_utils:wait_until(
        fun() ->
            0 =:= ets:info(hpr_route_ets_eui_pairs, size)
        end
    ),

    ok = test_utils:wait_until(
        fun() ->
            0 =:= ets:info(hpr_route_ets_devaddr_ranges, size)
        end
    ),

    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(1, 100)),

    ok.
