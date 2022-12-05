-module(hpr_cs_skf_stream_worker_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/config_pb.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    create_skf_test/1,
    update_skf_test/1,
    delete_skf_test/1
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
        create_skf_test,
        update_skf_test,
        delete_skf_test
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

create_skf_test(_Config) ->
    %% Let it startup
    timer:sleep(500),

    DevAddr = 16#00000000,
    SessionKeys = [crypto:strong_rand_bytes(16)],
    SKFMap = #{
        devaddr => DevAddr,
        session_keys => SessionKeys
    },
    ok = hpr_test_config_service_skf:stream_resp(
        hpr_skf_stream_res:new(create, hpr_skf:new(SKFMap))
    ),

    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_skf_ets, size)
        end
    ),
    ?assertEqual({ok, hpr_skf:new(SKFMap)}, hpr_skf_ets:lookup_devaddr(DevAddr)),
    ok.

update_skf_test(_Config) ->
    %% Let it startup
    timer:sleep(500),

    DevAddr1 = 16#00000000,
    SessionKeys1 = [crypto:strong_rand_bytes(16)],
    SKFMap1 = #{
        devaddr => DevAddr1,
        session_keys => SessionKeys1
    },
    ok = hpr_test_config_service_skf:stream_resp(
        hpr_skf_stream_res:new(create, hpr_skf:new(SKFMap1))
    ),

    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_skf_ets, size)
        end
    ),
    ?assertEqual({ok, hpr_skf:new(SKFMap1)}, hpr_skf_ets:lookup_devaddr(DevAddr1)),

    %% Update our SKF
    SessionKeys2 = [crypto:strong_rand_bytes(16)],
    SKFMap2 = SKFMap1#{
        devaddr => DevAddr1,
        session_keys => SessionKeys2
    },
    ok = hpr_test_config_service_skf:stream_resp(
        hpr_skf_stream_res:new(update, hpr_skf:new(SKFMap2))
    ),

    ok = test_utils:wait_until(
        fun() ->
            {ok, hpr_skf:new(SKFMap2)} =:= hpr_skf_ets:lookup_devaddr(DevAddr1)
        end
    ),
    ok.

delete_skf_test(_Config) ->
    %% Let it startup
    timer:sleep(500),

    DevAddr = 16#00000000,
    SessionKeys = [crypto:strong_rand_bytes(16)],
    SKFMap = #{
        devaddr => DevAddr,
        session_keys => SessionKeys
    },
    ok = hpr_test_config_service_skf:stream_resp(
        hpr_skf_stream_res:new(create, hpr_skf:new(SKFMap))
    ),

    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_skf_ets, size)
        end
    ),
    ?assertEqual({ok, hpr_skf:new(SKFMap)}, hpr_skf_ets:lookup_devaddr(DevAddr)),

    ok = hpr_test_config_service_skf:stream_resp(
        hpr_skf_stream_res:new(delete, hpr_skf:new(SKFMap))
    ),

    ok = test_utils:wait_until(
        fun() ->
            0 =:= ets:info(hpr_skf_ets, size)
        end
    ),

    ?assertEqual(
        {error, not_found}, hpr_skf_ets:lookup_devaddr(DevAddr)
    ),

    ok.

%% ===================================================================
%% Helpers
%% ===================================================================
