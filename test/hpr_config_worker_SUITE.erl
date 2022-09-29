-module(hpr_config_worker_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/server/config_pb.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    full_test/1
]).

-define(PORT, 8085).

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
        full_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    %% Startup a config service test server
    _ = application:ensure_all_started(grpcbox),
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [config_pb],
            services => #{'helium.config.config_service' => test_config_service}
        },
        listen_opts => #{port => ?PORT, ip => {0, 0, 0, 0}}
    }),

    %% Setup config worker
    BaseDir = erlang:atom_to_list(TestCase) ++ "_data",
    FilePath = filename:join(BaseDir, "config_worker.backup"),
    application:set_env(hpr, config_worker, #{
        host => "localhost",
        port => ?PORT,
        file_backup_path => FilePath
    }),

    test_utils:init_per_testcase(TestCase, [
        {server_pid, ServerPid}, {file_backup_path, FilePath} | Config
    ]).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    meck:unload(),
    test_utils:end_per_testcase(TestCase, Config),
    ok = gen_server:stop(proplists:get_value(server_pid, Config)),
    application:set_env(hpr, config_worker, #{}),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

full_test(Config) ->
    %% Let it startup
    timer:sleep(100),

    %% Create route and send them from server
    Route1 = #config_route_v1_pb{
        net_id = 0,
        devaddr_ranges = [
            #config_devaddr_range_v1_pb{start_addr = 16#00000001, end_addr = 16#0000000A}
        ],
        euis = [#config_eui_v1_pb{app_eui = 1, dev_eui = 0}],
        oui = 1,
        protocol = {router, #config_protocol_router_pb{ip = <<"localhost">>, port = 8080}}
    },
    Route2 = #config_route_v1_pb{
        net_id = 0,
        devaddr_ranges = [
            #config_devaddr_range_v1_pb{start_addr = 16#00000010, end_addr = 16#0000001A}
        ],
        euis = [#config_eui_v1_pb{app_eui = 2, dev_eui = 2}],
        oui = 2,
        protocol = {gwmp, #config_protocol_gwmp_pb{ip = <<"localhost">>, port = 8088}}
    },
    Routes = [Route1, Route2],
    ConfigRouteResV1 = #config_routes_res_v1_pb{routes = Routes},
    ok = test_config_service:config_route_res_v1(ConfigRouteResV1),

    %% Let  process new routes
    timer:sleep(100),

    %% Check backup file
    FilePath = proplists:get_value(file_backup_path, Config),
    case file:read_file(FilePath) of
        {ok, Binary} ->
            #{routes := DetsRoutes} = erlang:binary_to_term(Binary),
            ?assertEqual(Routes, [hpr_route:new(R) || R <- DetsRoutes]);
        {error, Reason} ->
            ct:fail(Reason)
    end,

    %% Check that we can query route via config
    ?assertEqual([Route1], hpr_config:lookup_devaddr(16#00000005)),
    ?assertEqual([Route2], hpr_config:lookup_devaddr(16#00000011)),
    ?assertEqual([Route1], hpr_config:lookup_eui(1, 12)),
    ?assertEqual([Route1], hpr_config:lookup_eui(1, 100)),
    ?assertEqual([Route2], hpr_config:lookup_eui(2, 2)),
    ?assertEqual([], hpr_config:lookup_devaddr(16#00000020)),
    ?assertEqual([], hpr_config:lookup_eui(3, 3)),
    ok.

%% ===================================================================
%% Helpers
%% ===================================================================
