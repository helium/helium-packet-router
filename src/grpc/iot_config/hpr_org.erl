-module(hpr_org).

-include("../autogen/iot_config_pb.hrl").

-export([
    oui/1,
    owner/1,
    payer/1,
    delegate_keys/1,
    locked/1
]).

-type org() :: #iot_config_org_v1_pb{}.

-ifdef(TEST).

-export([test_new/1]).

-endif.

-spec oui(Org :: org()) -> non_neg_integer().
oui(Org) ->
    Org#iot_config_org_v1_pb.oui.

-spec owner(Org :: org()) -> binary().
owner(Org) ->
    Org#iot_config_org_v1_pb.owner.

-spec payer(Org :: org()) -> binary().
payer(Org) ->
    Org#iot_config_org_v1_pb.payer.

-spec delegate_keys(Org :: org()) -> list(binary()).
delegate_keys(Org) ->
    Org#iot_config_org_v1_pb.delegate_keys.

-spec locked(Org :: org()) -> boolean().
locked(Org) ->
    Org#iot_config_org_v1_pb.locked.

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec test_new(RouteMap :: map()) -> org().
test_new(RouteMap) ->
    #iot_config_org_v1_pb{
        oui = maps:get(oui, RouteMap),
        owner = maps:get(owner, RouteMap, <<"owner-test-value">>),
        payer = maps:get(payer, RouteMap, <<"payer-test-value">>),
        delegate_keys = maps:get(delegate_keys, RouteMap, []),
        locked = maps:get(locked, RouteMap, false)
    }.

-endif.
