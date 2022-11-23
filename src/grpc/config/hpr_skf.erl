-module(hpr_skf).

-include("../autogen/server/config_pb.hrl").

-export([
    devaddr/1,
    session_keys/1,
    from_map/1
]).

-ifdef(TEST).

-endif.

-type skf() :: #config_session_key_filter_v1_pb{}.

-export_type([skf/0]).

-spec devaddr(SessionKeyFilter :: skf()) -> integer().
devaddr(SessionKeyFilter) ->
    SessionKeyFilter#config_session_key_filter_v1_pb.devaddr.

-spec session_keys(SessionKeyFilter :: skf()) -> [binary()].
session_keys(SessionKeyFilter) ->
    SessionKeyFilter#config_session_key_filter_v1_pb.session_keys.

-spec from_map(SessionKeyFilterMap :: client_config_pb:route_v1_pb()) -> skf().
from_map(SessionKeyFilterMap) ->
    config_pb:decode_msg(
        client_config_pb:encode_msg(SessionKeyFilterMap, session_key_filter_v1_pb),
        config_session_key_filter_v1_pb
    ).

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
