-module(hpr_routing).

-include("hpr.hrl").

-export([
    init/0,
    handle_packet/2,
    find_routes/2
]).

-define(MAX_JOIN_REQ, 999).

-define(GATEWAY_THROTTLE, hpr_gateway_rate_limit).
-define(DEFAULT_GATEWAY_THROTTLE, 25).

-define(PACKET_THROTTLE, hpr_packet_rate_limit).
-define(DEFAULT_PACKET_THROTTLE, 1).

-type hpr_routing_response() ::
    ok
    | {error, gateway_limit_exceeded | invalid_packet_type | bad_signature | invalid_mic}.

-type route() :: {hpr_route_ets:route(), SKFMaxCopies :: non_neg_integer()}.
-type routes() :: list(route()).

-export_type([hpr_routing_response/0, route/0, routes/0]).

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
    Timestamp = maps:get(timestamp, Opts, erlang:system_time(millisecond)),
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
            hpr_metrics:observe_packet_up(PacketUpType, Error, 0, Timestamp),
            Error;
        ok ->
            do_handle_packet(PacketUp, Timestamp)
    end.

-spec find_routes(hpr_packet_up:type(), PacketUp :: hpr_packet_up:packet()) ->
    {ok, routes()} | {error, invalid_mic}.
find_routes({join_req, {AppEUI, DevEUI}}, _PacketUp) ->
    Routes = hpr_eui_pair_storage:lookup(AppEUI, DevEUI),
    {ok, [{R, 0} || R <- Routes]};
find_routes({uplink, {_Type, DevAddr}}, PacketUp) ->
    {Time, Results} = timer:tc(fun() -> find_routes_for_uplink(PacketUp, DevAddr) end),
    ok = hpr_metrics:observe_find_routes(Time),
    Results.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec do_handle_packet(hpr_packet_up:packet(), Timestamp :: non_neg_integer()) ->
    ok | {error, any()}.
do_handle_packet(PacketUp, Timestamp) ->
    Hash = hpr_packet_up:phash(PacketUp),
    PacketUpType = hpr_packet_up:type(PacketUp),
    case hpr_routing_cache:lookup(Hash) of
        new ->
            establish_routing(PacketUp, Timestamp);
        no_routes ->
            ok = maybe_deliver_no_routes(PacketUp, Timestamp),
            hpr_metrics:observe_packet_up(PacketUpType, ok, 0, Timestamp),
            ok;
        {route, RoutesETS} ->
            route_packet(PacketUp, RoutesETS, Timestamp),
            ok;
        {locked, RoutingEntry} ->
            hpr_routing_cache:queue(RoutingEntry, {PacketUp, Timestamp});
        {error, _Reason} = Error ->
            hpr_metrics:observe_packet_up(PacketUpType, Error, 0, Timestamp),
            Error
    end.

-spec establish_routing(hpr_packet_up:packet(), Timestamp :: non_neg_integer()) ->
    ok | {error, any()}.
establish_routing(PacketUp, Timestamp) ->
    case hpr_routing_cache:lock(PacketUp, Timestamp) of
        {error, already_locked} ->
            do_handle_packet(PacketUp, Timestamp);
        {ok, RoutingEntry} ->
            PacketUpType = hpr_packet_up:type(PacketUp),
            case ?MODULE:find_routes(PacketUpType, PacketUp) of
                {error, _Reason} = Error ->
                    ok = hpr_routing_cache:error(RoutingEntry, Error),
                    Error;
                {ok, []} ->
                    ok = hpr_routing_cache:no_routes(RoutingEntry),
                    ok = maybe_deliver_no_routes(PacketUp, Timestamp),
                    hpr_metrics:observe_packet_up(PacketUpType, ok, 0, Timestamp),
                    ok;
                {ok, RoutesETS} ->
                    Queued = hpr_routing_cache:routes(RoutingEntry, RoutesETS),
                    lists:foreach(
                        fun({QueuedPacket, QueuedTimestamp}) ->
                            route_packet(QueuedPacket, RoutesETS, QueuedTimestamp)
                        end,
                        lists:reverse(Queued)
                    ),
                    ok
            end
    end.

