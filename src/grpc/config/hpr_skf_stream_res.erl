-module(hpr_skf_stream_res).

-include("../autogen/server/config_pb.hrl").

-export([
    new/1,
    new/2,
    action/1,
    filter/1
]).

-type res() :: #config_session_key_filter_stream_res_v1_pb{}.
-type action() :: create | update | delete.

-export_type([res/0, action/0]).

-spec new(map()) -> res().
new(Map) ->
    ?MODULE:new(maps:get(action, Map), maps:get(filter, Map)).

-spec new(action(), hpr_skf:skf()) -> res().
new(Action, Filter) ->
    #config_session_key_filter_stream_res_v1_pb{
        action = Action,
        filter = Filter
    }.

-spec action(SessionKeyFilterRes :: res()) -> action().
action(SessionKeyFilterRes) ->
    SessionKeyFilterRes#config_session_key_filter_stream_res_v1_pb.action.

-spec filter(SessionKeyFilterRes :: res()) ->
    hpr_skf:skf().
filter(SessionKeyFilterRes) ->
    SessionKeyFilterRes#config_session_key_filter_stream_res_v1_pb.filter.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

action_test() ->
    ?assertEqual(
        create,
        ?MODULE:action(#config_session_key_filter_stream_res_v1_pb{
            action = create,
            filter = undefined
        })
    ),
    ok.

filter_test() ->
    Filter = hpr_skf:new(#{devaddr => 16#0000001, session_keys => []}),
    ?assertEqual(
        Filter,
        ?MODULE:filter(#config_session_key_filter_stream_res_v1_pb{
            action = create,
            filter = Filter
        })
    ),
    ok.

new_test() ->
    Filter = hpr_skf:new(#{devaddr => 16#0000001, session_keys => []}),
    ?assertEqual(
        #config_session_key_filter_stream_res_v1_pb{
            action = create,
            filter = Filter
        },
        ?MODULE:new(#{
            action => create,
            filter => Filter
        })
    ),
    ok.

-endif.
