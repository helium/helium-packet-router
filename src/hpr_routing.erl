-module(hpr_routing).

-include("hpr.hrl").

-export([
    init/0,
    check_packet/1,
    handle_valid_packet/2
]).

-define(GATEWAY_THROTTLE, hpr_gateway_rate_limit).
-define(DEFAULT_GATEWAY_THROTTLE, 25).

-type hpr_routing_response() ::
    ok | {error, gateway_limit_exceeded | invalid_packet_type | bad_signature | invalid_mic}.

-export_type([hpr_routing_response/0]).

-spec init() -> ok.
init() ->
    GatewayRateLimit = application:get_env(hpr, gateway_rate_limit, ?DEFAULT_GATEWAY_THROTTLE),
    ok = throttle:setup(?GATEWAY_THROTTLE, GatewayRateLimit, per_second),
    ok.

-spec check_packet(PacketUp :: hpr_packet_up:packet()) -> hpr_routing_response().
check_packet(PacketUp) ->
    Checks = [
        {fun packet_type_check/1, invalid_packet_type},
        {fun hpr_packet_up:verify/1, bad_signature},
        {fun mic_check/1, invalid_mic},
        {fun throttle_check/1, gateway_limit_exceeded}
    ],
    execute_checks(PacketUp, Checks).

-spec handle_valid_packet(PacketUp :: hpr_packet_up:packet(), Start :: non_neg_integer()) ->
    hpr_routing_response().
handle_valid_packet(PacketUp, Start) ->
    ok = hpr_packet_up:md(PacketUp),
    lager:debug("received packet"),
    PacketUpType = hpr_packet_up:type(PacketUp),
    case find_routes(PacketUpType) of
        [] ->
            lager:debug("no routes found"),
            ok = maybe_deliver_no_routes(PacketUp),
            hpr_metrics:observe_packet_up(PacketUpType, ok, 0, Start),
            ok;
        Routes ->
            Routed = maybe_deliver_packet(PacketUp, Routes, 0),
            N = erlang:length(Routes),
            lager:debug(
                [{routes, N}, {routed, Routed}],
                "~w routes and delivered to ~w routes",
                [N, Routed]
            ),
            hpr_metrics:observe_packet_up(PacketUpType, ok, Routed, Start),
            ok
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec find_routes(hpr_packet_up:type()) -> [hpr_route:route()].
find_routes({join_req, {AppEUI, DevEUI}}) ->
    hpr_route_ets:lookup_eui_pair(AppEUI, DevEUI);
find_routes({uplink, {_Type, DevAddr}}) ->
    hpr_route_ets:lookup_devaddr_range(DevAddr).

-spec maybe_deliver_no_routes(PacketUp :: hpr_packet_up:packet()) -> ok.
maybe_deliver_no_routes(Packet) ->
    case application:get_env(?APP, no_routes, []) of
        [] ->
            lager:debug("no routes not set");
        HostsAndPorts ->
            %% NOTE: Fallback routes will always be packet_router protocol.
            %% Don't go through reporting logic when sending to roaming.
            %% State channels are still in use over there.
            lists:foreach(
                fun({Host, Port}) ->
                    Route = hpr_route:new_packet_router(Host, Port),
                    hpr_protocol_router:send(Packet, Route)
                end,
                HostsAndPorts
            )
    end.

-spec maybe_deliver_packet(
    Packet :: hpr_packet_up:packet(),
    Routes :: [hpr_route:route()],
    Routed :: non_neg_integer()
) -> non_neg_integer().
maybe_deliver_packet(_Packet, [], Routed) ->
    Routed;
maybe_deliver_packet(Packet, [Route | Routes], Routed) ->
    RouteMD = hpr_route:md(Route),
    case hpr_route:active(Route) andalso hpr_route:locked(Route) == false of
        false ->
            lager:debug(RouteMD, "not sending, route locked or inactive"),
            maybe_deliver_packet(Packet, Routes, Routed);
        true ->
            Server = hpr_route:server(Route),
            Protocol = hpr_route:protocol(Server),
            Key = crypto:hash(sha256, <<
                (hpr_packet_up:phash(Packet))/binary, (hpr_route:lns(Route))/binary
            >>),
            case hpr_max_copies:update_counter(Key, hpr_route:max_copies(Route)) of
                {error, Reason} ->
                    lager:debug(RouteMD, "not sending ~p", [Reason]),
                    maybe_deliver_packet(Packet, Routes, Routed);
                ok ->
                    case deliver_packet(Protocol, Packet, Route) of
                        ok ->
                            lager:debug(RouteMD, "delivered"),
                            ok = hpr_packet_reporter:report_packet(Packet, Route),
                            {Type, _} = hpr_packet_up:type(Packet),
                            ok = hpr_metrics:packet_up_per_oui(Type, hpr_route:oui(Route)),
                            maybe_deliver_packet(Packet, Routes, Routed + 1);
                        {error, Reason} ->
                            lager:warning(RouteMD, "error ~p", [Reason]),
                            maybe_deliver_packet(Packet, Routes, Routed)
                    end
            end
    end.

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

-spec mic_check(Packet :: hpr_packet_up:packet()) -> boolean().
mic_check(Packet) ->
    case hpr_packet_up:type(Packet) of
        {undefined, _} ->
            true;
        {join_req, _} ->
            true;
        {uplink, {_Type, DevAddr}} ->
            case hpr_skf_ets:lookup_devaddr(DevAddr) of
                {error, not_found} ->
                    true;
                {ok, Keys} ->
                    Payload = hpr_packet_up:payload(Packet),
                    lists:any(
                        fun(Key) ->
                            hpr_lorawan:key_matches_mic(Key, Payload)
                        end,
                        Keys
                    )
            end
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
