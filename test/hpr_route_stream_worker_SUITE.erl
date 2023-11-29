-module(hpr_route_stream_worker_SUITE).

-include_lib("eunit/include/eunit.hrl").

-include("hpr_metrics.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    main_test/1,
    refresh_route_test/1,
    stream_crash_resume_updates_test/1,
    app_restart_rehydrate_test/1
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
        refresh_route_test,
        stream_crash_resume_updates_test,
        app_restart_rehydrate_test
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

app_restart_rehydrate_test(_Config) ->
    %% Fill up the app with a few config things.
    ?assertMatch(
        #{
            route := 0,
            eui_pair := 0,
            devaddr_range := 0,
            skf := 0
        },
        hpr_route_stream_worker:test_counts()
    ),

    CheckCounts = fun(
        RouteID,
        ExpectedRouteCount,
        ExpectedEUIPairCount,
        ExpectedDevaddrRangeCount,
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
                        {false, {route_not_found, RouteID}}
                end
            end
        )
    end,

    %% Create a bunch of data to ingest
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
    SessionKeyFilter1 = hpr_skf:new(#{
        route_id => Route1ID,
        devaddr => DevAddr1,
        session_key => SessionKey1,
        max_copies => 1
    }),

    hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route1}, timestamp => 100})
    ),
    timer:sleep(100),

    Updates1 = [
        hpr_route_stream_res:test_new(#{
            action => add, data => {eui_pair, EUIPair1}, timestamp => 100
        }),
        hpr_route_stream_res:test_new(#{
            action => add, data => {devaddr_range, DevAddrRange1}, timestamp => 100
        }),
        hpr_route_stream_res:test_new(#{
            action => add, data => {skf, SessionKeyFilter1}, timestamp => 100
        })
    ],
    [ok = hpr_test_iot_config_service_route:stream_resp(Update) || Update <- Updates1],
    ct:print("all updates sent"),
    timer:sleep(timer:seconds(1)),

    %% make sure all the data was received
    %% ok = timer:sleep(150),
    ok = CheckCounts(Route1ID, 1, 1, 1, 1),
    ?assertMatch(
        #{
            route := 1,
            eui_pair := 1,
            devaddr_range := 1,
            skf := 1
        },
        hpr_route_stream_worker:test_counts()
    ),

    %% Timestamps are inclusive, send a route update to bump the last timestamp
    hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route1}, timestamp => 150})
    ),
    ok = timer:sleep(150),
    ct:print("checkpointing"),
    %% Make sure the latest config timestamp is saved
    ok = hpr_route_stream_worker:checkpoint(),

    %% Stop the app.
    ct:print("stopping the app"),
    ok = application:stop(hpr),
    %% Restart the app.
    timer:sleep(100),
    ct:print("starting the app"),
    {ok, _} = application:ensure_all_started(hpr),
    ok = test_utils:wait_until(
        fun() ->
            Stream = hpr_route_stream_worker:test_stream(),
            %% {state, Stream, _Backoff} = sys:get_state(hpr_route_stream_worker),
            Stream =/= undefined andalso
                erlang:is_pid(erlang:whereis(hpr_test_iot_config_service_route))
        end,
        20,
        500
    ),
    ct:print("everything should be rehydrated"),
    %% Make sure the config is still there.
    ok = CheckCounts(Route1ID, 1, 1, 1, 1),
    %% And no new updates have been received.
    ?assertMatch(
        #{
            route := 0,
            eui_pair := 0,
            devaddr_range := 0,
            skf := 0
        },
        hpr_route_stream_worker:test_counts()
    ),

    ok.

