-module(hpr_skf_stream_res).

-include("../autogen/iot_config_pb.hrl").

-export([
    action/1,
    filter/1
]).

-ifdef(TEST).

-export([test_new/1]).

-endif.

-type res() :: #iot_config_session_key_filter_stream_res_v1_pb{}.
-type action() :: add | remove.

-export_type([res/0, action/0]).

-spec action(SessionKeyFilterRes :: res()) -> action().
action(SessionKeyFilterRes) ->
    SessionKeyFilterRes#iot_config_session_key_filter_stream_res_v1_pb.action.

-spec filter(SessionKeyFilterRes :: res()) ->
    hpr_skf:skf().
filter(SessionKeyFilterRes) ->
    SessionKeyFilterRes#iot_config_session_key_filter_stream_res_v1_pb.filter.

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec test_new(map()) -> res().
test_new(Map) ->
    #iot_config_session_key_filter_stream_res_v1_pb{
        action = maps:get(action, Map),
        filter = maps:get(filter, Map)
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
        ?MODULE:action(#iot_config_session_key_filter_stream_res_v1_pb{
            action = add,
            filter = undefined
        })
    ),
    ok.

filter_test() ->
    Filter = hpr_skf:test_new(#{oui => 1, devaddr => 16#0000001, session_key => <<>>}),
    ?assertEqual(
        Filter,
        ?MODULE:filter(#iot_config_session_key_filter_stream_res_v1_pb{
            action = add,
            filter = Filter
        })
    ),
    ok.

new_test() ->
    Filter = hpr_skf:test_new(#{oui => 1, devaddr => 16#0000001, session_key => <<>>}),
    ?assertEqual(
        #iot_config_session_key_filter_stream_res_v1_pb{
            action = add,
            filter = Filter
        },
        ?MODULE:test_new(#{
            action => add,
            filter => Filter
        })
    ),
    ok.

-endif.
