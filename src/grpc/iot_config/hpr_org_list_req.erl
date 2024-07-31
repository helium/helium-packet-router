-module(hpr_org_list_req).

-include("../autogen/iot_config_pb.hrl").

-export([new/0]).

-type req() :: #iot_config_org_list_req_v1_pb{}.

-spec new() -> req().
new() ->
    #iot_config_org_list_req_v1_pb{}.
