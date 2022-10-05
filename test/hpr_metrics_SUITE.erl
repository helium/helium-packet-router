-module(hpr_metrics_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    elli_started_test/1,
    packet_up_histogram_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("hpr_metrics.hrl").

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
        elli_started_test,
        packet_up_histogram_test
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
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

elli_started_test(_Config) ->
    ?assertMatch({ok, _}, httpc:request(get, {"http://127.0.0.1:3000/metrics", []}, [], [])),
    ok.

packet_up_histogram_test(_Config) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),

    JoinPacketUp = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => SigFun
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(JoinPacketUp)),

    ?assertNotEqual(
        undefined,
        prometheus_histogram:value(default, ?METRICS_PACKET_UP_HISTOGRAM, [join_req, ok, 0])
    ),

    ok.
