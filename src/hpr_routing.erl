-module(hpr_routing).

-include("hpr.hrl").

-export([
    init/0,
    handle_packet/2,
    find_routes/2
]).

-define(GATEWAY_THROTTLE, hpr_gateway_rate_limit).
-define(DEFAULT_GATEWAY_THROTTLE, 25).

-define(PACKET_THROTTLE, hpr_packet_rate_limit).
-define(DEFAULT_PACKET_THROTTLE, 1).

-ifdef(TEST).
-define(SKF_UPDATE, timer:seconds(2)).
-else.
-define(SKF_UPDATE, timer:minutes(60)).
-endif.

-type hpr_routing_response() ::
    ok
    | {error, gateway_limit_exceeded | invalid_packet_type | bad_signature | invalid_mic}.

-export_type([hpr_routing_response/0]).

-spec init() -> ok.
init() ->
    GatewayRateLimit = application:get_env(?APP, gateway_rate_limit, ?DEFAULT_GATEWAY_THROTTLE),
    ok = throttle:setup(?GATEWAY_THROTTLE, GatewayRateLimit, per_second),
    PacketRateLimit = application:get_env(?APP, packet_rate_limit, ?DEFAULT_PACKET_THROTTLE),
    ok = throttle:setup(?PACKET_THROTTLE, PacketRateLimit, per_second),
    ok.

-spec handle_packet(PacketUp :: hpr_packet_up:packet(), Opts :: map()) ->
    hpr_routing_response().
handle_packet(PacketUp, Opts) ->
    Start = erlang:system_time(millisecond),
    ok = hpr_packet_up:md(PacketUp, Opts),
    lager:debug("received packet"),
    SessionKey = maps:get(session_key, Opts, undefined),
    Gateway = maps:get(gateway, Opts, undefined),
    Checks = [
        {fun packet_type_check/1, [], invalid_packet_type},
        {fun gateway_check/2, [Gateway], wrong_gateway},
        {fun packet_session_check/2, [SessionKey], bad_signature},
        {fun gateway_throttle_check/1, [], gateway_limit_exceeded},
        {fun packet_throttle_check/1, [], packet_limit_exceeded}
    ],
    PacketUpType = hpr_packet_up:type(PacketUp),
    case execute_checks(PacketUp, Checks) of
        {error, _Reason} = Error ->
            lager:debug("packet failed verification: ~p", [_Reason]),
            hpr_metrics:observe_packet_up(PacketUpType, Error, 0, Start),
            Error;
        ok ->
            case ?MODULE:find_routes(PacketUpType, PacketUp) of
                {error, _Reason} = Error ->
                    lager:debug("failed to find routes: ~p", [_Reason]),
                    hpr_metrics:observe_packet_up(PacketUpType, Error, 0, Start),
                    Error;
                {ok, []} ->
                    lager:debug("no routes found"),
                    ok = maybe_deliver_no_routes(PacketUp),
                    hpr_metrics:observe_packet_up(PacketUpType, ok, 0, Start),
                    ok;
                {ok, RoutesETS} ->
                    {Routed, IsFree} = maybe_deliver_packet_to_routes(PacketUp, RoutesETS),
                    ok = maybe_report_packet(
                        PacketUpType,
                        [hpr_route_ets:route(RouteETS) || {RouteETS, _} <- RoutesETS],
                        Routed,
                        IsFree,
                        PacketUp,
                        Start
                    ),
                    N = erlang:length(RoutesETS),
                    lager:debug(
                        [{routes, N}, {routed, Routed}],
                        "~w routes and delivered to ~w routes",
                        [N, Routed]
                    ),
                    hpr_metrics:observe_packet_up(PacketUpType, ok, Routed, Start),
                    ok
            end
    end.

-spec find_routes(hpr_packet_up:type(), PacketUp :: hpr_packet_up:packet()) ->
    {ok, [{hpr_route_ets:route(), non_neg_integer()}]} | {error, invalid_mic}.
