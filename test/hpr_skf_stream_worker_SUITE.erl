-module(hpr_skf_stream_worker_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/iot_config_pb.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    create_skf_test/1,
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
    SessionKey1 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SessionKeyFilter1 = hpr_skf:test_new(#{
        oui => 1,
        devaddr => DevAddr,
        session_key => SessionKey1
    }),
    ok = hpr_test_iot_config_service_skf:stream_resp(
        hpr_skf_stream_res:test_new(#{action => add, filter => SessionKeyFilter1})
    ),

    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_skf_ets, size)
        end
    ),
    ?assertEqual({ok, [hpr_utils:hex_to_bin(SessionKey1)]}, hpr_skf_ets:lookup_devaddr(DevAddr)),

    SessionKey2 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SessionKeyFilter2 = hpr_skf:test_new(#{
        oui => 1,
        devaddr => DevAddr,
        session_key => SessionKey2
    }),
    ok = hpr_test_iot_config_service_skf:stream_resp(
        hpr_skf_stream_res:test_new(#{action => add, filter => SessionKeyFilter2})
    ),
    ok = test_utils:wait_until(
        fun() ->
            2 =:= ets:info(hpr_skf_ets, size)
        end
    ),

    ?assertEqual(
        {ok, [hpr_utils:hex_to_bin(SessionKey1), hpr_utils:hex_to_bin(SessionKey2)]},
        hpr_skf_ets:lookup_devaddr(DevAddr)
    ),

    ok.

delete_skf_test(_Config) ->
    %% Let it startup
    timer:sleep(500),

    DevAddr = 16#00000000,
    SessionKey1 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SessionKeyFilter1 = hpr_skf:test_new(#{
        oui => 1,
        devaddr => DevAddr,
        session_key => SessionKey1
    }),
    ok = hpr_test_iot_config_service_skf:stream_resp(
        hpr_skf_stream_res:test_new(#{action => add, filter => SessionKeyFilter1})
    ),

    SessionKey2 = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SessionKeyFilter2 = hpr_skf:test_new(#{
        oui => 1,
        devaddr => DevAddr,
        session_key => SessionKey2
    }),
    ok = hpr_test_iot_config_service_skf:stream_resp(
        hpr_skf_stream_res:test_new(#{action => add, filter => SessionKeyFilter2})
    ),

    ok = test_utils:wait_until(
        fun() ->
            2 =:= ets:info(hpr_skf_ets, size)
        end
    ),
    ?assertEqual(
        {ok, [hpr_utils:hex_to_bin(SessionKey1), hpr_utils:hex_to_bin(SessionKey2)]},
        hpr_skf_ets:lookup_devaddr(DevAddr)
    ),

    ok = hpr_test_iot_config_service_skf:stream_resp(
        hpr_skf_stream_res:test_new(#{action => remove, filter => SessionKeyFilter1})
    ),

    ok = test_utils:wait_until(
        fun() ->
            1 =:= ets:info(hpr_skf_ets, size)
        end
    ),

    ?assertEqual({ok, [hpr_utils:hex_to_bin(SessionKey2)]}, hpr_skf_ets:lookup_devaddr(DevAddr)),

    ok = hpr_test_iot_config_service_skf:stream_resp(
        hpr_skf_stream_res:test_new(#{action => remove, filter => SessionKeyFilter2})
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
