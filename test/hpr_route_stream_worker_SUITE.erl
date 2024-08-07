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
    reset_stream_test/1,
    reset_channel_test/1,
    app_restart_rehydrate_test/1,
    route_remove_delete_skf_dets_test/1
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
        reset_stream_test,
        reset_channel_test,
        app_restart_rehydrate_test,
        route_remove_delete_skf_dets_test
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

route_remove_delete_skf_dets_test(_Config) ->
    #{
        route_id := Route1ID,
        route := Route1,
        eui_pair := EUIPair1,
        devaddr_range := DevAddrRange1,
        skf := SessionKeyFilter1
    } = test_data("7d502f32-4d58-4746-965e-001"),
    #{
        route_id := Route2ID,
        route := Route2,
        eui_pair := EUIPair2,
        devaddr_range := DevAddrRange2,
        skf := SessionKeyFilter2
    } = test_data("7d502f32-4d58-4746-965e-002"),

    Updates0 = [
        {route, Route1},
        {eui_pair, EUIPair1},
        {devaddr_range, DevAddrRange1},
        {skf, SessionKeyFilter1},
        {route, Route2},
        {eui_pair, EUIPair2},
        {devaddr_range, DevAddrRange2},
        {skf, SessionKeyFilter2}
    ],
    Updates = [
        hpr_route_stream_res:test_new(#{
            action => add, data => Data, timestamp => 100
        })
     || Data <- Updates0
    ],
    [ok = hpr_test_ics_route_service:stream_resp(Update) || Update <- Updates],
    timer:sleep(20),

    ok = check_config_counts(Route1ID, 2, 2, 2, 1),
    ok = check_config_counts(Route2ID, 2, 2, 2, 1),

    Route1SKFFileName = hpr_skf_storage:dets_filename(Route1ID),
    Route2SKFFileName = hpr_skf_storage:dets_filename(Route2ID),

    ?assert(filelib:is_file(Route1SKFFileName)),
    ?assert(filelib:is_file(Route2SKFFileName)),

    %% Remove a route and ensure the skf file is removed.
    ok = hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{
            action => remove,
            data => {route, Route1},
            timestamp => 200
        })
    ),

    timer:sleep(20),
    ?assertNot(filelib:is_file(Route1SKFFileName)),
    ok = check_config_counts(Route2ID, 1, 1, 1, 1),

    ok.

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

    %% Create a bunch of data to ingest
    #{
        route_id := Route1ID,
        route := Route1,
        eui_pair := EUIPair1,
        devaddr_range := DevAddrRange1,
        skf := SessionKeyFilter1
    } = test_data("7d502f32-4d58-4746-965e-001"),

    hpr_test_ics_route_service:stream_resp(
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
    [ok = hpr_test_ics_route_service:stream_resp(Update) || Update <- Updates1],
    ct:print("all updates sent"),
    timer:sleep(timer:seconds(1)),

    %% make sure all the data was received
    %% ok = timer:sleep(150),
    ok = check_config_counts(Route1ID, 1, 1, 1, 1),
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
    hpr_test_ics_route_service:stream_resp(
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
                erlang:is_pid(erlang:whereis(hpr_test_ics_route_service))
        end,
        20,
        500
    ),
    ct:print("everything should be rehydrated"),
    %% Make sure the config is still there.
    ok = check_config_counts(Route1ID, 1, 1, 1, 1),
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
    stream_resume_test_runner(
        fun() ->
            true = exit(whereis(hpr_route_stream_worker), kill),
            ok
        end
    ).

reset_stream_test(_Config) ->
    stream_resume_test_runner(
        fun() -> hpr_route_stream_worker:reset_stream() end
    ).

reset_channel_test(_Config) ->
    stream_resume_test_runner(
        fun() -> hpr_route_stream_worker:reset_channel() end
    ).

stream_resume_test_runner(ResetFn) ->
    %% The first time the stream worker starts up, it should ingest all available config.
    %% Then we stop the stream somehow `ResetFun()'.
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

    %% Create a bunch of data to ingest
    #{
        route_id := Route1ID,
        route := Route1,
        eui_pair := EUIPair1,
        devaddr_range := DevAddrRange1,
        skf := SessionKeyFilter1
    } = test_data("7d502f32-4d58-4746-965e-001"),

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
    [ok = hpr_test_ics_route_service:stream_resp(Update) || Update <- Updates1],

    %% make sure all the data was received
    %% ok = timer:sleep(150),
    ok = check_config_counts(Route1ID, 1, 1, 1, 1),
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
    hpr_test_ics_route_service:stream_resp(
        hpr_route_stream_res:test_new(#{action => add, data => {route, Route1}, timestamp => 150})
    ),
    ok = timer:sleep(150),
    %% Make sure the latest config timestamp is saved
    ok = hpr_route_stream_worker:checkpoint(),

    %% Kill the stream worker ==================================================
    ok = ResetFn(),
    %% =========================================================================

    ok = test_utils:wait_until(
        fun() ->
            WorkerAlive =
                case erlang:whereis(hpr_route_stream_worker) of
                    undefined -> false;
                    Pid0 when erlang:is_pid(Pid0) -> erlang:is_process_alive(Pid0)
                end,

            %% hpr_route_stream_worker may not be alive
            TestStream = catch hpr_route_stream_worker:test_stream(),

            TestServiceAlive =
                case erlang:whereis(hpr_test_ics_route_service) of
                    undefined -> false;
                    Pid1 when erlang:is_pid(Pid1) -> erlang:is_process_alive(Pid1)
                end,

            {
                WorkerAlive andalso
                    TestStream =/= undefined andalso
                    TestServiceAlive,
                [
                    {worker_alive, WorkerAlive},
                    {test_stream, TestStream},
                    {route_service, TestServiceAlive}
                ]
            }
        end,
        20,
        500
    ),
    %% Give the new worker a little bit of time init with the config service.
    ok = timer:sleep(150),

    %% Create a bunch of new data to ingest
    #{
        route_id := Route2ID,
        route := Route2,
        eui_pair := EUIPair2,
        devaddr_range := DevAddrRange2,
        skf := SessionKeyFilter2
    } = test_data("7d502f32-4d58-4746-965e-002"),

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
    [ok = hpr_test_ics_route_service:stream_resp(Update) || Update <- Updates2],

    %% make sure only the new data was received
    timer:sleep(timer:seconds(1)),
    %% NOTE: we expect 2 of everything, but skfs are checked per route.
    ok = check_config_counts(Route2ID, 2, 2, 2, 1),
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
    ok = check_config_counts(Route1ID, 1, 1, 1, 1),

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

    ok = check_config_counts(Route1ID, 1, 1, 1, 1),

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
    ok = check_config_counts(Route1ID, 1, 1, 1, 1),

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

%% ===================================================================
%% Helpers
%% ===================================================================

test_data(RouteID) ->
    Route1 = hpr_route:test_new(#{
        id => RouteID,
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
