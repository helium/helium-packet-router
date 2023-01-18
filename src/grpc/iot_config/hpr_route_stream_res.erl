-module(hpr_route_stream_res).

-include("../autogen/iot_config_pb.hrl").

-export([
    action/1,
    data/1
]).

-ifdef(TEST).

-export([test_new/1]).

-endif.

-type res() :: #iot_config_route_stream_res_v1_pb{}.
-type action() :: add | remove.

-export_type([res/0, action/0]).

-spec action(RouteStreamRes :: res()) -> action().
action(RouteStreamRes) ->
    RouteStreamRes#iot_config_route_stream_res_v1_pb.action.

-spec data(RouteStreamRes :: res()) ->
    {route, hpr_route:route()}
    | {eui_pair, hpr_eui_pair:eui_pair()}
    | {devaddr_range, hpr_devaddr_range:devaddr_range()}.
data(RouteStreamRes) ->
    RouteStreamRes#iot_config_route_stream_res_v1_pb.data.

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec test_new(map()) -> res().
test_new(Map) ->
    #iot_config_route_stream_res_v1_pb{
        action = maps:get(action, Map),
        data = maps:get(data, Map)
    }.

-endif.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

action_test() ->
    ?assertEqual(
        add,
        ?MODULE:action(#iot_config_route_stream_res_v1_pb{
            action = add,
            data = undefined
        })
    ),
    ok.

data_test() ->
    Route = hpr_route:test_new(#{
        id => "7d502f32-4d58-4746-965e-8c7dfdcfc624",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    ?assertEqual(
        {route, Route},
        ?MODULE:data(#iot_config_route_stream_res_v1_pb{
            action = add,
            route = {route, Route}
        })
    ),
    ok.

new_test() ->
    Route = hpr_route:test_new(#{
        id => "7d502f32-4d58-4746-965e-8c7dfdcfc624",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    ?assertEqual(
        #iot_config_route_stream_res_v1_pb{
            action = add,
            data = {route, Route}
        },
        ?MODULE:test_new(#{action => add, data => {route, Route}})
    ),
    ok.

-endif.
