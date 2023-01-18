-module(hpr_eui_pair).

-include("../autogen/iot_config_pb.hrl").

-export([
    route_id/1,
    app_eui/1,
    dev_eui/1,
    is_valid_record/1
]).

-ifdef(TEST).

-export([test_new/1]).

-endif.

-type eui_pair() :: #iot_config_eui_pair_v1_pb{}.

-export_type([eui_pair/0]).

-spec route_id(Route :: eui_pair()) -> string().
route_id(Route) ->
    Route#iot_config_eui_pair_v1_pb.route_id.

-spec app_eui(Route :: eui_pair()) -> non_neg_integer().
app_eui(Route) ->
    Route#iot_config_eui_pair_v1_pb.app_eui.

-spec dev_eui(Route :: eui_pair()) -> non_neg_integer().
dev_eui(Route) ->
    Route#iot_config_eui_pair_v1_pb.dev_eui.

-spec is_valid_record(eui_pair()) -> boolean().
is_valid_record(#iot_config_eui_pair_v1_pb{}) -> true;
is_valid_record(_) -> false.

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec test_new(EUIPairMap :: map()) -> eui_pair().
test_new(EUIPairMap) ->
    #iot_config_eui_pair_v1_pb{
        route_id = maps:get(route_id, EUIPairMap),
        app_eui = maps:get(app_eui, EUIPairMap),
        dev_eui = maps:get(dev_eui, EUIPairMap),
    }.

-endif.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

route_id_test() ->
    EUIPair = test_eui_pair(),
    ?assertEqual("7d502f32-4d58-4746-965e-8c7dfdcfc624", ?MODULE:route_id(EUIPair)),
    ok.

app_eui_test() ->
    EUIPair = test_eui_pair(),
    ?assertEqual(16#000000001, ?MODULE:app_eui(EUIPair)),
    ok.

dev_eui_test() ->
    EUIPair = test_eui_pair(),
    ?assertEqual(16#000000002, ?MODULE:dev_eui(EUIPair)),
    ok.

is_valid_record_test() ->
    EUIPair = test_eui_pair(),
    ?assert(?MODULE:is_valid_record(EUIPair)),
    ?assertNot(?MODULE:is_valid_record({invalid, record})),
    ok.

test_eui_pair() ->
    #iot_config_eui_pair_v1_pb{
        route_id = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
        app_eui = 16#000000001,
        dev_eui = 16#000000002
    }.

-endif.
