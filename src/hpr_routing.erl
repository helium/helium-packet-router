-module(hpr_routing).

-include("hpr.hrl").

-export([
    init/0,
    handle_packet/1
]).

-define(GATEWAY_THROTTLE, hpr_gateway_rate_limit).
-define(DEFAULT_GATEWAY_THROTTLE, 25).

-type hpr_routing_response() ::
    ok
    | {error, gateway_limit_exceeded | invalid_packet_type | bad_signature | invalid_mic}.

-export_type([hpr_routing_response/0]).

-spec init() -> ok.
init() ->
    GatewayRateLimit = application:get_env(hpr, gateway_rate_limit, ?DEFAULT_GATEWAY_THROTTLE),
    ok = throttle:setup(?GATEWAY_THROTTLE, GatewayRateLimit, per_second),
    ok.

-spec handle_packet(Packet :: hpr_packet_up:packet()) -> hpr_routing_response().
handle_packet(Packet) ->
    Start = erlang:system_time(millisecond),
    lager:debug("received packet"),
    Checks = [
        {fun packet_type_check/1, invalid_packet_type},
        {fun hpr_packet_up:verify/1, bad_signature},
        {fun throttle_check/1, gateway_limit_exceeded}
    ],
    PacketType = hpr_packet_up:type(Packet),
    case execute_checks(Packet, Checks) of
        {error, _Reason} = Error ->
            Gateway = hpr_packet_up:gateway(Packet),
            GatewayName = hpr_utils:gateway_name(Gateway),
            lager:debug([{gateway, GatewayName}], "packet failed verification: ~p", [_Reason]),
            hpr_metrics:observe_packet_up(PacketType, Error, 0, Start),
            Error;
        ok ->
            ok = hpr_packet_up:md(Packet),
            case find_routes(PacketType, Packet) of
                {error, _Reason} = Error ->
                    lager:debug("failed to find routes: ~p", [_Reason]),
                    hpr_metrics:observe_packet_up(PacketType, Error, 0, Start),
                    Error;
                {ok, []} ->
                    lager:debug("no routes found"),
                    ok = maybe_deliver_no_routes(Packet),
                    hpr_metrics:observe_packet_up(PacketType, ok, 0, Start),
                    ok;
                {ok, Routes} ->
                    Routed = maybe_deliver_packet(Packet, Routes, 0),
                    ok = maybe_report_packet(Routes, Routed, Packet),
                    N = erlang:length(Routes),
                    lager:debug(
                        [{routes, N}, {routed, Routed}],
                        "~w routes and delivered to ~w routes",
                        [N, Routed]
                    ),
                    hpr_metrics:observe_packet_up(PacketType, ok, Routed, Start),
                    ok
            end
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec find_routes(hpr_packet_up:type(), Packet :: hpr_packet_up:packet()) ->
    {ok, [hpr_route:route()]} | {error, invalid_mic}.
find_routes({join_req, {AppEUI, DevEUI}}, _Packet) ->
    {ok, hpr_route_ets:lookup_eui_pair(AppEUI, DevEUI)};
find_routes({uplink, _}, Packet) ->
    find_routes_for_uplink(Packet).

-spec find_routes_for_uplink(Packet :: hpr_packet_up:packet()) ->
    {ok, [hpr_route:route()]} | {error, invalid_mic}.
find_routes_for_uplink(Packet) ->
    {uplink, {_Type, DevAddr}} = hpr_packet_up:type(Packet),
    case hpr_route_ets:lookup_skf(DevAddr) of
        %% If they aren't any SKF for that devaddr we can move on the packet is valid
        [] ->
            {ok, hpr_route_ets:lookup_devaddr_range(DevAddr)};
        SKFs ->
            %% First, we get all the unique Routes we find in that SKFs list and
            %% all the Routes that devaddr is included into and make the delta.
            %% Getting us the Routes that do not have SKFs for that devaddr.
            SKFsRoutes = lists:usort([RouteID || {_Key, RouteID} <- SKFs]),
            RoutesWithNoSKF = lists:filtermap(
                fun(Route) ->
                    RouteID = hpr_route:id(Route),
                    not lists:member(RouteID, SKFsRoutes)
                end,
                hpr_route_ets:lookup_devaddr_range(DevAddr)
            ),
            %% Then, we actually check each SKF agaisnt the payload.
            Payload = hpr_packet_up:payload(Packet),
            MicFilteredRoutes = lists:filtermap(
                fun({Key, RouteID}) ->
                    case hpr_lorawan:key_matches_mic(Key, Payload) of
                        %% If failed we remove that entry
                        false ->
                            false;
                        %% If match we try to get the Route and included it.
                        true ->
                            case hpr_route_ets:lookup_route(RouteID) of
                                %% Note: this would mark packet as invalid_mic
                                %% but we are just missing the route
                                [] -> false;
                                Routes -> {true, Routes}
                            end
                    end
                end,
                SKFs
            ),
            %% We have to flatten as `hpr_route_ets:lookup_route/1` returns a list of Routes
            %% and `usort` it just in case there were any duplicates in the SKF.
            %% We can then add the Routes that did not include SKFs.
            case lists:usort(lists:flatten(MicFilteredRoutes)) ++ RoutesWithNoSKF of
                %% If we could not find any routes including with or without SKF then sorry
                %% you are not passing this test
                [] -> {error, invalid_mic};
                List -> {ok, List}
            end
    end.

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

