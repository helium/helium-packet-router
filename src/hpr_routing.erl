-module(hpr_routing).

-include("hpr.hrl").

-export([
    init/0,
    admit/2,
    handle_packet/2,
    find_routes/2
]).

-define(MAX_JOIN_REQ, 50).

-define(GATEWAY_THROTTLE, hpr_gateway_rate_limit).
-define(DEFAULT_GATEWAY_THROTTLE, 25).

-define(PACKET_THROTTLE, hpr_packet_rate_limit).
-define(DEFAULT_PACKET_THROTTLE, 1).

-type hpr_routing_response() ::
    ok
    | {error,
        gateway_limit_exceeded
        | packet_limit_exceeded
        | invalid_packet_type
        | bad_signature
        | invalid_mic
        | gateway_denied
        | wrong_gateway}.

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
    Checks0 = [
        {fun packet_type_check/1, [], invalid_packet_type},
        {fun gateway_check/2, [Gateway], wrong_gateway},
        {fun gateway_denied_check/1, [], gateway_denied},
        {fun packet_session_check/2, [SessionKey], bad_signature}
    ],
    %% The rate limits consume budget, so they run exactly once per packet.
    %% hpr_packet_router_service calls admit/2 before spawning us -- that is the
    %% point, a throttled packet should not cost a process -- and says so here.
    %% A caller that does not (any direct caller, and the test suites) still gets
    %% them, in their original position at the end of the list.
    Checks =
        case maps:get(admitted, Opts, false) of
            true ->
                Checks0;
            false ->
                Checks0 ++
                    [
                        {fun gateway_throttle_check/1, [], gateway_limit_exceeded},
                        {fun packet_throttle_check/1, [], packet_limit_exceeded}
                    ]
        end,
    PacketUpType = hpr_packet_up:type(PacketUp),
    case execute_checks(PacketUp, Checks) of
        {error, _Reason} = Error ->
            lager:debug("packet failed verification: ~p", [_Reason]),
            hpr_metrics:observe_packet_up(PacketUpType, Error, 0, Timestamp),
            Error;
        ok ->
            ok = hpr_netid_stats:maybe_report_net_id(PacketUp),
            do_handle_packet(PacketUp, Timestamp)
    end.

%% @doc Rate-limit decision, cheap enough to make before spawning anything.
%%
%% Two ETS lookups against limits the routing process would otherwise apply
%% after it had already been created, its metadata built and its payload
%% re-hashed. Takes the gateway and payload hash rather than digging them out of
%% the packet, because the stream process is holding both already.
-spec admit(Gateway :: libp2p_crypto:pubkey_bin(), PHash :: binary()) ->
    ok | {error, gateway_limit_exceeded | packet_limit_exceeded}.
admit(Gateway, PHash) ->
    %% Fail open. This runs in the gateway's stream process, so an unexpected
    %% throttle error here would take down that gateway's whole connection --
    %% where the same error inside the routing process only ever cost one
    %% packet. Dropping every packet from a hotspot because the rate limiter is
    %% broken is strictly worse than not rate limiting it.
    try
        case check_gateway_throttle(Gateway) of
            false ->
                {error, gateway_limit_exceeded};
            true ->
                case check_packet_throttle(Gateway, PHash) of
                    false -> {error, packet_limit_exceeded};
                    true -> ok
                end
        end
    catch
        Class:Reason ->
            lager:error("admit check failed, admitting anyway: ~p:~p", [Class, Reason]),
            ok
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
            %% Queued, the copy establishing routes will route this one too.
            %% Otherwise the entry moved on since we read it: look again.
            case hpr_routing_cache:queue(RoutingEntry, {PacketUp, Timestamp}) of
                ok -> ok;
                retry -> do_handle_packet(PacketUp, Timestamp)
            end;
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
                    true ->
                        EmptyRoutes;
                    false ->
                        _ = hpr_device_stats:update(DevAddr),
                        [RouteETS | EmptyRoutes]
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
        {ok, SessionKey, SKFMaxCopies} ->
            _ = hpr_device_stats:update(SessionKey),
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
    empty | false | {ok, binary(), non_neg_integer()}.
