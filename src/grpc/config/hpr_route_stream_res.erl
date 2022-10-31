-module(hpr_route_stream_res).

-include("../autogen/server/config_pb.hrl").

-export([
    action/1,
    route/1,
    from_map/1
]).

-type route_stream_res() :: #config_route_stream_res_v1_pb{}.
-type action() :: create | update | delete.

-export_type([route_stream_res/0, action/0]).

-spec action(RouteStreamRes :: route_stream_res()) -> action().
action(RouteStreamRes) ->
    RouteStreamRes#config_route_stream_res_v1_pb.action.

-spec route(RouteStreamRes :: route_stream_res()) -> hpr_route:route().
route(RouteStreamRes) ->
    RouteStreamRes#config_route_stream_res_v1_pb.route.

-spec from_map(Map :: map()) -> route_stream_res().
from_map(Map) ->
    config_pb:decode_msg(
        client_config_pb:encode_msg(Map, route_stream_res_v1_pb),
        config_route_stream_res_v1_pb
    ).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

action_test() ->
    ?assertEqual(
        create,
        ?MODULE:action(#config_route_stream_res_v1_pb{
            action = create,
            route = undefined
        })
    ),
    ok.

route_test() ->
    Route = hpr_route:new(#{
        id => <<"7d502f32-4d58-4746-965e-8c7dfdcfc624">>,
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A},
            #{start_addr => 16#00000010, end_addr => 16#0000001A}
        ],
        euis => [#{app_eui => 1, dev_eui => 2}, #{app_eui => 3, dev_eui => 4}],
        oui => 1,
        server => #{
            host => <<"lns1.testdomain.com">>,
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1,
        nonce => 1
    }),
    ?assertEqual(
        Route,
        ?MODULE:route(#config_route_stream_res_v1_pb{
            action = create,
            route = Route
        })
    ),
    ok.

from_map_test() ->
    RouteMap = #{
        id => <<"7d502f32-4d58-4746-965e-8c7dfdcfc624">>,
        net_id => 0,
        devaddr_ranges => [
            #{start_addr => 16#00000001, end_addr => 16#0000000A},
            #{start_addr => 16#00000010, end_addr => 16#0000001A}
        ],
        euis => [#{app_eui => 1, dev_eui => 2}, #{app_eui => 3, dev_eui => 4}],
        oui => 1,
        server => #{
            host => <<"lns1.testdomain.com">>,
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1,
        nonce => 1
    },
    ?assertEqual(
        #config_route_stream_res_v1_pb{
            action = create,
            route = hpr_route:new(RouteMap)
        },
        ?MODULE:from_map(#{
            action => create,
            route => RouteMap
        })
    ),
    ok.

-endif.