find_routes({join_req, {AppEUI, DevEUI}}, _PacketUp) ->
    Routes = hpr_route_ets:lookup_eui_pair(AppEUI, DevEUI),
    {ok, [{R, 0} || R <- Routes]};
find_routes({uplink, {_Type, DevAddr}}, PacketUp) ->
    {Time, Results} = timer:tc(fun() -> find_routes_for_uplink(PacketUp, DevAddr) end),
    ok = hpr_metrics:observe_find_routes(Time),
    Results.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec find_routes_for_uplink(PacketUp :: hpr_packet_up:packet(), DevAddr :: non_neg_integer()) ->
    {ok, [{hpr_route_ets:route(), non_neg_integer()}]} | {error, invalid_mic}.
find_routes_for_uplink(PacketUp, DevAddr) ->
    case hpr_route_ets:lookup_devaddr_range(DevAddr) of
        [] ->
            {ok, []};
        RoutesETS ->
            find_routes_for_uplink(PacketUp, DevAddr, RoutesETS, [], undefined)
    end.

-spec find_routes_for_uplink(
    PacketUp :: hpr_packet_up:packet(),
    DevAddr :: non_neg_integer(),
    [hpr_route_ets:route()],
    [hpr_route_ets:route()],
    undefined
    | {
        RouteETS :: hpr_route_ets:route(),
        SessionKey :: binary(),
        LastUsed :: non_neg_integer(),
        SKFMaxCopies :: non_neg_integer()
    }
) -> {ok, [{hpr_route:route(), non_neg_integer()}]} | {error, invalid_mic}.
find_routes_for_uplink(_PacketUp, _DevAddr, [], [], undefined) ->
    {error, invalid_mic};
find_routes_for_uplink(_PacketUp, _DevAddr, [], EmptyRoutes, undefined) ->
    {ok, [{R, 0} || R <- EmptyRoutes]};
find_routes_for_uplink(
    _PacketUp, DevAddr, [], EmptyRoutes, {RouteETS, SessionKey, LastUsed, SKFMaxCopies}
) ->
    LastHour = erlang:system_time(millisecond) - ?SKF_UPDATE,
    case LastUsed < LastHour of
        true ->
            Route = hpr_route_ets:route(RouteETS),
            erlang:spawn(hpr_route_ets, update_skf, [
                DevAddr, SessionKey, hpr_route:id(Route), SKFMaxCopies
            ]);
        false ->
            ok
    end,
    {ok, [{RouteETS, SKFMaxCopies} | [{R, 0} || R <- EmptyRoutes]]};
find_routes_for_uplink(PacketUp, DevAddr, [RouteETS | RoutesETS], EmptyRoutes, SelectedRoute) ->
    Route = hpr_route_ets:route(RouteETS),
    SKFETS = hpr_route_ets:skf_ets(RouteETS),
    case check_route_skfs(PacketUp, DevAddr, SKFETS) of
        empty ->
            case hpr_route:ignore_empty_skf(Route) of
                true ->
                    find_routes_for_uplink(
                        PacketUp, DevAddr, RoutesETS, EmptyRoutes, SelectedRoute
                    );
                false ->
                    find_routes_for_uplink(
                        PacketUp, DevAddr, RoutesETS, [RouteETS | EmptyRoutes], SelectedRoute
                    )
            end;
        false ->
            find_routes_for_uplink(PacketUp, DevAddr, RoutesETS, EmptyRoutes, SelectedRoute);
        {ok, SessionKey, LastUsed, SKFMaxCopies} ->
            case SelectedRoute of
                undefined ->
                    find_routes_for_uplink(
                        PacketUp,
                        DevAddr,
                        RoutesETS,
                        EmptyRoutes,
                        {RouteETS, SessionKey, LastUsed, SKFMaxCopies}
                    );
                {_R, _S, L, _M} when LastUsed > L ->
                    find_routes_for_uplink(
                        PacketUp,
                        DevAddr,
                        RoutesETS,
                        EmptyRoutes,
                        {RouteETS, SessionKey, LastUsed, SKFMaxCopies}
                    );
                _ ->
                    find_routes_for_uplink(PacketUp, DevAddr, RoutesETS, EmptyRoutes, SelectedRoute)
            end
    end.