-spec route_packet(
    PacketUp :: hpr_packet_up:packet(),
    [{RouteETS :: hpr_route_ets:route(), SKFMaxCopies :: non_neg_integer()}],
    Timestamp :: non_neg_integer()
) -> ok.
route_packet(PacketUp, RoutesETS, Timestamp) ->
    PacketUpType = hpr_packet_up:type(PacketUp),
    {Routed, IsFree} = maybe_deliver_packet_to_routes(PacketUpType, PacketUp, RoutesETS, Timestamp),
    ok = maybe_report_packet(
        PacketUpType,
        [hpr_route_ets:route(RouteETS) || {RouteETS, _} <- RoutesETS],
        Routed,
        IsFree,
        PacketUp,
        Timestamp
    ),
    N = erlang:length(RoutesETS),
    lager:debug(
        [{routes, N}, {routed, Routed}],
        "~w routes and delivered to ~w routes",
        [N, Routed]
    ),
    hpr_metrics:observe_packet_up(PacketUpType, ok, Routed, Timestamp).

-spec find_routes_for_uplink(PacketUp :: hpr_packet_up:packet(), DevAddr :: non_neg_integer()) ->
    {ok, routes()} | {error, invalid_mic}.
find_routes_for_uplink(PacketUp, DevAddr) ->
    case hpr_devaddr_range_storage:lookup(DevAddr) of
        [] ->
            {ok, []};
        RoutesETS ->
            find_routes_for_uplink(PacketUp, DevAddr, RoutesETS, [], [])
    end.

-spec find_routes_for_uplink(
    PacketUp :: hpr_packet_up:packet(),
    DevAddr :: non_neg_integer(),
    CandidateRoutes :: [hpr_route_ets:route()],
    EmptyRoutes :: [hpr_route_ets:route()],
    SelectedRoute :: routes()
) -> {ok, routes()} | {error, invalid_mic}.
find_routes_for_uplink(_PacketUp, _DevAddr, [], [], []) ->
    {error, invalid_mic};
find_routes_for_uplink(_PacketUp, _DevAddr, [], EmptyRoutes, []) ->
    {ok, [{R, 0} || R <- EmptyRoutes]};
find_routes_for_uplink(_PacketUp, _DevAddr, [], EmptyRoutes, SelectedRoutes) ->
    {ok, SelectedRoutes ++ [{R, 0} || R <- EmptyRoutes]};
find_routes_for_uplink(
    PacketUp, DevAddr, [RouteETS | RoutesETS], EmptyRoutes, SelectedRoutes
) ->
    Route = hpr_route_ets:route(RouteETS),
    SKFETS = hpr_route_ets:skf_ets(RouteETS),
    case check_route_skfs(PacketUp, DevAddr, SKFETS) of
        empty ->
            EmptyRoutes1 =
                case hpr_route:ignore_empty_skf(Route) of
                    true -> EmptyRoutes;
                    false -> [RouteETS | EmptyRoutes]
                end,
            find_routes_for_uplink(
                PacketUp,
                DevAddr,
                RoutesETS,
                EmptyRoutes1,
                SelectedRoutes
            );
        false ->
            find_routes_for_uplink(
                PacketUp,
                DevAddr,
                RoutesETS,
                EmptyRoutes,
                SelectedRoutes
            );
        {ok, SKFMaxCopies} ->
            find_routes_for_uplink(
                PacketUp,
                DevAddr,
                RoutesETS,
                EmptyRoutes,
                [{RouteETS, SKFMaxCopies} | SelectedRoutes]
            )
    end.

-spec check_route_skfs(
    PacketUp :: hpr_packet_up:packet(), DevAddr :: non_neg_integer(), ets:table()
) ->
    empty | false | {ok, non_neg_integer()}.
