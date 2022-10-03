-module(hpr_routing).

-export([
    init/0,
    handle_packet/2,
    routing_info_type/1
]).

-type routing_info() ::
    {devaddr, DevAddr :: non_neg_integer()}
    | {eui, DevEUI :: non_neg_integer(), AppEUI :: non_neg_integer()}.

-export_type([
    routing_info/0
]).

-define(GATEWAY_THROTTLE, hpr_routing_gateway_throttle).
-define(DEFAULT_GATEWAY_THROTTLE, 25).

-export_type([hpr_routing_response/0]).

-type uplink_packet_type() ::
    {join_req, non_neg_integer(), non_neg_integer()} | {uplink, non_neg_integer()} | undefined.
-type hpr_routing_response() :: ok | {error, any()}.

-define(JOIN_REQUEST, 2#000).
-define(UNCONFIRMED_UP, 2#010).
-define(CONFIRMED_UP, 2#100).

-spec init() -> ok.
init() ->
    GatewayRateLimit = application:get_env(router, gateway_rate_limit, ?DEFAULT_GATEWAY_THROTTLE),
    ok = throttle:setup(?GATEWAY_THROTTLE, GatewayRateLimit, per_second),
    ok.

-spec handle_packet(
    Packet :: hpr_packet_up:packet(),
    StreamHandler :: grpcbox_stream:t()
) -> hpr_routing_response().
handle_packet(Packet, StreamHandler) ->
    GatewayName = hpr_utils:gateway_name(hpr_packet_up:gateway(Packet)),
    lager:md([{gateway, GatewayName}, {phash, hpr_utils:bin_to_hex(hpr_packet_up:phash(Packet))}]),
    %% TODO: log some identifying information?
    lager:debug("received packet"),
    Checks = [
        {fun hpr_packet_up:verify/1, bad_signature},
        {fun throttle_check/1, gateway_limit_exceeded}
    ],
    case execute_checks(Packet, Checks) of
        {error, _Reason} = Error ->
            lager:error("packet failed verification: ~p", [_Reason]),
            Error;
        ok ->
            dispatch_packet(packet_type(Packet), Packet, StreamHandler)
    end.

routing_info_type({eui, _DevEUI, _AppEUI}) -> eui;
routing_info_type({devaddr, _DevAddr}) -> devaddr.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec dispatch_packet(
    uplink_packet_type(), hpr_packet_up:packet(), StreamHandler :: grpcbox_stream:t()
) -> hpr_routing_response().
dispatch_packet(undefined, _Packet, _StreamHandler) ->
    lager:error("invalid packet type"),
    {error, invalid_packet_type};
dispatch_packet({join_req, AppEUI, DevEUI}, Packet, StreamHandler) ->
    Routes = hpr_config:lookup_eui(AppEUI, DevEUI),
    lager:debug(
        [
            {app_eui, hpr_utils:int_to_hex(AppEUI)},
            {dev_eui, hpr_utils:int_to_hex(DevEUI)}
        ],
        "handling join"
    ),
    RoutingInfo = {eui, DevEUI, AppEUI},
    deliver_packet(Packet, StreamHandler, Routes, RoutingInfo);
dispatch_packet({uplink, DevAddr}, Packet, StreamHandler) ->
    lager:debug(
        [{devaddr, hpr_utils:int_to_hex(DevAddr)}],
        "handling uplink"
    ),
    Routes = hpr_config:lookup_devaddr(DevAddr),
    RoutingInfo = {devaddr, DevAddr},
    deliver_packet(Packet, StreamHandler, Routes, RoutingInfo).

-spec deliver_packet(
    Packet :: hpr_packet_up:packet(),
    StreamHandler :: grpcbox_stream:t() | hpr_router_stream_manager:gateway_stream(),
    Routes :: [hpr_route:route()],
    RoutingInfo :: routing_info()
) -> ok.
deliver_packet(_Packet, _StreamHandler, [], _RoutingInfo) ->
    ok;
deliver_packet(Packet, StreamHandler, [Route | Routes], RoutingInfo) ->
    lager:debug(
        [
            {oui, hpr_route:oui(Route)},
            {protocol, hpr_route:protocol(Route)},
            {net_id, hpr_utils:int_to_hex(hpr_route:net_id(Route))}
        ],
        "delivering packet to ~s",
        [hpr_route:lns(Route)]
    ),
    Protocol = hpr_route:protocol(Route),
    %% FIXME: delivery could be halted to multiple routes if one of the earlier
    %% Protocol:send(...) errors out.
    Resp =
        case Protocol of
            router ->
                hpr_protocol_router:send(Packet, StreamHandler, Route, RoutingInfo);
            gwmp ->
                hpr_protocol_gwmp:send(Packet, StreamHandler, Route, RoutingInfo);
            http ->
                hpr_http_router:send(Packet, StreamHandler, Route, RoutingInfo);
            _OtherProtocol ->
                lager:warning([{protocol, _OtherProtocol}], "unimplemented"),
                ok
        end,
    case Resp of
        ok ->
            ok;
        {error, Err} ->
            %% FIXME: might be dangerous to log full `Err` tuple right now

            lager:warning(
                [{protocol, Protocol}, {error, Err}],
                "error sending"
            )
    end,
    deliver_packet(Packet, StreamHandler, Routes, RoutingInfo).

-spec throttle_check(Packet :: hpr_packet_up:packet()) -> boolean().
throttle_check(Packet) ->
    Gateway = hpr_packet_up:gateway(Packet),
    case throttle:check(?GATEWAY_THROTTLE, Gateway) of
        {limit_exceeded, _, _} -> false;
        _ -> true
    end.

-spec execute_checks(Packet :: hpr_packet_up:packet(), [{fun(), any()}]) -> ok | {error, any()}.
execute_checks(_Packet, []) ->
    ok;
execute_checks(Packet, [{Fun, ErrorReason} | Rest]) ->
    case Fun(Packet) of
        false ->
            {error, ErrorReason};
        true ->
            execute_checks(Packet, Rest)
    end.

-spec packet_type(Packet :: hpr_packet_up:packet()) -> uplink_packet_type().
packet_type(Packet) ->
    case hpr_packet_up:payload(Packet) of
        <<?JOIN_REQUEST:3, _:5, AppEUI:64/integer-unsigned-little,
            DevEUI:64/integer-unsigned-little, _DevNonce:2/binary, _MIC:4/binary>> ->
            {join_req, AppEUI, DevEUI};
        (<<FType:3, _:5, DevAddr:32/integer-unsigned-little, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1,
            FOptsLen:4, _FCnt:16/little-unsigned-integer, _FOpts:FOptsLen/binary,
            PayloadAndMIC/binary>>) when
            (FType == ?UNCONFIRMED_UP orelse FType == ?CONFIRMED_UP) andalso
                %% MIC is 4 bytes, so the binary must be at least that long
                erlang:byte_size(PayloadAndMIC) >= 4
        ->
            Body = binary:part(PayloadAndMIC, {0, byte_size(PayloadAndMIC) - 4}),
            {FPort, _FRMPayload} =
                case Body of
                    <<>> -> {undefined, <<>>};
                    <<Port:8, Payload/binary>> -> {Port, Payload}
                end,
            case FPort of
                0 when FOptsLen /= 0 ->
                    undefined;
                _ ->
                    {uplink, DevAddr}
            end;
        _ ->
            undefined
    end.
