-module(hpr_routing).

-export([
    init/0,
    handle_packet/1
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

-spec handle_packet(Packet :: hpr_packet_up:packet()) -> hpr_routing_response().
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
        {fun throttle_check/1, gateway_limit_exceeded},
        {fun packet_type_check/1, invalid_packet_type}
    ],
    case execute_checks(Packet, Checks) of
        {error, _Reason} = Error ->
            lager:error("packet failed verification: ~p", [_Reason]),
            hpr_metrics:observe_packet_up(PacketType, Error, 0, Start),
            Error;
        ok ->
            Routes = find_routes(PacketType),
            lager:debug("Routes: ~p", [Routes]),
            ok = maybe_deliver_packet(Packet, Routes),
            hpr_metrics:observe_packet_up(PacketType, ok, erlang:length(Routes), Start),
            ok
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec find_routes(hpr_packet_up:type()) -> [hpr_route:route()].
find_routes({join_req, {AppEUI, DevEUI}}) ->
    lager:debug(
        [
            {app_eui, hpr_utils:int_to_hex(AppEUI)},
            {dev_eui, hpr_utils:int_to_hex(DevEUI)}
        ],
        "handling join"
    ),
    hpr_config:lookup_eui(AppEUI, DevEUI);
find_routes({uplink, DevAddr}) ->
    lager:debug(
        [{devaddr, hpr_utils:int_to_hex(DevAddr)}],
        "handling uplink"
    ),
    hpr_config:lookup_devaddr(DevAddr).

-spec maybe_deliver_packet(
    Packet :: hpr_packet_up:packet(),
    Routes :: [hpr_route:route()]
) -> ok.
maybe_deliver_packet(_Packet, []) ->
    ok;
maybe_deliver_packet(Packet, [Route | Routes]) ->
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
    Key = crypto:hash(sha256, <<
        (hpr_packet_up:phash(Packet))/binary, (hpr_route:lns(Route))/binary
    >>),
    case hpr_max_copies:update_counter(Key, hpr_route:max_copies(Route)) of
        {error, Reason} ->
            lager:debug("not sending ~p, Route: ~p", [Reason, Route]);
        ok ->
            case deliver_packet(Protocol, Packet, Route) of
                ok ->
                    ok = hpr_packet_reporter:report_packet(Packet, Route),
                    ok;
                {error, Reason} ->
                    lager:warning([{protocol, Protocol}], "error ~p", [Reason])
            end
    end,
    maybe_deliver_packet(Packet, Routes).

-spec deliver_packet(
    hpr_route:protocol(), Packet :: hpr_packet_up:packet(), Route :: hpr_route:route()
) -> hpr_routing_response().
deliver_packet({packet_router, _}, Packet, Route) ->
    hpr_protocol_router:send(Packet, self(), Route);
deliver_packet({gwmp, _}, Packet, Route) ->
    hpr_protocol_gwmp:send(Packet, self(), Route);
deliver_packet({http_roaming, _}, Packet, Route) ->
    hpr_protocol_http_roaming:send(Packet, self(), Route);
deliver_packet(_OtherProtocol, _Packet, _Route) ->
    lager:warning([{protocol, _OtherProtocol}], "protocol unimplemented").

-spec throttle_check(Packet :: hpr_packet_up:packet()) -> boolean().
throttle_check(Packet) ->
    Gateway = hpr_packet_up:gateway(Packet),
    case throttle:check(?GATEWAY_THROTTLE, Gateway) of
        {limit_exceeded, _, _} -> false;
        _ -> true
    end.

-spec packet_type_check(Packet :: hpr_packet_up:packet()) -> boolean().
packet_type_check(Packet) ->
    case hpr_packet_up:type(Packet) of
        {undefined, _} -> false;
        {join_req, _} -> true;
        {uplink, _} -> true
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