check_route_skfs(PacketUp, DevAddr, SKFETS) ->
    case hpr_skf_storage:select(SKFETS, DevAddr) of
        '$end_of_table' ->
            empty;
        Continuation ->
            Payload = hpr_packet_up:payload(PacketUp),
            case check_route_skfs(Payload, Continuation) of
                false -> false;
                {ok, MaxCopies} -> {ok, MaxCopies}
            end
    end.

-spec check_route_skfs(
    Payload :: binary(),
    '$end_of_table' | {[{binary(), integer(), non_neg_integer()}], ets:continuation()}
) -> false | {ok, non_neg_integer()}.
check_route_skfs(_Payload, '$end_of_table') ->
    false;
check_route_skfs(Payload, {SKFs, Continuation}) ->
    case check_skfs(Payload, SKFs) of
        false ->
            check_route_skfs(Payload, hpr_skf_storage:select(Continuation));
        {ok, _MaxCopies} = OK ->
            OK
    end.

-spec check_skfs(Payload :: binary(), [{binary(), non_neg_integer()}]) ->
    false | {ok, non_neg_integer()}.
check_skfs(_Payload, []) ->
    false;
check_skfs(Payload, [{SessionKey, MaxCopies} | SKFs]) ->
    case hpr_lorawan:key_matches_mic(SessionKey, Payload) of
        false ->
            check_skfs(Payload, SKFs);
        true ->
            {ok, MaxCopies}
    end.

-spec maybe_deliver_no_routes(
    PacketUp :: hpr_packet_up:packet(),
    Timestamp :: non_neg_integer()
) -> ok.
maybe_deliver_no_routes(PacketUp, Timestamp) ->
    case application:get_env(?APP, no_routes, []) of
        [] ->
            lager:debug("no routes not set");
        HostsAndPorts ->
            lager:debug("delivering to no route"),
            %% NOTE: Fallback routes will always be packet_router protocol.
            %% Don't go through reporting logic when sending to roaming.
            %% State channels are still in use over there.
            lists:foreach(
                fun({Host, Port}) ->
                    Route = hpr_route:new_packet_router(Host, Port),
                    hpr_protocol_router:send(PacketUp, Route, Timestamp, undefined)
                end,
                HostsAndPorts
            )
    end.