stream_crash_resume_updates_test(_Config) ->
    %% The first time the stream worker starts up, it should ingest all available config.
    %% Then we kill it.
    %% Then we start it up again, and it should ingest only new available config.

    ?assertMatch(
        #{
            route := 0,
            eui_pair := 0,
            devaddr_range := 0,
            skf := 0
        },
        hpr_route_stream_worker:test_counts()
    ),

    CheckCounts = fun(
        RouteID,
        ExpectedRouteCount,
        ExpectedEUIPairCount,
        ExpectedDevaddrRangeCount,
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
                                {skf, ExpectedSKFCount, SKFCount}
                            ]
                        };
                    _ ->
                        false
                end
            end
        )
    end,

    %% Create a bunch of data to ingest
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
    SessionKeyFilter1 = hpr_skf:new(#{
        route_id => Route1ID,
        devaddr => DevAddr1,
        session_key => SessionKey1,
        max_copies => 1
    }),

    Updates1 = [
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route1}, timestamp => 100}),
        hpr_route_stream_res:test_new(#{
            action => add, data => {eui_pair, EUIPair1}, timestamp => 100
        }),
        hpr_route_stream_res:test_new(#{
            action => add, data => {devaddr_range, DevAddrRange1}, timestamp => 100
        }),
        hpr_route_stream_res:test_new(#{
            action => add, data => {skf, SessionKeyFilter1}, timestamp => 100
        })
    ],
    [ok = hpr_test_iot_config_service_route:stream_resp(Update) || Update <- Updates1],

    %% make sure all the data was received
    %% ok = timer:sleep(150),
    ok = CheckCounts(Route1ID, 1, 1, 1, 1),
    ?assertMatch(
        #{
            route := 1,
            eui_pair := 1,
            devaddr_range := 1,
            skf := 1
        },
        hpr_route_stream_worker:test_counts()
    ),

    %% Timestamps are inclusive, send a route update to bump the last timestamp
    hpr_test_iot_config_service_route:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route1}, timestamp => 150})
    ),
    ok = timer:sleep(150),
    %% Make sure the latest config timestamp is saved
    ok = hpr_route_stream_worker:checkpoint(),
    %% Kill the stream worker
    exit(whereis(hpr_route_stream_worker), kill),
    ok = test_utils:wait_until(
        fun() ->
            whereis(hpr_route_stream_worker) =/= undefined andalso
                erlang:is_process_alive(whereis(hpr_route_stream_worker)) andalso
                hpr_route_stream_worker:test_stream() =/= undefined andalso
                erlang:is_pid(erlang:whereis(hpr_test_iot_config_service_route))
        end,
        20,
        500
    ),

    %% Create a bunch of new data to ingest
    Route2ID = "7d502f32-4d58-4746-965e-002",
    Route2 = hpr_route:test_new(#{
        id => Route2ID,
        net_id => 0,
        oui => 1,
        server => #{
            host => "localhost",
            port => 8080,
            protocol => {packet_router, #{}}
        },
        max_copies => 10
    }),
    EUIPair2 = hpr_eui_pair:test_new(#{
        route_id => Route2ID, app_eui => 1, dev_eui => 0
    }),
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => Route2ID, start_addr => 16#00000001, end_addr => 16#0000000A
    }),
    DevAddr2 = 16#00000002,
    SessionKey2 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SessionKeyFilter2 = hpr_skf:new(#{
        route_id => Route2ID,
        devaddr => DevAddr2,
        session_key => SessionKey2,
        max_copies => 1
    }),

    %% Send the old data, and the new data
    Updates2 =
        Updates1 ++
            [
                hpr_route_stream_res:test_new(#{
                    action => add, data => {route, Route2}, timestamp => 200
                }),
                hpr_route_stream_res:test_new(#{
                    action => add, data => {eui_pair, EUIPair2}, timestamp => 200
                }),
                hpr_route_stream_res:test_new(#{
                    action => add, data => {devaddr_range, DevAddrRange2}, timestamp => 200
                }),
                hpr_route_stream_res:test_new(#{
                    action => add, data => {skf, SessionKeyFilter2}, timestamp => 200
                })
            ],
    [ok = hpr_test_iot_config_service_route:stream_resp(Update) || Update <- Updates2],

    %% make sure only the new data was received
    timer:sleep(timer:seconds(1)),
    %% NOTE: we expect 2 of everything, but skfs are checked per route.
    ok = CheckCounts(Route2ID, 2, 2, 2, 1),
    ?assertMatch(
        #{
            route := 1,
            eui_pair := 1,
            devaddr_range := 1,
            skf := 1
        },
        hpr_route_stream_worker:test_counts()
    ),

    ok.

