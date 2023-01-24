-module(hpr_devaddr_range).

-include("../autogen/iot_config_pb.hrl").

-export([
    route_id/1,
    start_addr/1,
    end_addr/1,
    is_valid_record/1
]).

-ifdef(TEST).

-export([test_new/1]).

-endif.

-type devaddr_range() :: #iot_config_devaddr_range_v1_pb{}.

-export_type([devaddr_range/0]).

-spec route_id(Route :: devaddr_range()) -> string().
route_id(Route) ->
    Route#iot_config_devaddr_range_v1_pb.route_id.

-spec start_addr(Route :: devaddr_range()) -> non_neg_integer().
start_addr(Route) ->
    Route#iot_config_devaddr_range_v1_pb.start_addr.

-spec end_addr(Route :: devaddr_range()) -> non_neg_integer().
end_addr(Route) ->
    Route#iot_config_devaddr_range_v1_pb.end_addr.

-spec is_valid_record(devaddr_range()) -> boolean().
is_valid_record(#iot_config_devaddr_range_v1_pb{}) -> true;
is_valid_record(_) -> false.

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec test_new(DevAddrRangeMap :: map()) -> devaddr_range().
test_new(DevAddrRangeMap) ->
    #iot_config_devaddr_range_v1_pb{
        route_id = maps:get(route_id, DevAddrRangeMap),
        start_addr = maps:get(start_addr, DevAddrRangeMap),
        end_addr = maps:get(end_addr, DevAddrRangeMap)
    }.

-endif.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

route_id_test() ->
    DevAddrRange = test_devaddr_range(),
    ?assertEqual("7d502f32-4d58-4746-965e-8c7dfdcfc624", ?MODULE:route_id(DevAddrRange)),
    ok.

start_addr_test() ->
    DevAddrRange = test_devaddr_range(),
    ?assertEqual(16#000000001, ?MODULE:start_addr(DevAddrRange)),
    ok.

end_addr_test() ->
    DevAddrRange = test_devaddr_range(),
    ?assertEqual(16#000000002, ?MODULE:end_addr(DevAddrRange)),
    ok.

is_valid_record_test() ->
    DevAddrRange = test_devaddr_range(),
    ?assert(?MODULE:is_valid_record(DevAddrRange)),
    ?assertNot(?MODULE:is_valid_record({invalid, record})),
    ok.

test_devaddr_range() ->
    #iot_config_devaddr_range_v1_pb{
        route_id = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
        start_addr = 16#000000001,
        end_addr = 16#000000002
    }.

-endif.