-spec maybe_deliver_packet_to_routes(
    PacketUpType :: hpr_packet_up:packet_type(),
    PacketUp :: hpr_packet_up:packet(),
    RoutesETS :: [{hpr_route_ets:route(), non_neg_integer()}],
    Timestamp :: non_neg_integer()
) -> {non_neg_integer(), boolean()}.
maybe_deliver_packet_to_routes(PacketUpType, PacketUp, RoutesETS, Timestamp) ->
    case erlang:length(RoutesETS) of
        1 ->
            [{RouteETS, SKFMaxCopies}] = RoutesETS,
            case
                maybe_deliver_packet_to_route(
                    PacketUpType, PacketUp, RouteETS, Timestamp, SKFMaxCopies
                )
            of
                {ok, IsFree} -> {1, IsFree};
                {error, _} -> {0, false}
            end;
        X when X > 1 ->
            MaybeDelivered = hpr_utils:pmap(
                fun({RouteETS, SKFMaxCopies}) ->
                    maybe_deliver_packet_to_route(
                        PacketUpType, PacketUp, RouteETS, Timestamp, SKFMaxCopies
                    )
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
    PacketUpType :: hpr_packet_up:packet_type(),
    PacketUp :: hpr_packet_up:packet(),
    RouteETS :: hpr_route_ets:route(),
    Timestamp :: non_neg_integer(),
    SKFMaxCopies :: non_neg_integer()
) -> {ok, boolean()} | {error, any()}.
maybe_deliver_packet_to_route(PacketUpType, PacketUp, RouteETS, Timestamp, SKFMaxCopies) ->
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
        {_, _, BackoffTimestamp} when BackoffTimestamp > Now ->
            lager:debug(RouteMD, "not sending, route in cooldown, back in ~wms", [
                BackoffTimestamp - Now
            ]),
            {error, in_cooldown};
        {true, false, _} ->
            Key = hpr_multi_buy:make_key(PacketUp, Route),
            MaxCopies =
                case {SKFMaxCopies, PacketUpType} of
                    {0, {join_req, _}} -> ?MAX_JOIN_REQ;
                    {0, _} -> hpr_route:max_copies(Route);
                    _ -> SKFMaxCopies
                end,
            case hpr_multi_buy:update_counter(Key, MaxCopies) of
                {error, Reason} = Error ->
                    lager:debug(RouteMD, "not sending ~p", [Reason]),
                    Error;
                {ok, IsFree} ->
                    Server = hpr_route:server(Route),
                    Protocol = hpr_route:protocol(Server),
                    RouteID = hpr_route:id(Route),
                    PubKeyBin = hpr_packet_up:gateway(PacketUp),
                    GatewayLocation =
                        case hpr_gateway_location:get(PubKeyBin) of
                            {error, _Reason} ->
                                lager:debug("failed to get gateway location ~p", [_Reason]),
                                undefined;
                            {ok, H3Index, Lat, Long} ->
                                {H3Index, Lat, Long}
                        end,
                    case deliver_packet(Protocol, PacketUp, Route, Timestamp, GatewayLocation) of
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
    Route :: hpr_route:route(),
    Timestamp :: non_neg_integer(),
    GatewayLocation :: hpr_gateway_location:loc()
) -> hpr_routing_response().
deliver_packet({packet_router, _}, PacketUp, Route, Timestamp, GatewayLocation) ->
    hpr_protocol_router:send(PacketUp, Route, Timestamp, GatewayLocation);
deliver_packet({gwmp, _}, PacketUp, Route, Timestamp, GatewayLocation) ->
    hpr_protocol_gwmp:send(PacketUp, Route, Timestamp, GatewayLocation);
deliver_packet({http_roaming, _}, PacketUp, Route, Timestamp, GatewayLocation) ->
    hpr_protocol_http_roaming:send(PacketUp, Route, Timestamp, GatewayLocation);
deliver_packet(_OtherProtocol, _PacketUp, _Route, _Timestamp, _GatewayLocation) ->
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
    lager:debug("not reporting packet, not routed");
maybe_report_packet({uplink, _}, Routes, Routed, IsFree, PacketUp, ReceivedTime) when Routed > 0 ->
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