check_route_skfs(PacketUp, DevAddr, SKFETS) ->
    %% The whole candidate set in one call, not chunked. Chunking existed
    %% because the old table shape could not look up by DevAddr and had to scan
    %% the table (23ms on a 137k-row route), so a bounded chunk was the only way
    %% to avoid paying for all of it. Now that DevAddr is the key prefix this is
    %% a range read, and handing every candidate to match_session_key/2 at once
    %% is what lets its frame-counter search be the outer loop -- inverting the
    %% loops inside a 100-key chunk would save nothing.
    case hpr_skf_storage:lookup(SKFETS, DevAddr) of
        [] ->
            empty;
        SKFs ->
            Payload = hpr_packet_up:payload(PacketUp),
            case hpr_lorawan:match_session_key(Payload, [SK || {SK, _} <- SKFs]) of
                false ->
                    false;
                {ok, SessionKey} ->
                    {SessionKey, MaxCopies} = lists:keyfind(SessionKey, 1, SKFs),
                    {ok, SessionKey, MaxCopies}
            end
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
            PubKeyBin = hpr_packet_up:gateway(PacketUp),
            Region = hpr_packet_up:region(PacketUp),
            MaxCopies =
                case {SKFMaxCopies, PacketUpType} of
                    {0, {join_req, _}} -> ?MAX_JOIN_REQ;
                    {0, _} -> hpr_route:max_copies(Route);
                    _ -> SKFMaxCopies
                end,
            case hpr_multi_buy:update_counter(Key, MaxCopies, PubKeyBin, Region, Route) of
                {error, Reason} = Error ->
                    lager:debug(RouteMD, "not sending ~p", [Reason]),
                    Error;
                {ok, IsFree} ->
                    Server = hpr_route:server(Route),
                    Protocol = hpr_route:protocol(Server),
                    RouteID = hpr_route:id(Route),
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
            %% The packet was delivered but is never reported, and so never
            %% charged -- report_packet/4 takes a single route and there is no
            %% one route to attribute it to. Counted so the volume is a graph
            %% rather than an error line per packet; which route should win when
            %% devaddr ranges overlap across OUIs is a config question, not one
            %% to decide here.
            RouteIDs = [hpr_route:id(R) || R <- Routes],
            ok = hpr_metrics:unreported_packet(RouteIDs),
            lager:warning("routed packet to non unique OUI/Net ID ~p", [
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

%% Drop packets from denylisted gateways. The denylist is a cheap, usually-empty
%% ETS lookup, so we run it before signature/throttle work. The gateway field is
%% not signature-verified at this point, but that is fine for a denylist: a packet
%% spoofing a denied gateway's key still fails packet_session_check downstream.
-spec gateway_denied_check(PacketUp :: hpr_packet_up:packet()) ->
    boolean().
gateway_denied_check(PacketUp) ->
    not hpr_denylist:is_denied(hpr_packet_up:gateway(PacketUp)).

-spec packet_session_check(PacketUp :: hpr_packet_up:packet(), SessionKey :: undefined | binary()) ->
    boolean().
packet_session_check(PacketUp, undefined) ->
    hpr_packet_up:verify(PacketUp);
packet_session_check(PacketUp, SessionKey) ->
    hpr_packet_up:verify(PacketUp, SessionKey).

-spec gateway_throttle_check(PacketUp :: hpr_packet_up:packet()) ->
    boolean().
gateway_throttle_check(PacketUp) ->
    check_gateway_throttle(hpr_packet_up:gateway(PacketUp)).

-spec packet_throttle_check(PacketUp :: hpr_packet_up:packet()) ->
    boolean().
packet_throttle_check(PacketUp) ->
    check_packet_throttle(hpr_packet_up:gateway(PacketUp), hpr_packet_up:phash(PacketUp)).

-spec check_gateway_throttle(Gateway :: libp2p_crypto:pubkey_bin()) -> boolean().
check_gateway_throttle(Gateway) ->
    case throttle:check(?GATEWAY_THROTTLE, Gateway) of
        {limit_exceeded, _, _} -> false;
        _ -> true
    end.

-spec check_packet_throttle(Gateway :: libp2p_crypto:pubkey_bin(), PHash :: binary()) ->
    boolean().
check_packet_throttle(Gateway, PHash) ->
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
        ?_test(maybe_deliver_packet_to_route_multi_buy()),
        ?_test(handle_packet_gateway_denied())
    ]}.

foreach_setup() ->
    true = erlang:register(hpr_sup, self()),
    ok = hpr_route_ets:init(),
    ok = hpr_multi_buy:init(),
    ok = hpr_denylist:init(),
    ok = hpr_device_stats:init(),
    ok = hpr_netid_stats:init(),
    %% NOTE: These tests expect that routing is setup to hit multi-buy, but the
    %% grpc service is not there.
    application:set_env(hpr, multi_buy_enabled, true),
    meck:new(hpr_gateway_location, [passthrough]),
    meck:expect(hpr_gateway_location, get, fun(_) -> {error, not_implemented} end),
    meck:new(hpr_metrics, [passthrough]),
    ok.

