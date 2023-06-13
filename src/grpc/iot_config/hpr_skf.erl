-module(hpr_skf).

-include("../autogen/iot_config_pb.hrl").

-export([
    route_id/1,
    devaddr/1,
    session_key/1,
    max_copies/1
]).

-ifdef(TEST).

-export([test_new/1]).

-endif.

-type skf() :: #iot_config_skf_v1_pb{}.

-export_type([skf/0]).

-spec route_id(SessionKeyFilter :: skf()) -> string().
route_id(SessionKeyFilter) ->
    SessionKeyFilter#iot_config_skf_v1_pb.route_id.

-spec devaddr(SessionKeyFilter :: skf()) -> non_neg_integer().
devaddr(SessionKeyFilter) ->
    SessionKeyFilter#iot_config_skf_v1_pb.devaddr.

-spec session_key(SessionKeyFilter :: skf()) -> binary().
session_key(SessionKeyFilter) ->
    SessionKeyFilter#iot_config_skf_v1_pb.session_key.

-spec max_copies(SessionKeyFilter :: skf()) -> non_neg_integer().
max_copies(SessionKeyFilter) ->
    SessionKeyFilter#iot_config_skf_v1_pb.max_copies.

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec test_new(SessionKeyFilterMap :: map()) -> skf().
test_new(SessionKeyFilterMap) when erlang:is_map(SessionKeyFilterMap) ->
    #iot_config_skf_v1_pb{
        route_id = maps:get(route_id, SessionKeyFilterMap),
        devaddr = maps:get(devaddr, SessionKeyFilterMap),
        session_key = maps:get(session_key, SessionKeyFilterMap),
        max_copies = maps:get(max_copies, SessionKeyFilterMap)
    }.

-endif.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

route_id_test() ->
    RouteId = "route_ud",
    ?assertEqual(
        RouteId, ?MODULE:route_id(#iot_config_skf_v1_pb{route_id = RouteId})
    ),
    ok.

devaddr_test() ->
    DevAddr = 16#0000001,
    ?assertEqual(DevAddr, ?MODULE:devaddr(#iot_config_skf_v1_pb{devaddr = DevAddr})),
    ok.

session_key_test() ->
    ?assertEqual(
        <<>>, ?MODULE:session_key(#iot_config_skf_v1_pb{session_key = <<>>})
    ),
    ok.

max_copies_test() ->
    ?assertEqual(
        1, ?MODULE:max_copies(#iot_config_skf_v1_pb{max_copies = 1})
    ),
    ok.

-endif.