-spec check_route_skfs(
    PacketUp :: hpr_packet_up:packet(), DevAddr :: non_neg_integer(), ets:table()
) ->
    empty | false | {ok, binary(), non_neg_integer(), non_neg_integer()}.
check_route_skfs(PacketUp, DevAddr, SKFETS) ->
    case hpr_route_ets:select_skf(SKFETS, DevAddr) of
        '$end_of_table' ->
            empty;
        Continuation ->
            Payload = hpr_packet_up:payload(PacketUp),
            case check_route_skfs(Payload, Continuation) of
                false -> false;
                {ok, _SessionKey, _LastUsed, _MaxCopies} = OK -> OK
            end
    end.

-spec check_route_skfs(
    Payload :: binary(),
    '$end_of_table' | {[{binary(), integer(), non_neg_integer()}], ets:continuation()}
) -> false | {ok, binary(), non_neg_integer(), non_neg_integer()}.
check_route_skfs(_Payload, '$end_of_table') ->
    false;
check_route_skfs(Payload, {SKFs, Continuation}) ->
    case check_skfs(Payload, SKFs) of
        false ->
            check_route_skfs(Payload, hpr_route_ets:select_skf(Continuation));
        {ok, _SessionKey, _LastUsed, _MaxCopies} = OK ->
            OK
    end.

-spec check_skfs(Payload :: binary(), [{binary(), integer(), non_neg_integer()}]) ->
    false | {ok, binary(), non_neg_integer(), non_neg_integer()}.
check_skfs(_Payload, []) ->
    false;
check_skfs(Payload, [{SessionKey, LastUsed, MaxCopies} | SKFs]) ->
    case hpr_lorawan:key_matches_mic(SessionKey, Payload) of
        false ->
            check_skfs(Payload, SKFs);
        true ->
            {ok, SessionKey, LastUsed * -1, MaxCopies}
    end.

-spec maybe_deliver_no_routes(PacketUp :: hpr_packet_up:packet()) -> ok.
maybe_deliver_no_routes(PacketUp) ->
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
                    hpr_protocol_router:send(PacketUp, Route)
                end,
                HostsAndPorts
            )
    end.

-spec maybe_deliver_packet_to_routes(
    PacketUp :: hpr_packet_up:packet(),
    RoutesETS :: [{hpr_route_ets:route(), non_neg_integer()}]
) -> {non_neg_integer(), boolean()}.
maybe_deliver_packet_to_routes(PacketUp, RoutesETS) ->
    case erlang:length(RoutesETS) of
        1 ->
            [{RouteETS, SKFMaxCopies}] = RoutesETS,
            case maybe_deliver_packet_to_route(PacketUp, RouteETS, SKFMaxCopies) of
                {ok, IsFree} -> {1, IsFree};
                {error, _} -> {0, false}
            end;
        X when X > 1 ->
            MaybeDelivered = hpr_utils:pmap(
                fun({RouteETS, SKFMaxCopies}) ->
                    maybe_deliver_packet_to_route(PacketUp, RouteETS, SKFMaxCopies)
                end,
                RoutesETS
            ),
            lists:foldl(
                fun
                    ({ok, _}, {Routed, true}) ->
                        {Routed + 1, true};
                    ({ok, IsFree}, {Routed, false}) ->
                        {Routed + 1, IsFree};
                    ({error, _}, {Routed, IsFree}) ->
                        {Routed, IsFree}
                end,
                {0, false},
                MaybeDelivered
            )
    end.