foreach_cleanup(ok) ->
    true = ets:delete(hpr_multi_buy_ets),
    true = ets:delete(hpr_multi_buy_backoff_ets),
    %% Via the owning modules rather than by table name: hpr_devaddr_range_storage
    %% also owns the derived lookup index, and naming its tables here just means
    %% this cleanup silently rots the next time one is added.
    ok = hpr_devaddr_range_storage:test_delete_ets(),
    ok = hpr_eui_pair_storage:test_delete_ets(),
    true = ets:delete(hpr_device_stats_ets),
    true = ets:delete(hpr_netid_stats_ets),
    lists:foreach(
        fun(RouteETS) ->
            SKFETS = hpr_route_ets:skf_ets(RouteETS),
            ets:delete(SKFETS)
        end,
        ets:tab2list(hpr_routes_ets)
    ),
    true = ets:delete(hpr_routes_ets),
    ok = hpr_denylist:reset(),
    ok = hpr_denylist:test_delete_ets(),
    true = erlang:unregister(hpr_sup),
    meck:unload(hpr_gateway_location),
    meck:unload(hpr_metrics),
    ok.

handle_packet_gateway_denied() ->
    meck:expect(hpr_metrics, observe_packet_up, fun(_, _, _, _) -> ok end),
    %% handle_packet/2 calls hpr_packet_up:md/2 which reaches gproc; start it so
    %% the md lookup returns "not found" (a warning) instead of crashing.
    {ok, _} = application:ensure_all_started(gproc),

    PacketUp = test_utils:uplink_packet_up(#{devaddr => 16#00000001}),
    Gateway = hpr_packet_up:gateway(PacketUp),
    Opts = #{gateway => Gateway},

    %% Not denied by default: the denylist check passes and routing continues
    %% (the test packet then fails on its bad signature, not gateway_denied).
    ?assertNotEqual({error, gateway_denied}, hpr_routing:handle_packet(PacketUp, Opts)),

    %% Once denied, the packet is dropped with gateway_denied.
    ok = hpr_denylist:add(Gateway),
    ?assertEqual({error, gateway_denied}, hpr_routing:handle_packet(PacketUp, Opts)),
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
        maybe_deliver_packet_to_route(
            hpr_packet_up:type(PacketUp), PacketUp, RouteETS1, erlang:system_time(millisecond), 1
        )
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
        maybe_deliver_packet_to_route(
            hpr_packet_up:type(PacketUp), PacketUp, RouteETS1, erlang:system_time(millisecond), 1
        )
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
        maybe_deliver_packet_to_route(
            hpr_packet_up:type(PacketUp), PacketUp, RouteETS1, erlang:system_time(millisecond), 1
        )
    ),

    ?assertEqual(0, meck:num_calls(hpr_protocol_router, send, 4)),
    meck:unload(hpr_protocol_router),
    ok.

maybe_deliver_packet_to_route_multi_buy() ->
    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _, _, _) -> ok end),

    meck:expect(hpr_metrics, observe_multi_buy, fun(_, _, _) -> ok end),
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
        maybe_deliver_packet_to_route(
            hpr_packet_up:type(PacketUp), PacketUp, RouteETS1, erlang:system_time(millisecond), 1
        )
    ),
    %% Packet 2 refused using SKF Multi buy 1 (counter 2)
    ?assertEqual(
        {error, multi_buy},
        maybe_deliver_packet_to_route(
            hpr_packet_up:type(PacketUp), PacketUp, RouteETS1, erlang:system_time(millisecond), 1
        )
    ),

    %% Packet 3 accepted using route multi buy 3 (counter 3)
    ?assertEqual(
        {ok, true},
        maybe_deliver_packet_to_route(
            hpr_packet_up:type(PacketUp), PacketUp, RouteETS1, erlang:system_time(millisecond), 0
        )
    ),
    %% Packet 4 refused using route multi buy 3 (counter 4)
    ?assertEqual(
        {error, multi_buy},
        maybe_deliver_packet_to_route(
            hpr_packet_up:type(PacketUp), PacketUp, RouteETS1, erlang:system_time(millisecond), 0
        )
    ),

    ?assertEqual(2, meck:num_calls(hpr_protocol_router, send, 4)),
    meck:unload(hpr_protocol_router),
    ok.

-endif.
