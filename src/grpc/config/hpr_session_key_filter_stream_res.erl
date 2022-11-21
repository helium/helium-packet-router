-module(hpr_session_key_filter_stream_res).

-include("../autogen/server/config_pb.hrl").

-export([
    action/1,
    filter/1,
    from_map/1
]).

-type session_key_filter_stream_res() :: #config_session_key_filter_stream_res_v1_pb{}.
-type action() :: create | update | delete.

-export_type([session_key_filter_stream_res/0, action/0]).

-spec action(SessionKeyFilterRes :: session_key_filter_stream_res()) -> action().
action(SessionKeyFilterRes) ->
    SessionKeyFilterRes#config_session_key_filter_stream_res_v1_pb.action.

-spec filter(SessionKeyFilterRes :: session_key_filter_stream_res()) ->
    hpr_session_key_filter:session_key_filter().
filter(SessionKeyFilterRes) ->
    SessionKeyFilterRes#config_session_key_filter_stream_res_v1_pb.filter.

-spec from_map(Map :: map()) -> session_key_filter_stream_res().
from_map(Map) ->
    config_pb:decode_msg(
        client_config_pb:encode_msg(Map, session_key_filter_stream_res_v1_pb),
        config_session_key_filter_stream_res_v1_pb
    ).

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
    Filter = hpr_session_key_filter:from_map(#{devaddr => 16#0000001, session_keys => []}),
    ?assertEqual(
        Filter,
        ?MODULE:filter(#config_session_key_filter_stream_res_v1_pb{
            action = create,
            filter = Filter
        })
    ),
    ok.

from_map_test() ->
    FilterMap = #{devaddr => 16#0000001, session_keys => []},
    Filter = hpr_session_key_filter:from_map(#{devaddr => 16#0000001, session_keys => []}),
    ?assertEqual(
        #config_session_key_filter_stream_res_v1_pb{
            action = create,
            filter = Filter
        },
        ?MODULE:from_map(#{
            action => create,
            filter => FilterMap
        })
    ),
    ok.

-endif.