-spec maybe_deliver_packet_to_route(
    PacketUp :: hpr_packet_up:packet(),
    RouteETS :: hpr_route_ets:route(),
    SKFMaxCopies :: non_neg_integer()
) -> {ok, boolean()} | {error, any()}.
maybe_deliver_packet_to_route(PacketUp, RouteETS, SKFMaxCopies) ->
    Route = hpr_route_ets:route(RouteETS),
    RouteMD = hpr_route:md(Route),
    BackoffTimestamp =
        case hpr_route_ets:backoff(RouteETS) of
            undefined -> 0;
            {T, _} -> T
        end,
    Now = erlang:system_time(millisecond),

    case {hpr_route:active(Route), hpr_route:locked(Route), BackoffTimestamp} of
        {_, true, _} ->
            lager:debug(RouteMD, "not sending, route locked"),
            {error, locked};
        {false, _, _} ->
            lager:debug(RouteMD, "not sending, route inactive"),
            {error, inactive};
        {_, _, Timestamp} when Timestamp > Now ->
            lager:debug(RouteMD, "not sending, route in cooldown, back in ~wms", [Timestamp - Now]),
            {error, in_cooldown};
        {true, false, _} ->
            Server = hpr_route:server(Route),
            Protocol = hpr_route:protocol(Server),
            Key = hpr_multi_buy:make_key(PacketUp, Route),
            MaxCopies =
                case SKFMaxCopies of
                    0 -> hpr_route:max_copies(Route);
                    _ -> SKFMaxCopies
                end,
            case hpr_multi_buy:update_counter(Key, MaxCopies) of
                {error, Reason} = Error ->
                    lager:debug(RouteMD, "not sending ~p", [Reason]),
                    Error;
                {ok, IsFree} ->
                    RouteID = hpr_route:id(Route),
                    case deliver_packet(Protocol, PacketUp, Route) of
                        {error, Reason} = Error ->
                            lager:warning(RouteMD, "error ~p", [Reason]),
                            ok = hpr_route_ets:inc_backoff(RouteID),
                            Error;
                        ok ->
                            lager:debug(RouteMD, "delivered"),
                            ok = hpr_route_ets:reset_backoff(RouteID),
                            {Type, _} = hpr_packet_up:type(PacketUp),
                            ok = hpr_metrics:packet_up_per_oui(Type, hpr_route:oui(Route)),
                            {ok, IsFree}
                    end
            end
    end.

-spec deliver_packet(
    hpr_route:protocol(),
    PacketUp :: hpr_packet_up:packet(),
    Route :: hpr_route:route()
) -> hpr_routing_response().
deliver_packet({packet_router, _}, PacketUp, Route) ->
    hpr_protocol_router:send(PacketUp, Route);
deliver_packet({gwmp, _}, PacketUp, Route) ->
    hpr_protocol_gwmp:send(PacketUp, Route);
deliver_packet({http_roaming, _}, PacketUp, Route) ->
    hpr_protocol_http_roaming:send(PacketUp, Route);
deliver_packet(_OtherProtocol, _PacketUp, _Route) ->
    lager:warning([{protocol, _OtherProtocol}], "protocol unimplemented").

-spec maybe_report_packet(
    PacketUpType :: hpr_packet_up:packet_type(),
    Routes :: [hpr_route:route()],
    Routed :: non_neg_integer(),
    IsFree :: boolean(),
    PacketUp :: hpr_packet_up:packet(),
    ReceivedTime :: non_neg_integer()
) -> ok.
maybe_report_packet(_PacketUpType, _Routes, 0, _IsFree, _PacketUp, _ReceivedTime) ->
    lager:debug("not reporting packet, no routed");
maybe_report_packet(_PacketType, Routes, Routed, IsFree, PacketUp, ReceivedTime) when Routed > 0 ->
    UniqueOUINetID = lists:usort([{hpr_route:oui(R), hpr_route:net_id(R)} || R <- Routes]),
    case erlang:length(UniqueOUINetID) of
        1 ->
            [Route | _] = Routes,
            ok = hpr_packet_reporter:report_packet(PacketUp, Route, IsFree, ReceivedTime);
        _ ->
            lager:error("routed packet to non unique OUI/Net ID ~p", [
                [{hpr_route:id(R), hpr_route:oui(R), hpr_route:net_id(R)} || R <- Routes]
            ])
    end;