-spec packet_type_check(PacketUp :: hpr_packet_up:packet()) ->
    boolean().
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
    meck:new(hpr_gateway_location, [passthrough]),
    meck:expect(hpr_gateway_location, get, fun(_) -> {error, not_implemented} end),
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
    meck:unload(hpr_gateway_location),
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
    ok = hpr_route_storage:insert(Route1),

    DevAddr1 = 16#00000001,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange1),

    SessionKey1 = crypto:strong_rand_bytes(16),
    SKF1 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 1
    }),
    ok = hpr_skf_storage:insert(SKF1),

    PacketUp = test_utils:uplink_packet_up(#{devaddr => DevAddr1, nwk_session_key => SessionKey1}),

    {ok, RouteETS1} = hpr_route_storage:lookup(RouteID1),
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
    ok = hpr_route_storage:insert(Route1),

    DevAddr1 = 16#00000001,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange1),

    SessionKey1 = crypto:strong_rand_bytes(16),
    SKF1 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 1
    }),
    ok = hpr_skf_storage:insert(SKF1),

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
    ok = hpr_route_storage:insert(Route1),
    ok = hpr_route_storage:insert(Route2),

    DevAddr1 = 16#00000001,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange1),
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => RouteID2, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange2),

    %% Testing with only Route1 having a SKF
    SessionKey1 = crypto:strong_rand_bytes(16),
    SKF1 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 1
    }),
    ok = hpr_skf_storage:insert(SKF1),

    PacketUp = test_utils:uplink_packet_up(#{
        devaddr => DevAddr1, nwk_session_key => SessionKey1
    }),

    {ok, RouteETS1} = hpr_route_storage:lookup(RouteID1),
    ?assertEqual(Route1, hpr_route_ets:route(RouteETS1)),

    {ok, RouteETS2} = hpr_route_storage:lookup(RouteID2),
    ?assertEqual(Route2, hpr_route_ets:route(RouteETS2)),

    ?assertEqual(
        {ok, [{RouteETS1, 1}, {RouteETS2, 0}]}, find_routes_for_uplink(PacketUp, DevAddr1)
    ),

    %% Testing with both Routes having a good SKF
    SKF2 = hpr_skf:new(#{
        route_id => RouteID2,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 2
    }),
    ok = hpr_skf_storage:insert(SKF2),
    ?assertEqual(
        {ok, [{RouteETS2, 2}, {RouteETS1, 1}]}, find_routes_for_uplink(PacketUp, DevAddr1)
    ),

    %% No SKF at all
    ok = hpr_skf_storage:delete(SKF1),
    ok = hpr_skf_storage:delete(SKF2),

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
    ok = hpr_route_storage:insert(Route1),
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
    ok = hpr_route_storage:insert(Route2),

    DevAddr1 = 16#00000001,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange1),
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => RouteID2, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange2),

    %% Testing with only Route1 having a bad SKF and other no SKF
    SessionKey1 = crypto:strong_rand_bytes(16),
    SKF1 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 1
    }),
    ok = hpr_skf_storage:insert(SKF1),

    PacketUp1 = test_utils:uplink_packet_up(#{
        devaddr => DevAddr1, nwk_session_key => crypto:strong_rand_bytes(16)
    }),

    {ok, RouteETS1} = hpr_route_storage:lookup(RouteID1),
    ?assertEqual(Route1, hpr_route_ets:route(RouteETS1)),

    {ok, RouteETS2} = hpr_route_storage:lookup(RouteID2),
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
    ok = hpr_skf_storage:insert(SKF2),

    ?assertEqual({error, invalid_mic}, find_routes_for_uplink(PacketUp1, DevAddr1)),

    %% Testing one good SKF and one bad SKF
    SessionKey3 = crypto:strong_rand_bytes(16),
    SKF3 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey3),
        max_copies => 3
    }),
    ok = hpr_skf_storage:insert(SKF3),

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
    ok = hpr_route_storage:insert(Route1),
    ok = hpr_route_storage:insert(Route2),

    DevAddr1 = 16#00000001,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange1),
    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => RouteID2, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_devaddr_range_storage:insert(DevAddrRange2),

    %% Testing with only Route1 having a SKF and Route2  with ignore_empty_skf => true
    SessionKey1 = crypto:strong_rand_bytes(16),
    SKF1 = hpr_skf:new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 1
    }),
    ok = hpr_skf_storage:insert(SKF1),

    PacketUp = test_utils:uplink_packet_up(#{
        devaddr => DevAddr1, nwk_session_key => SessionKey1
    }),

    {ok, RouteETS1} = hpr_route_storage:lookup(RouteID1),
    ?assertEqual(Route1, hpr_route_ets:route(RouteETS1)),

    {ok, RouteETS2} = hpr_route_storage:lookup(RouteID2),
    ?assertEqual(Route2, hpr_route_ets:route(RouteETS2)),

    ?assertEqual({ok, [{RouteETS1, 1}]}, find_routes_for_uplink(PacketUp, DevAddr1)),

    %% Testing with both Routes having a good SKF
    SKF2 = hpr_skf:new(#{
        route_id => RouteID2,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 2
    }),
    ok = hpr_skf_storage:insert(SKF2),
    ?assertEqual(
        {ok, [{RouteETS2, 2}, {RouteETS1, 1}]}, find_routes_for_uplink(PacketUp, DevAddr1)
    ),

    %% No SKF at all
    ok = hpr_skf_storage:delete(SKF1),
    ok = hpr_skf_storage:delete(SKF2),

    ?assertEqual({ok, [{RouteETS1, 0}]}, find_routes_for_uplink(PacketUp, DevAddr1)),

    ok.

