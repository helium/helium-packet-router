-module(hpr_skf).

-include("../autogen/server/config_pb.hrl").

-export([
    new/1,
    devaddr/1,
    session_keys/1
]).

-type skf() :: #config_session_key_filter_v1_pb{}.

-export_type([skf/0]).

-spec new(SessionKeyFilterMap :: map()) -> skf().
new(SessionKeyFilterMap) when erlang:is_map(SessionKeyFilterMap) ->
    #config_session_key_filter_v1_pb{
        devaddr = maps:get(devaddr, SessionKeyFilterMap),
        session_keys = maps:get(session_keys, SessionKeyFilterMap)
    }.

-spec devaddr(SessionKeyFilter :: skf()) -> integer().
devaddr(SessionKeyFilter) ->
    SessionKeyFilter#config_session_key_filter_v1_pb.devaddr.

-spec session_keys(SessionKeyFilter :: skf()) -> [binary()].
session_keys(SessionKeyFilter) ->
    SessionKeyFilter#config_session_key_filter_v1_pb.session_keys.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

devaddr_test() ->
    DevAddr = 16#0000001,
    ?assertEqual(DevAddr, ?MODULE:devaddr(#config_session_key_filter_v1_pb{devaddr = DevAddr})),
    ok.

session_keysr_test() ->
    ?assertEqual([], ?MODULE:session_keys(#config_session_key_filter_v1_pb{session_keys = []})),
    ok.

-endif.
