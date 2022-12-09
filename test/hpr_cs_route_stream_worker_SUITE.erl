-module(hpr_cs_route_stream_worker_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/config_pb.hrl").

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

create_route_test(Config) ->
    %% Let it startup
    timer:sleep(500),

    %% Create route and send them from server
    Route = hpr_route:test_new(#{
        id => "7d502f32-4d58-4746-965e-001",
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A}
        ],
        euis => [#{app_eui => 1, dev_eui => 0}],
        oui => 1,
        server => #{
            host => "localhost",
            port => 8080,
            protocol => {packet_router, #{}}
        },
        max_copies => 1,
        nonce => 1
    }),

    ok = hpr_test_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => create, route => Route})
    ),

    %% Let time to process new routes
    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_route_ets_routes, size)
        end
    ),

    %% Check backup file
    FilePath = proplists:get_value(router_worker_file_backup_path, Config),
    case file:read_file(FilePath) of
        {ok, Binary} ->
            Map = erlang:binary_to_term(Binary),
            ?assertEqual(Route, maps:get(hpr_route:id(Route), Map));
        {error, Reason} ->
            ct:fail(Reason)
    end,

    %% Check that we can query route via config
    ?assertEqual(
        [hpr_route_ets:remove_euis_dev_ranges(Route)], hpr_route_ets:lookup_devaddr(16#00000005)
    ),
    ?assertEqual([hpr_route_ets:remove_euis_dev_ranges(Route)], hpr_route_ets:lookup_eui(1, 12)),
    ?assertEqual([hpr_route_ets:remove_euis_dev_ranges(Route)], hpr_route_ets:lookup_eui(1, 100)),
    ?assertEqual([], hpr_route_ets:lookup_devaddr(16#00000020)),
    ?assertEqual([], hpr_route_ets:lookup_eui(3, 3)),
    ok.

update_route_test(Config) ->
    %% Let it startup
    timer:sleep(500),

    %% Create route and send them from server
    Route1Map = #{
        id => "7d502f32-4d58-4746-965e-001",
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A}
        ],
        euis => [#{app_eui => 1, dev_eui => 0}],
        oui => 1,
        server => #{
            host => "localhost",
            port => 8080,
            protocol => {packet_router, #{}}
        },
        max_copies => 1,
        nonce => 1
    },
    Route1 = hpr_route:test_new(Route1Map),
    ok = hpr_test_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => create, route => Route1})
    ),

    %% Let time to process new routes
    FilePath = proplists:get_value(router_worker_file_backup_path, Config),
    ok = test_utils:wait_until(
        fun() ->
            case file:read_file(FilePath) of
                {ok, Binary} ->
                    Map = erlang:binary_to_term(Binary),
                    Route1 =:= maps:get(hpr_route:id(Route1), Map, undefined);
                {error, _Reason} ->
                    false
            end
        end
    ),

    %% Check that we can query route via config
    ?assertEqual(
        [hpr_route_ets:remove_euis_dev_ranges(Route1)], hpr_route_ets:lookup_devaddr(16#00000005)
    ),
    ?assertEqual([hpr_route_ets:remove_euis_dev_ranges(Route1)], hpr_route_ets:lookup_eui(1, 12)),
    ?assertEqual([hpr_route_ets:remove_euis_dev_ranges(Route1)], hpr_route_ets:lookup_eui(1, 100)),

    %% Update our Route
    Route2Map = Route1Map#{
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A},
            #{start_addr => 16#0000000B, end_addr => 16#0000000C}
        ],
        euis => [#{app_eui => 2, dev_eui => 2}],
        nonce => 2
    },
    Route2 = hpr_route:test_new(Route2Map),
    ok = hpr_test_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => update, route => Route2})
    ),

    ok = test_utils:wait_until(
        fun() ->
            case file:read_file(FilePath) of
                {ok, Binary} ->
                    Map = erlang:binary_to_term(Binary),
                    Route2 =:= maps:get(hpr_route:id(Route2), Map, undefined);
                {error, _Reason} ->
                    false
            end
        end
    ),

    %% Check that we can query route via config
    ?assertEqual(
        [hpr_route_ets:remove_euis_dev_ranges(Route2)], hpr_route_ets:lookup_devaddr(16#00000005)
    ),
    ?assertEqual(
        [hpr_route_ets:remove_euis_dev_ranges(Route2)], hpr_route_ets:lookup_devaddr(16#0000000B)
    ),
    ?assertEqual(
        [hpr_route_ets:remove_euis_dev_ranges(Route2)], hpr_route_ets:lookup_devaddr(16#0000000C)
    ),
    ?assertEqual([], hpr_route_ets:lookup_eui(1, 12)),
    ?assertEqual([], hpr_route_ets:lookup_eui(1, 100)),
    ?assertEqual([hpr_route_ets:remove_euis_dev_ranges(Route2)], hpr_route_ets:lookup_eui(2, 2)),

    ok.

delete_route_test(Config) ->
    %% Let it startup
    timer:sleep(500),

    %% Create route and send them from server
    Route1Map = #{
        id => "7d502f32-4d58-4746-965e-001",
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A}
        ],
        euis => [#{app_eui => 1, dev_eui => 0}],
        oui => 1,
        server => #{
            host => "localhost",
            port => 8080,
            protocol => {packet_router, #{}}
        },
        max_copies => 1,
        nonce => 1
    },
    Route1 = hpr_route:test_new(Route1Map),
    ok = hpr_test_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => create, route => Route1})
    ),

    %% Let time to process new routes
    FilePath = proplists:get_value(router_worker_file_backup_path, Config),
    ok = test_utils:wait_until(
        fun() ->
            case file:read_file(FilePath) of
                {ok, Binary} ->
                    Map = erlang:binary_to_term(Binary),
                    Route1 =:= maps:get(hpr_route:id(Route1), Map, undefined);
                {error, _Reason} ->
                    false
            end
        end
    ),

    %% Check that we can query route via config
    ?assertEqual(
        [hpr_route_ets:remove_euis_dev_ranges(Route1)], hpr_route_ets:lookup_devaddr(16#00000005)
    ),
    ?assertEqual([hpr_route_ets:remove_euis_dev_ranges(Route1)], hpr_route_ets:lookup_eui(1, 12)),
    ?assertEqual([hpr_route_ets:remove_euis_dev_ranges(Route1)], hpr_route_ets:lookup_eui(1, 100)),

    %% Delete our Route

    ok = hpr_test_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => delete, route => Route1})
    ),

    ok = test_utils:wait_until(
        fun() ->
            case file:read_file(FilePath) of
                {ok, Binary} ->
                    Map = erlang:binary_to_term(Binary),
                    0 =:= maps:size(Map);
                {error, _Reason} ->
                    false
            end
        end
    ),

    %% Check that we can query route via config
    ?assertEqual(
        [], hpr_route_ets:lookup_devaddr(16#00000005)
    ),
    ?assertEqual([], hpr_route_ets:lookup_eui(1, 12)),
    ?assertEqual([], hpr_route_ets:lookup_eui(1, 100)),
    ?assertEqual(0, ets:info(hpr_route_ets_routes_by_devaddr, size)),
    ?assertEqual(0, ets:info(hpr_route_ets_routes_by_eui, size)),
    ?assertEqual(0, ets:info(hpr_route_ets_routes, size)),

    ok.

%% ===================================================================
%% Helpers
%% ===================================================================
