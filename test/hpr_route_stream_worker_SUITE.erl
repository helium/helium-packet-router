-module(hpr_route_stream_worker_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/iot_config_pb.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    main_test/1
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
        main_test
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
    SessionKeyFilter = hpr_skf:test_new(#{
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
            1 =:= ets:info(hpr_routes_ets, size) andalso
                1 =:= ets:info(hpr_route_eui_pairs_ets, size) andalso
                1 =:= ets:info(hpr_route_devaddr_ranges_ets, size) andalso
                1 =:= ets:info(hpr_route_skfs_ets, size)
        end
    ),

    %% Check that we can query route via config
    ?assertEqual([Route1], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([Route1], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([Route1], hpr_route_ets:lookup_eui_pair(1, 100)),
    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000020)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(3, 3)),
    ?assertEqual(
        [{hpr_utils:hex_to_bin(SessionKey1), Route1ID, 1}], hpr_route_ets:lookup_skf(DevAddr1)
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
            0 =:= ets:info(hpr_route_skfs_ets, size)
        end
    ),

    ?assertEqual([], hpr_route_ets:lookup_skf(DevAddr1)),

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
            1 =:= ets:info(hpr_routes_ets, size) andalso
                1 =:= ets:info(hpr_route_eui_pairs_ets, size) andalso
                1 =:= ets:info(hpr_route_devaddr_ranges_ets, size) andalso
                1 =:= ets:info(hpr_route_skfs_ets, size)
        end
    ),
    ?assertEqual([Route1], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([Route1], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([Route1], hpr_route_ets:lookup_eui_pair(1, 100)),
    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000020)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(3, 3)),
    ?assertEqual(
        [{hpr_utils:hex_to_bin(SessionKey1), Route1ID, 1}], hpr_route_ets:lookup_skf(DevAddr1)
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
                0 =:= ets:info(hpr_route_skfs_ets, size)
        end
    ),

    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000005)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(1, 12)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(1, 100)),
    ?assertEqual([], hpr_route_ets:lookup_devaddr_range(16#00000020)),
    ?assertEqual([], hpr_route_ets:lookup_eui_pair(3, 3)),
    ?assertEqual([], hpr_route_ets:lookup_skf(DevAddr1)),

    ok.