%% TODO: test this in CT
-spec maybe_report_packet(
    Routes :: [hpr_route:route()], Routed :: non_neg_integer(), Packet :: hpr_packet_up:packet()
) -> ok.
maybe_report_packet(_Routes, 0, _Packet) ->
    lager:debug("not reporting packet");
maybe_report_packet([Route | _] = Routes, Routed, Packet) when Routed > 0 ->
    UniqueOUINetID = lists:usort([{hpr_route:oui(R), hpr_route:net_id(R)} || R <- Routes]),
    case erlang:length(UniqueOUINetID) of
        1 ->
            ok = hpr_packet_reporter:report_packet(Packet, Route);
        _ ->
            lager:error("routed packet to non unique OUI/Net ID ~p", [
                [{hpr_route:id(R), hpr_route:oui(R), hpr_route:net_id(R)} || R <- Routes]
            ])
    end.

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

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        ?_test(find_routes_for_uplink_no_skf()),
        ?_test(find_routes_for_uplink_single_route_success()),
        ?_test(find_routes_for_uplink_single_route_failed()),
        ?_test(find_routes_for_uplink_multi_route_success()),
        ?_test(find_routes_for_uplink_multi_route_failed())
    ]}.

foreach_setup() ->
    meck:new(hpr_route_ets, [passthrough]),
    ok.

foreach_cleanup(ok) ->
    meck:unload(hpr_route_ets),
    ok.

