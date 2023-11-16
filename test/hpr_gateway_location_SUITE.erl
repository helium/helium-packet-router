-module(hpr_gateway_location_SUITE).

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

-record(location, {
    gateway :: libp2p_crypto:pubkey_bin(),
    timestamp :: non_neg_integer(),
    h3_index :: h3:index() | undefined,
    lat :: float() | undefined,
    long :: float() | undefined
}).

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
    persistent_term:put(hpr_test_ics_gateway_service, self()),
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

main_test(_Config) ->
    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),
    IndexString = "8828308281fffff",
    ExpectedIndex = h3:from_string(IndexString),
    ok = hpr_test_ics_gateway_service:register_gateway_location(
        PubKeyBin1,
        IndexString
    ),

    Before = erlang:system_time(millisecond),

    %% Let worker start
    ok = test_utils:wait_until(fun() ->
        try hpr_test_ics_gateway_service:get(PubKeyBin1) of
            {ok, ExpectedIndex, _, _} -> true;
            _ -> false
        catch
            _:_ ->
                false
        end
    end),

    [LocationRec] = ets:lookup(hpr_gateway_location_ets, PubKeyBin1),

    ?assertEqual(PubKeyBin1, LocationRec#location.gateway),
    ?assertEqual(ExpectedIndex, LocationRec#location.h3_index),
    ?assertNotEqual(undefined, LocationRec#location.lat),
    ?assertNotEqual(undefined, LocationRec#location.long),

    Timestamp = LocationRec#location.timestamp,
    Now = erlang:system_time(millisecond),

    ?assert(Timestamp > Before),
    ?assert(Timestamp =< Now),

    [{location, Req1}] = rcv_loop([]),
    ?assertEqual(PubKeyBin1, Req1#iot_config_gateway_location_req_v1_pb.gateway),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

rcv_loop(Acc) ->
    receive
        {hpr_test_ics_gateway_service, Type, Req} ->
            lager:notice("got hpr_test_ics_gateway_service ~p req ~p", [Type, Req]),
            rcv_loop([{Type, Req} | Acc])
    after timer:seconds(2) -> Acc
    end.