maybe_report_packet({Type, _}, _Routes, _Routed, _IsFree, _PacketUp, _ReceivedTime) ->
    lager:debug("not reporting ~p packet", [Type]).

-spec packet_type_check(PacketUp :: hpr_packet_up:packet()) -> boolean().
packet_type_check(PacketUp) ->
    case hpr_packet_up:type(PacketUp) of
        {undefined, _} -> false;
        {join_req, _} -> true;
        {uplink, _} -> true
    end.

-spec gateway_check(PacketUp :: hpr_packet_up:packet(), Gateway :: binary() | undefined) ->
    boolean().
gateway_check(PacketUp, Gateway) ->
    hpr_packet_up:gateway(PacketUp) == Gateway.

-spec packet_session_check(PacketUp :: hpr_packet_up:packet(), SessionKey :: undefined | binary()) ->
    boolean().
packet_session_check(PacketUp, undefined) ->
    hpr_packet_up:verify(PacketUp);
packet_session_check(PacketUp, SessionKey) ->
    hpr_packet_up:verify(PacketUp, SessionKey).

-spec gateway_throttle_check(PacketUp :: hpr_packet_up:packet()) ->
    boolean().
gateway_throttle_check(PacketUp) ->
    Gateway = hpr_packet_up:gateway(PacketUp),
    case throttle:check(?GATEWAY_THROTTLE, Gateway) of
        {limit_exceeded, _, _} -> false;
        _ -> true
    end.

-spec packet_throttle_check(PacketUp :: hpr_packet_up:packet()) ->
    boolean().
packet_throttle_check(PacketUp) ->
    Gateway = hpr_packet_up:gateway(PacketUp),
    PHash = hpr_packet_up:phash(PacketUp),
    case throttle:check(?PACKET_THROTTLE, {Gateway, PHash}) of
        {limit_exceeded, _, _} -> false;
        _ -> true
    end.

-spec execute_checks(PacketUp :: hpr_packet_up:packet(), [{fun(), list(any()), any()}]) ->
    ok | {error, any()}.
execute_checks(_PacketUp, []) ->
    ok;
execute_checks(PacketUp, [{Fun, Args, ErrorReason} | Rest]) ->
    case erlang:apply(Fun, [PacketUp | Args]) of
        false ->
            {error, ErrorReason};
        true ->
            execute_checks(PacketUp, Rest)
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
        ?_test(find_routes_for_uplink_multi_route_failed()),
        ?_test(find_routes_for_uplink_ignore_empty_skf()),
        ?_test(maybe_deliver_packet_to_route_locked()),
        ?_test(maybe_deliver_packet_to_route_inactive()),
        ?_test(maybe_deliver_packet_to_route_in_cooldown()),
        ?_test(maybe_deliver_packet_to_route_multi_buy())
    ]}.

foreach_setup() ->
    true = erlang:register(hpr_sup, self()),
    ok = hpr_route_ets:init(),
    ok = hpr_multi_buy:init(),
    ok.

foreach_cleanup(ok) ->
    true = ets:delete(hpr_multi_buy_ets),
    true = ets:delete(hpr_route_devaddr_ranges_ets),
    true = ets:delete(hpr_route_eui_pairs_ets),
    lists:foreach(
        fun(RouteETS) ->
            SKFETS = hpr_route_ets:skf_ets(RouteETS),
            ets:delete(SKFETS)
        end,
        ets:tab2list(hpr_routes_ets)
    ),
    true = ets:delete(hpr_routes_ets),
    true = erlang:unregister(hpr_sup),
    ok.

