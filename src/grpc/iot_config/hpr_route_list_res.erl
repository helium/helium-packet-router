-module(hpr_route_list_res).

-include("../autogen/iot_config_pb.hrl").

-export([
    routes/1
]).

-type res() :: #iot_config_route_list_res_v1_pb{}.

-spec routes(Res :: res()) -> list(hpr_route:route()).
routes(Res) ->
    Res#iot_config_route_list_res_v1_pb.routes.
