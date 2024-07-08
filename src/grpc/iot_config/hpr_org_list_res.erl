-module(hpr_org_list_res).

-include("../autogen/iot_config_pb.hrl").

-export([
    orgs/1,
    timestamp/1,
    signer/1,
    signature/1
]).

-export([
    org_ouis/1
]).

-type res() :: #iot_config_org_list_res_v1_pb{}.

-spec orgs(Res :: res()) -> list(hpr_org:org()).
orgs(Res) ->
    Res#iot_config_org_list_res_v1_pb.orgs.

-spec timestamp(Res :: res()) -> non_neg_integer().
timestamp(Res) ->
    Res#iot_config_org_list_res_v1_pb.timestamp.

-spec signer(Res :: res()) -> binary().
signer(Res) ->
    Res#iot_config_org_list_res_v1_pb.signer.

-spec signature(Res :: res()) -> binary().
signature(Res) ->
    Res#iot_config_org_list_res_v1_pb.signature.

-spec org_ouis(Res :: res()) -> list(non_neg_integer()).
org_ouis(Res) ->
    [hpr_org:oui(Org) || Org <- ?MODULE:orgs(Res)].