find_routes_for_uplink_no_skf() ->
    DevAddr1 = 16#00000001,
    PacketUp = test_utils:uplink_packet_up(#{devaddr => DevAddr1}),
    ?assertEqual({ok, []}, find_routes_for_uplink(PacketUp, DevAddr1)),
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
        max_copies => 10,
        active => true,
        locked => false
    }),
    ok = hpr_route_ets:insert_route(Route1),

    DevAddr1 = 16#00000001,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_route_ets:insert_devaddr_range(DevAddrRange1),

    SessionKey1 = crypto:strong_rand_bytes(16),
    SKF1 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 1
    }),
    ok = hpr_route_ets:insert_skf(SKF1),

    PacketUp = test_utils:uplink_packet_up(#{devaddr => DevAddr1, nwk_session_key => SessionKey1}),

    [RouteETS1] = hpr_route_ets:lookup_route(RouteID1),
    ?assertEqual(Route1, hpr_route_ets:route(RouteETS1)),

    ?assertEqual({ok, [{RouteETS1, 1}]}, find_routes_for_uplink(PacketUp, DevAddr1)),
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
        max_copies => 10,
        active => true,
        locked => false
    }),
    ok = hpr_route_ets:insert_route(Route1),

    DevAddr1 = 16#00000001,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_route_ets:insert_devaddr_range(DevAddrRange1),

    SessionKey1 = crypto:strong_rand_bytes(16),
    SKF1 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 1
    }),
    ok = hpr_route_ets:insert_skf(SKF1),

    PacketUp = test_utils:uplink_packet_up(#{
        devaddr => DevAddr1, nwk_session_key => crypto:strong_rand_bytes(16)
    }),

    ?assertEqual({error, invalid_mic}, find_routes_for_uplink(PacketUp, DevAddr1)),
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
        max_copies => 10,
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
        max_copies => 20,
        active => true,
        locked => false
    }),
    ok = hpr_route_ets:insert_route(Route1),
    ok = hpr_route_ets:insert_route(Route2),

    DevAddr1 = 16#00000001,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_route_ets:insert_devaddr_range(DevAddrRange1),
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => RouteID2, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_route_ets:insert_devaddr_range(DevAddrRange2),

    %% Testing with only Route1 having a SKF
    SessionKey1 = crypto:strong_rand_bytes(16),
    SKF1 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 1
    }),
    ok = hpr_route_ets:insert_skf(SKF1),

    PacketUp = test_utils:uplink_packet_up(#{
        devaddr => DevAddr1, nwk_session_key => SessionKey1
    }),

    [RouteETS1] = hpr_route_ets:lookup_route(RouteID1),
    ?assertEqual(Route1, hpr_route_ets:route(RouteETS1)),

    [RouteETS2] = hpr_route_ets:lookup_route(RouteID2),
    ?assertEqual(Route2, hpr_route_ets:route(RouteETS2)),

    ?assertEqual(
        {ok, [{RouteETS1, 1}, {RouteETS2, 0}]}, find_routes_for_uplink(PacketUp, DevAddr1)
    ),

    %% Testing with both Routes having a good SKF the latest one only should be picked
    SKF2 = hpr_skf:new(#{
        route_id => RouteID2,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 2
    }),
    timer:sleep(1),
    ok = hpr_route_ets:insert_skf(SKF2),

    ?assertEqual({ok, [{RouteETS2, 2}]}, find_routes_for_uplink(PacketUp, DevAddr1)),

    %% No SKF at all
    ok = hpr_route_ets:delete_skf(SKF1),
    ok = hpr_route_ets:delete_skf(SKF2),

    ?assertEqual(
        {ok, [{RouteETS2, 0}, {RouteETS1, 0}]}, find_routes_for_uplink(PacketUp, DevAddr1)
    ),

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
        max_copies => 10,
        active => true,
        locked => false
    }),
    ok = hpr_route_ets:insert_route(Route1),
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
        max_copies => 10,
        active => true,
        locked => false
    }),
    ok = hpr_route_ets:insert_route(Route2),

    DevAddr1 = 16#00000001,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_route_ets:insert_devaddr_range(DevAddrRange1),
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => RouteID2, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_route_ets:insert_devaddr_range(DevAddrRange2),

    %% Testing with only Route1 having a bad SKF and other no SKF
    SessionKey1 = crypto:strong_rand_bytes(16),
    SKF1 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 1
    }),
    ok = hpr_route_ets:insert_skf(SKF1),

    PacketUp1 = test_utils:uplink_packet_up(#{
        devaddr => DevAddr1, nwk_session_key => crypto:strong_rand_bytes(16)
    }),

    [RouteETS1] = hpr_route_ets:lookup_route(RouteID1),
    ?assertEqual(Route1, hpr_route_ets:route(RouteETS1)),

    [RouteETS2] = hpr_route_ets:lookup_route(RouteID2),
    ?assertEqual(Route2, hpr_route_ets:route(RouteETS2)),

    ?assertEqual({ok, [{RouteETS2, 0}]}, find_routes_for_uplink(PacketUp1, DevAddr1)),

    %% Testing with both Routes having a bad SKF
    SessionKey2 = crypto:strong_rand_bytes(16),
    SKF2 = hpr_skf:new(#{
        route_id => RouteID2,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey2),
        max_copies => 2
    }),
    ok = hpr_route_ets:insert_skf(SKF2),

    ?assertEqual({error, invalid_mic}, find_routes_for_uplink(PacketUp1, DevAddr1)),

    %% Testing one good SKF and one bad SKF
    SessionKey3 = crypto:strong_rand_bytes(16),
    SKF3 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey3),
        max_copies => 3
    }),
    ok = hpr_route_ets:insert_skf(SKF3),

    PacketUp2 = test_utils:uplink_packet_up(#{devaddr => DevAddr1, nwk_session_key => SessionKey3}),

    ?assertEqual({ok, [{RouteETS1, 3}]}, find_routes_for_uplink(PacketUp2, DevAddr1)),

    ok.

find_routes_for_uplink_ignore_empty_skf() ->
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
        max_copies => 10,
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
        max_copies => 20,
        active => true,
        locked => false,
        ignore_empty_skf => true
    }),
    ok = hpr_route_ets:insert_route(Route1),
    ok = hpr_route_ets:insert_route(Route2),

    DevAddr1 = 16#00000001,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_route_ets:insert_devaddr_range(DevAddrRange1),
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => RouteID2, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_route_ets:insert_devaddr_range(DevAddrRange2),

    %% Testing with only Route1 having a SKF and Route2  with ignore_empty_skf => true
    SessionKey1 = crypto:strong_rand_bytes(16),
    SKF1 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 1
    }),
    ok = hpr_route_ets:insert_skf(SKF1),

    PacketUp = test_utils:uplink_packet_up(#{
        devaddr => DevAddr1, nwk_session_key => SessionKey1
    }),

    [RouteETS1] = hpr_route_ets:lookup_route(RouteID1),
    ?assertEqual(Route1, hpr_route_ets:route(RouteETS1)),

    [RouteETS2] = hpr_route_ets:lookup_route(RouteID2),
    ?assertEqual(Route2, hpr_route_ets:route(RouteETS2)),

    ?assertEqual({ok, [{RouteETS1, 1}]}, find_routes_for_uplink(PacketUp, DevAddr1)),

    %% Testing with both Routes having a good SKF the latest one only should be picked
    SKF2 = hpr_skf:new(#{
        route_id => RouteID2,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 2
    }),
    timer:sleep(1),
    ok = hpr_route_ets:insert_skf(SKF2),

    ?assertEqual({ok, [{RouteETS2, 2}]}, find_routes_for_uplink(PacketUp, DevAddr1)),

    %% No SKF at all
    ok = hpr_route_ets:delete_skf(SKF1),
    ok = hpr_route_ets:delete_skf(SKF2),

    ?assertEqual({ok, [{RouteETS1, 0}]}, find_routes_for_uplink(PacketUp, DevAddr1)),

    ok.