main_test(_Config) ->
    CheckCounts = fun(
        RouteID,
        ExpectedRouteCount,
        ExpectedEUIPairCount,
        ExpectedDevaddrRangeCount,
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
                                {skf, ExpectedSKFCount, SKFCount}
                            ]
                        };
                    _ ->
                        false
                end
            end
        )
    end,

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
        hpr_route_stream_res:test_new(#{action => add, data => {skf, SessionKeyFilter}})
    ),

    %% Let time to process new routes
    ok = CheckCounts(Route1ID, 1, 1, 1, 1),
    %% ok = test_utils:wait_until(
    %%     fun() ->
    %%         case hpr_route_storage:lookup(Route1ID) of
    %%             {ok, RouteETS} ->
    %%                 1 =:= ets:info(hpr_routes_ets, size) andalso
    %%                     1 =:= ets:info(hpr_route_eui_pairs_ets, size) andalso
    %%                     1 =:= ets:info(hpr_route_devaddr_ranges_ets, size) andalso
    %%                     1 =:= ets:info(hpr_route_ets:skf_ets(RouteETS), size);
    %%             _ ->
    %%                 false
    %%         end
    %%     end
    %% ),

    ?assertEqual(
        1,
        prometheus_counter:value(?METRICS_ICS_UPDATES_COUNTER, [route, add])
    ),
    ?assertEqual(
        1,
        prometheus_counter:value(?METRICS_ICS_UPDATES_COUNTER, [eui_pair, add])
    ),
    ?assertEqual(
        1,
        prometheus_counter:value(?METRICS_ICS_UPDATES_COUNTER, [devaddr_range, add])
    ),
    ?assertEqual(
        1,
        prometheus_counter:value(?METRICS_ICS_UPDATES_COUNTER, [skf, add])
    ),

    {ok, RouteETS1} = hpr_route_storage:lookup(Route1ID),
    SKFETS1 = hpr_route_ets:skf_ets(RouteETS1),

    %% Check that we can query route via config
    ?assertMatch([RouteETS1], hpr_devaddr_range_storage:lookup(16#00000005)),
    ?assertEqual([RouteETS1], hpr_eui_pair_storage:lookup(1, 12)),
    ?assertEqual([RouteETS1], hpr_eui_pair_storage:lookup(1, 100)),
    ?assertEqual([], hpr_devaddr_range_storage:lookup(16#00000020)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(3, 3)),
    SK1 = hpr_utils:hex_to_bin(SessionKey1),
    ?assertMatch(
        [{SK1, 1}], hpr_skf_storage:lookup(SKFETS1, DevAddr1)
    ),

    %% Delete EUI Pairs / DevAddr Ranges / SKF
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => remove, data => {eui_pair, EUIPair1}})
    ),

    ok = test_utils:wait_until(
        fun() ->
            0 =:= ets:info(hpr_route_eui_pairs_ets, size)
        end
    ),

    ?assertEqual(
        1,
        prometheus_counter:value(?METRICS_ICS_UPDATES_COUNTER, [eui_pair, remove])
    ),

    ?assertEqual([], hpr_eui_pair_storage:lookup(1, 12)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(1, 100)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(3, 3)),

    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => remove, data => {devaddr_range, DevAddrRange1}})
    ),

    ok = test_utils:wait_until(
        fun() ->
            0 =:= ets:info(hpr_route_devaddr_ranges_ets, size)
        end
    ),

    ?assertEqual([], hpr_devaddr_range_storage:lookup(16#00000005)),
    ?assertEqual([], hpr_devaddr_range_storage:lookup(16#00000006)),
    ?assertEqual([], hpr_devaddr_range_storage:lookup(16#00000020)),

    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => remove, data => {skf, SessionKeyFilter}})
    ),

    ok = test_utils:wait_until(
        fun() ->
            0 =:= ets:info(SKFETS1, size)
        end
    ),

    ?assertEqual([], hpr_skf_storage:lookup(SKFETS1, DevAddr1)),

    %% Add back euis, ranges and skf to test full route delete
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {eui_pair, EUIPair1}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {devaddr_range, DevAddrRange1}})
    ),
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {skf, SessionKeyFilter}})
    ),
    ok = test_utils:wait_until(
        fun() ->
            case hpr_route_storage:lookup(Route1ID) of
                {ok, RouteETS} ->
                    1 =:= ets:info(hpr_routes_ets, size) andalso
                        1 =:= ets:info(hpr_route_eui_pairs_ets, size) andalso
                        1 =:= ets:info(hpr_route_devaddr_ranges_ets, size) andalso
                        1 =:= ets:info(hpr_route_ets:skf_ets(RouteETS), size);
                _ ->
                    false
            end
        end
    ),
    ?assertMatch([RouteETS1], hpr_devaddr_range_storage:lookup(16#00000005)),
    ?assertEqual([RouteETS1], hpr_eui_pair_storage:lookup(1, 12)),
    ?assertEqual([RouteETS1], hpr_eui_pair_storage:lookup(1, 100)),
    ?assertEqual([], hpr_devaddr_range_storage:lookup(16#00000020)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(3, 3)),
    SK1 = hpr_utils:hex_to_bin(SessionKey1),
    ?assertMatch(
        [{SK1, 1}], hpr_skf_storage:lookup(SKFETS1, DevAddr1)
    ),

    %% Remove route should delete eveything
    ok = hpr_test_ics_route_service:stream_resp(
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

    ?assertEqual([], hpr_devaddr_range_storage:lookup(16#00000005)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(1, 12)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(1, 100)),
    ?assertEqual([], hpr_devaddr_range_storage:lookup(16#00000020)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(3, 3)),

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

    %% Let time to process new routes
    ok = test_utils:wait_until(
        fun() ->
            case hpr_route_storage:lookup(Route1ID) of
                {ok, RouteETS} ->
                    RouteCount = ets:info(hpr_routes_ets, size),
                    EUIPairCount = ets:info(hpr_route_eui_pairs_ets, size),
                    DevaddrRangeCount = ets:info(hpr_route_devaddr_ranges_ets, size),
                    SKFCount = ets:info(hpr_route_ets:skf_ets(RouteETS), size),

                    ExpectedRouteCount = 1,
                    ExpectedEUIPairCount = 1,
                    ExpectedDevaddrRangeCount = 1,
                    ExpectedSKFCount = 1,

                    {
                        ExpectedRouteCount =:= RouteCount andalso
                            ExpectedEUIPairCount =:= EUIPairCount andalso
                            ExpectedDevaddrRangeCount =:= DevaddrRangeCount andalso
                            ExpectedSKFCount =:= SKFCount,
                        [
                            {route, ExpectedRouteCount, RouteCount},
                            {eui_pair, ExpectedEUIPairCount, EUIPairCount},
                            {devaddr_range, ExpectedDevaddrRangeCount, DevaddrRangeCount},
                            {skf, ExpectedSKFCount, SKFCount}
                        ]
                    };
                _ ->
                    false
            end
        end
    ),

    {ok, RouteETS1} = hpr_route_storage:lookup(Route1ID),
    SKFETS1 = hpr_route_ets:skf_ets(RouteETS1),

    %% Check that we can query route via config
    ?assertMatch([RouteETS1], hpr_devaddr_range_storage:lookup(16#00000005)),
    ?assertEqual([RouteETS1], hpr_eui_pair_storage:lookup(1, 12)),
    ?assertEqual([RouteETS1], hpr_eui_pair_storage:lookup(1, 100)),
    ?assertEqual([], hpr_devaddr_range_storage:lookup(16#00000020)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(3, 3)),
    SK1 = hpr_utils:hex_to_bin(SessionKey1),
    ?assertMatch(
        [{SK1, 1}], hpr_skf_storage:lookup(SKFETS1, DevAddr1)
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
    {ok, RouteETS2} = hpr_route_storage:lookup(Route1ID),
    SKFETS2 = hpr_route_ets:skf_ets(RouteETS2),

    %% Old routing is removed
    ?assertMatch([RouteETS2], hpr_devaddr_range_storage:lookup(16#00000005)),
    ?assertEqual([RouteETS2], hpr_eui_pair_storage:lookup(1, 12)),
    ?assertEqual([RouteETS2], hpr_eui_pair_storage:lookup(1, 100)),
    ?assertEqual([], hpr_devaddr_range_storage:lookup(16#00000020), "always out of range"),
    ?assertEqual([], hpr_eui_pair_storage:lookup(3, 3), "always out of range"),
    %% ?assertMatch([], hpr_skf_storage:lookup(SKFETS2, DevAddr1)),

    %% New details like magic
    ?assertMatch([RouteETS2], hpr_devaddr_range_storage:lookup(16#00000008)),
    ?assertEqual([RouteETS2], hpr_eui_pair_storage:lookup(2, 12)),
    ?assertEqual([RouteETS2], hpr_eui_pair_storage:lookup(2, 100)),
    SK2 = hpr_utils:hex_to_bin(SessionKey2),
    ?assertMatch(
        [{SK2, 1}], hpr_skf_storage:lookup(SKFETS2, DevAddr2)
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
    {ok, RouteETS3} = hpr_route_storage:lookup(Route1ID),
    SKFETS3 = hpr_route_ets:skf_ets(RouteETS3),
    ?assertMatch([], hpr_devaddr_range_storage:lookup(16#00000005)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(1, 12)),
    ?assertEqual([], hpr_eui_pair_storage:lookup(1, 100)),
    ?assertEqual([], hpr_devaddr_range_storage:lookup(16#00000020), "always out of range"),
    ?assertEqual([], hpr_eui_pair_storage:lookup(3, 3), "always out of range"),
    ?assertEqual([], hpr_skf_storage:lookup(SKFETS3, DevAddr1)),

    ok.
