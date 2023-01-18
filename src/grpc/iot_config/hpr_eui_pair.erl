-module(hpr_eui_pair).

-include("../autogen/iot_config_pb.hrl").

-export([
    route_id/1,
    app_eui/1,
    dev_eui/1
]).

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

test_eui_pair() ->
    #iot_config_eui_pair_v1_pb{
        route_id = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
        app_eui = 16#000000001,
        dev_eui = 16#000000002
    }.

-endif.
