-module(hpr_route_list_req).

-include("../autogen/iot_config_pb.hrl").

-export([
    new/2,
    timestamp/1,
    signer/1,
    signature/1
]).

-export([
    sign/2,
    verify/1
]).

-type req() :: #iot_config_route_list_req_v1_pb{}.

-spec new(Signer :: libp2p_crypto:pubkey_bin(), Oui :: non_neg_integer()) -> req().
new(Signer, Oui) ->
    #iot_config_route_list_req_v1_pb{
        oui = Oui,
        timestamp = erlang:system_time(millisecond),
        signer = Signer
    }.

-spec timestamp(Req :: req()) -> non_neg_integer().
timestamp(Req) ->
     Req#iot_config_route_list_req_v1_pb.timestamp.

-spec signer(Req:: req()) -> binary().
signer(Req) ->
     Req#iot_config_route_list_req_v1_pb.signer.

-spec signature(Req:: req()) -> binary().
signature(Req) ->
     Req#iot_config_route_list_req_v1_pb.signature.

-spec sign(RouteListReq :: req(), SigFun :: fun()) -> req().
sign(RouteListReq, SigFun) ->
    EncodedRouteListReq = iot_config_pb:encode_msg(
        RouteListReq, iot_config_route_list_req_v1_pb
    ),
    RouteListReq#iot_config_route_list_req_v1_pb{signature = SigFun(EncodedRouteListReq)}.

-spec verify(RouteListReq :: req()) -> boolean().
verify(RouteListReq) ->
    EncodedRouteListReq = iot_config_pb:encode_msg(
        RouteListReq#iot_config_route_list_req_v1_pb{
            signature = <<>>
        },
        iot_config_route_list_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedRouteListReq,
        ?MODULE:signature(RouteListReq),
        libp2p_crypto:bin_to_pubkey(?MODULE:signer(RouteListReq))
    ).