maybe_deliver_packet_to_route_locked() ->
    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _, _, _) -> ok end),

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
    ok = hpr_route_storage:insert(Route1),

    PacketUp = test_utils:uplink_packet_up(#{}),
    {ok, RouteETS1} = hpr_route_storage:lookup(RouteID1),

    ?assertEqual(
        {error, locked},
        maybe_deliver_packet_to_route(PacketUp, RouteETS1, erlang:system_time(millisecond), 1)
    ),

    ?assertEqual(0, meck:num_calls(hpr_protocol_router, send, 4)),
    meck:unload(hpr_protocol_router),
    ok.

maybe_deliver_packet_to_route_inactive() ->
    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _, _, _) -> ok end),

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
    ok = hpr_route_storage:insert(Route1),

    PacketUp = test_utils:uplink_packet_up(#{}),
    {ok, RouteETS1} = hpr_route_storage:lookup(RouteID1),

    ?assertEqual(
        {error, inactive},
        maybe_deliver_packet_to_route(PacketUp, RouteETS1, erlang:system_time(millisecond), 1)
    ),

    ?assertEqual(0, meck:num_calls(hpr_protocol_router, send, 4)),
    meck:unload(hpr_protocol_router),
    ok.

maybe_deliver_packet_to_route_in_cooldown() ->
    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _, _, _) -> ok end),

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
    ok = hpr_route_storage:insert(Route1),

    PacketUp = test_utils:uplink_packet_up(#{}),
    ok = hpr_route_ets:inc_backoff(RouteID1),
    {ok, RouteETS1} = hpr_route_storage:lookup(RouteID1),

    ?assertEqual(
        {error, in_cooldown},
        maybe_deliver_packet_to_route(PacketUp, RouteETS1, erlang:system_time(millisecond), 1)
    ),

    ?assertEqual(0, meck:num_calls(hpr_protocol_router, send, 4)),
    meck:unload(hpr_protocol_router),
    ok.

maybe_deliver_packet_to_route_multi_buy() ->
    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _, _, _) -> ok end),

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
    ok = hpr_route_storage:insert(Route1),

    PacketUp = test_utils:uplink_packet_up(#{}),

    {ok, RouteETS1} = hpr_route_storage:lookup(RouteID1),
    %% Packet 1 accepted using SKF Multi buy 1 (counter 1)
    ?assertEqual(
        {ok, true},
        maybe_deliver_packet_to_route(PacketUp, RouteETS1, erlang:system_time(millisecond), 1)
    ),
    %% Packet 2 refused using SKF Multi buy 1 (counter 2)
    ?assertEqual(
        {error, multi_buy},
        maybe_deliver_packet_to_route(PacketUp, RouteETS1, erlang:system_time(millisecond), 1)
    ),

    %% Packet 3 accepted using route multi buy 3 (counter 3)
    ?assertEqual(
        {ok, true},
        maybe_deliver_packet_to_route(PacketUp, RouteETS1, erlang:system_time(millisecond), 0)
    ),
    %% Packet 4 refused using route multi buy 3 (counter 4)
    ?assertEqual(
        {error, multi_buy},
        maybe_deliver_packet_to_route(PacketUp, RouteETS1, erlang:system_time(millisecond), 0)
    ),

    ?assertEqual(2, meck:num_calls(hpr_protocol_router, send, 4)),
    meck:unload(hpr_protocol_router),
    meck:unload(hpr_metrics),
    ok.

-endif.