find_routes_for_uplink_no_skf() ->
    meck:expect(hpr_route_ets, lookup_skf, fun(_) -> [] end),
    meck:expect(hpr_route_ets, lookup_devaddr_range, fun(_) -> [] end),

    PacketUp = test_utils:uplink_packet_up(#{}),

    ?assertEqual({ok, []}, find_routes_for_uplink(PacketUp)),
    ok.

find_routes_for_uplink_single_route_success() ->
    RouteID1 = "route_id_1",
    Route1 = hpr_route:test_new(#{
        id => RouteID1,
        net_id => 1,
        oui => 10,
        server => #{
            host => "lsn.lora.com",
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1,
        active => true,
        locked => false
    }),
    SKF1 = crypto:strong_rand_bytes(16),
    SKFs = [{SKF1, RouteID1}],

    meck:expect(hpr_route_ets, lookup_skf, fun(_) -> SKFs end),
    meck:expect(hpr_route_ets, lookup_devaddr_range, fun(_) -> [Route1] end),
    meck:expect(hpr_route_ets, lookup_route, fun(_) -> [Route1] end),

    PacketUp = test_utils:uplink_packet_up(#{nwk_session_key => SKF1}),

    ?assertEqual({ok, [Route1]}, find_routes_for_uplink(PacketUp)),
    ok.

find_routes_for_uplink_single_route_failed() ->
    RouteID1 = "route_id_1",
    Route1 = hpr_route:test_new(#{
        id => RouteID1,
        net_id => 1,
        oui => 10,
        server => #{
            host => "lsn.lora.com",
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1,
        active => true,
        locked => false
    }),
    SKF1 = crypto:strong_rand_bytes(16),
    SKFs = [{SKF1, RouteID1}],

    meck:expect(hpr_route_ets, lookup_skf, fun(_) -> SKFs end),
    meck:expect(hpr_route_ets, lookup_devaddr_range, fun(_) -> [Route1] end),
    meck:expect(hpr_route_ets, lookup_route, fun(_) -> [Route1] end),

    PacketUp = test_utils:uplink_packet_up(#{nwk_session_key => crypto:strong_rand_bytes(16)}),

    ?assertEqual({error, invalid_mic}, find_routes_for_uplink(PacketUp)),
    ok.

find_routes_for_uplink_multi_route_success() ->
    RouteID1 = "route_id_1",
    Route1 = hpr_route:test_new(#{
        id => RouteID1,
        net_id => 1,
        oui => 10,
        server => #{
            host => "lsn.lora.com",
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1,
        active => true,
        locked => false
    }),
    RouteID2 = "route_id_2",
    Route2 = hpr_route:test_new(#{
        id => RouteID2,
        net_id => 1,
        oui => 10,
        server => #{
            host => "lsn.lora.com",
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1,
        active => true,
        locked => false
    }),
    SKF1 = crypto:strong_rand_bytes(16),
    SKFs1 = [{SKF1, RouteID1}],

    %% Testing with only Route1 having a SKF
    meck:expect(hpr_route_ets, lookup_skf, fun(_) -> SKFs1 end),
    meck:expect(hpr_route_ets, lookup_devaddr_range, fun(_) -> [Route1, Route2] end),
    meck:expect(hpr_route_ets, lookup_route, fun(ID) ->
        case ID of
            RouteID1 -> [Route1];
            RouteID2 -> [Route2]
        end
    end),

    PacketUp = test_utils:uplink_packet_up(#{nwk_session_key => SKF1}),

    ?assertEqual({ok, [Route1, Route2]}, find_routes_for_uplink(PacketUp)),

    %% Testing with both Routes having a good SKF
    SKFs2 = [{SKF1, RouteID1}, {SKF1, RouteID2}],

    meck:expect(hpr_route_ets, lookup_skf, fun(_) -> SKFs2 end),

    ?assertEqual({ok, [Route1, Route2]}, find_routes_for_uplink(PacketUp)),

    %% No SKF at all
    meck:expect(hpr_route_ets, lookup_skf, fun(_) -> [] end),

    ?assertEqual({ok, [Route1, Route2]}, find_routes_for_uplink(PacketUp)),

    ok.

find_routes_for_uplink_multi_route_failed() ->
    RouteID1 = "route_id_1",
    Route1 = hpr_route:test_new(#{
        id => RouteID1,
        net_id => 1,
        oui => 10,
        server => #{
            host => "lsn.lora.com",
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1,
        active => true,
        locked => false
    }),
    RouteID2 = "route_id_2",
    Route2 = hpr_route:test_new(#{
        id => RouteID2,
        net_id => 1,
        oui => 10,
        server => #{
            host => "lsn.lora.com",
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1,
        active => true,
        locked => false
    }),
    SKF1 = crypto:strong_rand_bytes(16),
    SKFs1 = [{SKF1, RouteID1}],

    %% Testing with only Route1 having a bad SKF and other no SKF
    meck:expect(hpr_route_ets, lookup_skf, fun(_) -> SKFs1 end),
    meck:expect(hpr_route_ets, lookup_devaddr_range, fun(_) -> [Route1, Route2] end),
    meck:expect(hpr_route_ets, lookup_route, fun(ID) ->
        case ID of
            RouteID1 -> [Route1];
            RouteID2 -> [Route2]
        end
    end),

    PacketUp1 = test_utils:uplink_packet_up(#{nwk_session_key => crypto:strong_rand_bytes(16)}),

    ?assertEqual({ok, [Route2]}, find_routes_for_uplink(PacketUp1)),

    %% Testing with both Routes having a bad SKF
    SKFs2 = [{SKF1, RouteID1}, {SKF1, RouteID2}],

    meck:expect(hpr_route_ets, lookup_skf, fun(_) -> SKFs2 end),

    ?assertEqual({error, invalid_mic}, find_routes_for_uplink(PacketUp1)),

    %% Testing one good SKF and one bad SKF
    SKF2 = crypto:strong_rand_bytes(16),
    SKFs3 = [{SKF1, RouteID1}, {SKF2, RouteID2}],

    meck:expect(hpr_route_ets, lookup_skf, fun(_) -> SKFs3 end),
    PacketUp2 = test_utils:uplink_packet_up(#{nwk_session_key => SKF1}),

    ?assertEqual({ok, [Route1]}, find_routes_for_uplink(PacketUp2)),

    ok.

-endif.