maybe_deliver_packet_to_route_locked() ->
    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    RouteID1 = "route_id_1",
    Route1 = hpr_route:test_new(#{
        id => RouteID1,
        net_id => 1,
        oui => 10,
        server => #{
            host => "lsn.lora.com",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 10,
        active => true,
        locked => true
    }),
    ok = hpr_route_ets:insert_route(Route1),

    PacketUp = test_utils:uplink_packet_up(#{}),
    [RouteETS1] = hpr_route_ets:lookup_route(RouteID1),

    ?assertEqual(
        {error, locked}, maybe_deliver_packet_to_route(PacketUp, RouteETS1, 1)
    ),

    ?assertEqual(0, meck:num_calls(hpr_protocol_router, send, 2)),
    meck:unload(hpr_protocol_router),
    ok.

maybe_deliver_packet_to_route_inactive() ->
    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    RouteID1 = "route_id_1",
    Route1 = hpr_route:test_new(#{
        id => RouteID1,
        net_id => 1,
        oui => 10,
        server => #{
            host => "lsn.lora.com",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 10,
        active => false,
        locked => false
    }),
    ok = hpr_route_ets:insert_route(Route1),

    PacketUp = test_utils:uplink_packet_up(#{}),
    [RouteETS1] = hpr_route_ets:lookup_route(RouteID1),

    ?assertEqual(
        {error, inactive}, maybe_deliver_packet_to_route(PacketUp, RouteETS1, 1)
    ),

    ?assertEqual(0, meck:num_calls(hpr_protocol_router, send, 2)),
    meck:unload(hpr_protocol_router),
    ok.

maybe_deliver_packet_to_route_in_cooldown() ->
    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    RouteID1 = "route_id_1",
    Route1 = hpr_route:test_new(#{
        id => RouteID1,
        net_id => 1,
        oui => 10,
        server => #{
            host => "lsn.lora.com",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 10,
        active => true,
        locked => false
    }),
    ok = hpr_route_ets:insert_route(Route1),

    PacketUp = test_utils:uplink_packet_up(#{}),
    ok = hpr_route_ets:inc_backoff(RouteID1),
    [RouteETS1] = hpr_route_ets:lookup_route(RouteID1),

    ?assertEqual(
        {error, in_cooldown}, maybe_deliver_packet_to_route(PacketUp, RouteETS1, 1)
    ),

    ?assertEqual(0, meck:num_calls(hpr_protocol_router, send, 2)),
    meck:unload(hpr_protocol_router),
    ok.

maybe_deliver_packet_to_route_multi_buy() ->
    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    meck:new(hpr_metrics, [passthrough]),
    meck:expect(hpr_metrics, observe_multi_buy, fun(_, _) -> ok end),
    meck:expect(hpr_metrics, packet_up_per_oui, fun(_, _) -> ok end),

    RouteID1 = "route_id_1",
    Route1 = hpr_route:test_new(#{
        id => RouteID1,
        net_id => 1,
        oui => 10,
        server => #{
            host => "lsn.lora.com",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 3,
        active => true,
        locked => false
    }),
    ok = hpr_route_ets:insert_route(Route1),

    PacketUp = test_utils:uplink_packet_up(#{}),

    [RouteETS1] = hpr_route_ets:lookup_route(RouteID1),
    %% Packet 1 accepted using SKF Multi buy 1 (counter 1)
    ?assertEqual(
        {ok, true}, maybe_deliver_packet_to_route(PacketUp, RouteETS1, 1)
    ),
    %% Packet 2 refused using SKF Multi buy 1 (counter 2)
    ?assertEqual(
        {error, multi_buy}, maybe_deliver_packet_to_route(PacketUp, RouteETS1, 1)
    ),

    %% Packet 3 accepted using route multi buy 3 (counter 3)
    ?assertEqual(
        {ok, true}, maybe_deliver_packet_to_route(PacketUp, RouteETS1, 0)
    ),
    %% Packet 4 refused using route multi buy 3 (counter 4)
    ?assertEqual(
        {error, multi_buy}, maybe_deliver_packet_to_route(PacketUp, RouteETS1, 0)
    ),

    ?assertEqual(2, meck:num_calls(hpr_protocol_router, send, 2)),
    meck:unload(hpr_protocol_router),
    meck:unload(hpr_metrics),
    ok.

-endif.
