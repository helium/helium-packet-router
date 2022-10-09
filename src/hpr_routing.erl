-module(hpr_routing).

-export([
    init/0,
    handle_packet/1,
    routing_info_type/1,
    routing_info_from/1
]).

-type routing_info() ::
    {devaddr, DevAddr :: non_neg_integer()}
    | {eui, DevEUI :: non_neg_integer(), AppEUI :: non_neg_integer()}.

-export_type([
    routing_info/0
]).

-define(GATEWAY_THROTTLE, hpr_routing_gateway_throttle).
-define(DEFAULT_GATEWAY_THROTTLE, 25).

-type hpr_routing_response() :: ok | {error, any()}.

-export_type([hpr_routing_response/0]).

-spec init() -> ok.
init() ->
    GatewayRateLimit = application:get_env(router, gateway_rate_limit, ?DEFAULT_GATEWAY_THROTTLE),
    ok = throttle:setup(?GATEWAY_THROTTLE, GatewayRateLimit, per_second),
    ok.

-spec handle_packet(
    Packet :: hpr_packet_up:packet()
) -> hpr_routing_response().
handle_packet(Packet) ->
    Start = erlang:system_time(millisecond),
    GatewayName = hpr_utils:gateway_name(hpr_packet_up:gateway(Packet)),
    PacketType = hpr_packet_up:type(Packet),
    {Type, _} = PacketType,
    lager:md([
        {gateway, GatewayName},
        {phash, hpr_utils:bin_to_hex(hpr_packet_up:phash(Packet))},
        {packet_type, Type}
    ]),
    lager:debug("received packet"),
    Checks = [
        {fun hpr_packet_up:verify/1, bad_signature},
        {fun throttle_check/1, gateway_limit_exceeded}
    ],
    {Res, NumberOfRoutes} =
        case execute_checks(Packet, Checks) of
            {error, _Reason} = Error ->
                lager:error("packet failed verification: ~p", [_Reason]),
                {Error, 0};
            ok ->
                dispatch_packet(PacketType, Packet)
        end,
    ok = hpr_metrics:observe_packet_up(PacketType, Res, NumberOfRoutes, Start),
    Res.

-spec routing_info_type(routing_info()) -> eui | devaddr.
routing_info_type({eui, _DevEUI, _AppEUI}) -> eui;
routing_info_type({devaddr, _DevAddr}) -> devaddr.

-spec routing_info_from(PacketUp :: hpr_packet_up:packet()) -> RoutingInfo :: routing_info().
routing_info_from(PacketUp) ->
    case hpr_packet_up:type(PacketUp) of
        {join_req, {AppEUI, DevEUI}} -> {eui, DevEUI, AppEUI};
        {uplink, DevAddr} -> {devaddr, DevAddr};
        {undefined, _} -> undefined
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec dispatch_packet(hpr_packet_up:type(), hpr_packet_up:packet()) ->
    {hpr_routing_response(), non_neg_integer()}.
dispatch_packet({undefined, FType}, _Packet) ->
    lager:warning("invalid packet type ~w", [FType]),
    {{error, invalid_packet_type}, 0};
dispatch_packet({join_req, {AppEUI, DevEUI}}, Packet) ->
    Routes = hpr_config:lookup_eui(AppEUI, DevEUI),
    lager:debug(
        [
            {app_eui, hpr_utils:int_to_hex(AppEUI)},
            {dev_eui, hpr_utils:int_to_hex(DevEUI)}
        ],
        "handling join"
    ),
    {deliver_packet(Packet, Routes), erlang:length(Routes)};
dispatch_packet({uplink, DevAddr}, Packet) ->
    lager:debug(
        [{devaddr, hpr_utils:int_to_hex(DevAddr)}],
        "handling uplink"
    ),
    Routes = hpr_config:lookup_devaddr(DevAddr),
    {deliver_packet(Packet, Routes), erlang:length(Routes)}.

-spec deliver_packet(
    Packet :: hpr_packet_up:packet(),
    Routes :: [hpr_route:route()]
) -> ok.
deliver_packet(_Packet, []) ->
    ok;
deliver_packet(Packet, [Route | Routes]) ->
    Server = hpr_route:server(Route),
    Protocol = hpr_route:protocol(Server),
    lager:debug(
        [
            {oui, hpr_route:oui(Route)},
            {protocol, Protocol},
            {net_id, hpr_utils:int_to_hex(hpr_route:net_id(Route))}
        ],
        "delivering packet to ~s",
        [hpr_route:lns(Route)]
    ),
    %% FIXME: delivery could be halted to multiple routes if one of the earlier
    %% Protocol:send(...) errors out.
    Resp =
        case Protocol of
            {packet_router, _} ->
                hpr_protocol_router:send(Packet, self(), Route);
            {gwmp, _} ->
                hpr_protocol_gwmp:send(Packet, self(), Route);
            {http_roaming, _} ->
                hpr_http_router:send(Packet, self(), Route);
            _OtherProtocol ->
                lager:warning([{protocol, _OtherProtocol}], "unimplemented"),
                ok
        end,
    case Resp of
        ok ->
            ok;
        {error, Err} ->
            lager:warning([{protocol, Protocol}], "error ~p", [Err])
    end,
    deliver_packet(Packet, Routes).

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
