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

-define(NOT_FOUND, not_found).
-define(REQUESTED, requested).

-record(location, {
    status :: ok | ?NOT_FOUND | error | ?REQUESTED,
    gateway :: libp2p_crypto:pubkey_bin(),
    timestamp :: non_neg_integer(),
    h3_index = undefined :: h3:index() | undefined,
    lat = undefined :: float() | undefined,
    long = undefined :: float() | undefined
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
    %% Create gateway and add location to service
    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),
    IndexString = "8828308281fffff",
    ExpectedIndex = h3:from_string(IndexString),
    ok = hpr_test_ics_gateway_service:register_gateway_location(
        PubKeyBin1,
        IndexString
    ),
    {ExpectedLat, ExpectedLong} = h3:to_geo(ExpectedIndex),

    %% The location update is now async
    Before = erlang:system_time(millisecond) - 1,
    ?assertEqual(
        {error, not_found}, hpr_gateway_location:get(PubKeyBin1)
    ),
    timer:sleep(15),

    %% Make request to get gateway location
    ?assertEqual(
        {ok, ExpectedIndex, ExpectedLat, ExpectedLong}, hpr_gateway_location:get(PubKeyBin1)
    ),

    %% Check that req was received
    [{location, Req1}] = rcv_loop([]),
    ?assertEqual(PubKeyBin1, Req1#iot_config_gateway_location_req_v1_pb.gateway),

    %% Verify ETS data
    [ETSLocationRec] = ets:lookup(hpr_gateway_location_ets, PubKeyBin1),
    ?assertEqual(ok, ETSLocationRec#location.status),
    ?assertEqual(PubKeyBin1, ETSLocationRec#location.gateway),
    ?assertEqual(ExpectedIndex, ETSLocationRec#location.h3_index),
    ?assertEqual(ExpectedLat, ETSLocationRec#location.lat),
    ?assertEqual(ExpectedLong, ETSLocationRec#location.long),
    ?assert(ETSLocationRec#location.timestamp > Before),
    ?assert(ETSLocationRec#location.timestamp =< erlang:system_time(millisecond)),

    %% Verify DETS data
    [DETSLocationRec] = dets:lookup(hpr_gateway_location_dets, PubKeyBin1),
    ?assertEqual(ok, DETSLocationRec#location.status),
    ?assertEqual(PubKeyBin1, DETSLocationRec#location.gateway),
    ?assertEqual(ExpectedIndex, DETSLocationRec#location.h3_index),
    ?assertEqual(ExpectedLat, DETSLocationRec#location.lat),
    ?assertEqual(ExpectedLong, DETSLocationRec#location.long),
    ?assert(DETSLocationRec#location.timestamp > Before),
    ?assert(DETSLocationRec#location.timestamp =< erlang:system_time(millisecond)),

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
