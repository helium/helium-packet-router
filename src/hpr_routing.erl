-module(hpr_routing).

-export([
    init/0,
    handle_packet/1
]).

-define(GATEWAY_THROTTLE, hpr_gateway_rate_limit).
-define(DEFAULT_GATEWAY_THROTTLE, 25).

-type hpr_routing_response() :: ok | {error, any()}.

-export_type([hpr_routing_response/0]).

-spec init() -> ok.
init() ->
    GatewayRateLimit = application:get_env(hpr, gateway_rate_limit, ?DEFAULT_GATEWAY_THROTTLE),
    ok = throttle:setup(?GATEWAY_THROTTLE, GatewayRateLimit, per_second),
    ok.

-spec handle_packet(Packet :: hpr_packet_up:packet()) -> hpr_routing_response().
handle_packet(Packet) ->
    Start = erlang:system_time(millisecond),
    ok = md(Packet),
    lager:debug("received packet"),
    Checks = [
        {fun hpr_packet_up:verify/1, bad_signature},
        {fun throttle_check/1, gateway_limit_exceeded},
        {fun packet_type_check/1, invalid_packet_type}
    ],
    PacketType = hpr_packet_up:type(Packet),
    case execute_checks(Packet, Checks) of
        {error, _Reason} = Error ->
            lager:error("packet failed verification: ~p", [_Reason]),
            hpr_metrics:observe_packet_up(PacketType, Error, 0, Start),
            Error;
        ok ->
            Routes = find_routes(PacketType),
            lager:debug("maybe deliver packet to ~w routes", [erlang:length(Routes)]),
            ok = maybe_deliver_packet(Packet, Routes),
            hpr_metrics:observe_packet_up(PacketType, ok, erlang:length(Routes), Start),
            ok
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec md(PacketUp :: hpr_packet_up:packet()) -> ok.
md(PacketUp) ->
    Gateway = hpr_packet_up:gateway(PacketUp),
    GatewayName = hpr_utils:gateway_name(Gateway),
    StreamPid =
        case hpr_packet_router_service:locate(Gateway) of
            {ok, Pid} -> Pid;
            {error, _} -> undefined
        end,
    case hpr_packet_up:type(PacketUp) of
        {undefined, FType} ->
            lager:md([
                {stream, StreamPid},
                {gateway, GatewayName},
                {packet_type, FType},
                {phash, hpr_packet_up:phash(PacketUp)}
            ]);
        {join_req, {AppEUI, DevEUI}} ->
            lager:md([
                {stream, StreamPid},
                {gateway, GatewayName},
                {app_eui, hpr_utils:int_to_hex(AppEUI)},
                {dev_eui, hpr_utils:int_to_hex(DevEUI)},
                {packet_type, join_req},
                {phash, hpr_packet_up:phash(PacketUp)}
            ]);
        {uplink, DevAddr} ->
            lager:md([
                {stream, StreamPid},
                {gateway, GatewayName},
                {devaddr, hpr_utils:int_to_hex(DevAddr)},
                {packet_type, uplink},
                {phash, hpr_packet_up:phash(PacketUp)}
            ])
    end.

-spec find_routes(hpr_packet_up:type()) -> [hpr_route:route()].
find_routes({join_req, {AppEUI, DevEUI}}) ->
    hpr_config:lookup_eui(AppEUI, DevEUI);
find_routes({uplink, DevAddr}) ->
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
    hpr_route:protocol(),
    Packet :: hpr_packet_up:packet(),
    Route :: hpr_route:route()
) -> hpr_routing_response().
deliver_packet({packet_router, _}, Packet, Route) ->
    hpr_protocol_router:send(Packet, Route);
deliver_packet({gwmp, _}, Packet, Route) ->
    hpr_protocol_gwmp:send(Packet, Route);
deliver_packet({http_roaming, _}, Packet, Route) ->
    hpr_protocol_http_roaming:send(Packet, Route);
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
