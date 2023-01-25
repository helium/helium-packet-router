-module(hpr_skf).

-include("../autogen/iot_config_pb.hrl").

-export([
    oui/1,
    devaddr/1,
    session_key/1
]).

-ifdef(TEST).

-export([test_new/1]).

-endif.

-type skf() :: #iot_config_session_key_filter_v1_pb{}.

-export_type([skf/0]).

-spec oui(SessionKeyFilter :: skf()) -> non_neg_integer().
oui(SessionKeyFilter) ->
    SessionKeyFilter#iot_config_session_key_filter_v1_pb.oui.

-spec devaddr(SessionKeyFilter :: skf()) -> non_neg_integer().
devaddr(SessionKeyFilter) ->
    SessionKeyFilter#iot_config_session_key_filter_v1_pb.devaddr.

-spec session_key(SessionKeyFilter :: skf()) -> binary().
session_key(SessionKeyFilter) ->
    SessionKeyFilter#iot_config_session_key_filter_v1_pb.session_key.

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec test_new(SessionKeyFilterMap :: map()) -> skf().
test_new(SessionKeyFilterMap) when erlang:is_map(SessionKeyFilterMap) ->
    #iot_config_session_key_filter_v1_pb{
        oui = maps:get(oui, SessionKeyFilterMap),
        devaddr = maps:get(devaddr, SessionKeyFilterMap),
        session_key = maps:get(session_key, SessionKeyFilterMap)
    }.

-endif.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

oui_test() ->
    OUI = 1,
    ?assertEqual(OUI, ?MODULE:oui(#iot_config_session_key_filter_v1_pb{oui = OUI})),
    ok.

devaddr_test() ->
    DevAddr = 16#0000001,
    ?assertEqual(DevAddr, ?MODULE:devaddr(#iot_config_session_key_filter_v1_pb{devaddr = DevAddr})),
    ok.

session_key_test() ->
    ?assertEqual(
        <<>>, ?MODULE:session_key(#iot_config_session_key_filter_v1_pb{session_key = <<>>})
    ),
    ok.

-endif.
