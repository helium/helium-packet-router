-module(hpr_routing).

-include("hpr.hrl").

-export([
    init/0,
    handle_packet/1,
    find_routes/2
]).

-define(GATEWAY_THROTTLE, hpr_gateway_rate_limit).
-define(DEFAULT_GATEWAY_THROTTLE, 25).

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
            case ?MODULE:find_routes(PacketType, Packet) of
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
                    {Routed, IsFree} = maybe_deliver_packet_to_routes(Packet, Routes),
                    ok = maybe_report_packet(
                        [R || {R, _} <- Routes], Routed, IsFree, Packet, Start
                    ),
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

-spec find_routes(hpr_packet_up:type(), Packet :: hpr_packet_up:packet()) ->
    {ok, [{hpr_route:route(), non_neg_integer()}]} | {error, invalid_mic}.
find_routes({join_req, {AppEUI, DevEUI}}, _Packet) ->
    Routes = hpr_route_ets:lookup_eui_pair(AppEUI, DevEUI),
    {ok, [{R, 0} || R <- Routes]};
find_routes({uplink, {_Type, DevAddr}}, Packet) ->
    {Time, Results} = timer:tc(fun() -> find_routes_for_uplink(Packet, DevAddr) end),
    ok = hpr_metrics:observe_find_routes(Time),
    Results.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec find_routes_for_uplink(Packet :: hpr_packet_up:packet(), DevAddr :: non_neg_integer()) ->
    {ok, [{hpr_route:route(), non_neg_integer()}]} | {error, invalid_mic}.
find_routes_for_uplink(Packet, DevAddr) ->
    case hpr_route_ets:lookup_devaddr_range(DevAddr) of
        [] ->
            {ok, []};
        Routes ->
            find_routes_for_uplink(Packet, DevAddr, Routes, [], undefined)
    end.

-spec find_routes_for_uplink(
    Packet :: hpr_packet_up:packet(),
    DevAddr :: non_neg_integer(),
    [{hpr_route:route(), ets:table()}],
    [hpr_route:route()],
    undefined
    | {
        Route :: hpr_route:route(),
        SessionKey :: binary(),
        LastUsed :: non_neg_integer(),
        SKFMaxCopies :: non_neg_integer()
    }
) -> {ok, [{hpr_route:route(), non_neg_integer()}]} | {error, invalid_mic}.
find_routes_for_uplink(_Packet, _DevAddr, [], [], undefined) ->
    {error, invalid_mic};
find_routes_for_uplink(_Packet, _DevAddr, [], EmptyRoutes, undefined) ->
    {ok, [{R, 0} || R <- EmptyRoutes]};
find_routes_for_uplink(
    _Packet, DevAddr, [], EmptyRoutes, {Route, SessionKey, LastUsed, SKFMaxCopies}
) ->
    LastHour = erlang:system_time(millisecond) - ?SKF_UPDATE,
    case LastUsed < LastHour of
        true ->
            erlang:spawn(hpr_route_ets, update_skf, [
                DevAddr, SessionKey, hpr_route:id(Route), SKFMaxCopies
            ]);
        false ->
            ok
    end,
    {ok, [{Route, SKFMaxCopies} | [{R, 0} || R <- EmptyRoutes]]};
find_routes_for_uplink(Packet, DevAddr, [{Route, SKFETS} | Routes], EmptyRoutes, SelectedRoute) ->
    case check_route_skfs(Packet, DevAddr, SKFETS) of
        empty ->
            case hpr_route:ignore_empty_skf(Route) of
                true ->
                    find_routes_for_uplink(Packet, DevAddr, Routes, EmptyRoutes, SelectedRoute);
                false ->
                    find_routes_for_uplink(
                        Packet, DevAddr, Routes, [Route | EmptyRoutes], SelectedRoute
                    )
            end;
        false ->
            find_routes_for_uplink(Packet, DevAddr, Routes, EmptyRoutes, SelectedRoute);
        {ok, SessionKey, LastUsed, SKFMaxCopies} ->
            case SelectedRoute of
                undefined ->
                    find_routes_for_uplink(
                        Packet,
                        DevAddr,
                        Routes,
                        EmptyRoutes,
                        {Route, SessionKey, LastUsed, SKFMaxCopies}
                    );
                {_R, _S, L, _M} when LastUsed > L ->
                    find_routes_for_uplink(
                        Packet,
                        DevAddr,
                        Routes,
                        EmptyRoutes,
                        {Route, SessionKey, LastUsed, SKFMaxCopies}
                    );
                _ ->
                    find_routes_for_uplink(Packet, DevAddr, Routes, EmptyRoutes, SelectedRoute)
            end
    end.

-spec check_route_skfs(Packet :: hpr_packet_up:packet(), DevAddr :: non_neg_integer(), ets:table()) ->
    empty | false | {ok, binary(), non_neg_integer(), non_neg_integer()}.
check_route_skfs(Packet, DevAddr, SKFETS) ->
    case hpr_route_ets:select_skf(SKFETS, DevAddr) of
        '$end_of_table' ->
            empty;
        Continuation ->
            Payload = hpr_packet_up:payload(Packet),
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

-spec maybe_deliver_packet_to_routes(
    Packet :: hpr_packet_up:packet(),
    Routes :: [{hpr_route:route(), non_neg_integer()}]
) -> {non_neg_integer(), boolean()}.
maybe_deliver_packet_to_routes(Packet, Routes) ->
    maybe_deliver_packet_to_routes(Packet, Routes, {0, false}).

-spec maybe_deliver_packet_to_routes(
    Packet :: hpr_packet_up:packet(),
    Routes :: [{hpr_route:route(), non_neg_integer()}],
    {Routed :: non_neg_integer(), IsFree :: boolean()}
) -> {Routed :: non_neg_integer(), IsFree :: boolean()}.
maybe_deliver_packet_to_routes(_Packet, [], {Routed, IsFree}) ->
    {Routed, IsFree};
maybe_deliver_packet_to_routes(Packet, [{Route, SKFMaxCopies} | Routes], {Routed, true}) ->
    case maybe_deliver_packet_to_route(Packet, Route, SKFMaxCopies) of
        {ok, _IsFree} ->
            maybe_deliver_packet_to_routes(Packet, Routes, {Routed + 1, true});
        {error, _} ->
            maybe_deliver_packet_to_routes(Packet, Routes, {Routed, true})
    end;
maybe_deliver_packet_to_routes(Packet, [{Route, SKFMaxCopies} | Routes], {Routed, false}) ->
    case maybe_deliver_packet_to_route(Packet, Route, SKFMaxCopies) of
        {ok, IsFree} ->
            maybe_deliver_packet_to_routes(Packet, Routes, {Routed + 1, IsFree});
        {error, _} ->
            maybe_deliver_packet_to_routes(Packet, Routes, {Routed, false})
    end.

-spec maybe_deliver_packet_to_route(
    Packet :: hpr_packet_up:packet(),
    Routes :: hpr_route:route(),
    SKFMaxCopies :: non_neg_integer()
) -> {ok, boolean()} | {error, any()}.
maybe_deliver_packet_to_route(Packet, Route, SKFMaxCopies) ->
    RouteMD = hpr_route:md(Route),
    case hpr_route:active(Route) andalso hpr_route:locked(Route) == false of
        false ->
            lager:debug(RouteMD, "not sending, route locked or inactive"),
            {error, inactive};
        true ->
            Server = hpr_route:server(Route),
            Protocol = hpr_route:protocol(Server),
            Key = crypto:hash(sha256, <<
                (hpr_packet_up:phash(Packet))/binary, (hpr_route:lns(Route))/binary
            >>),
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
                    case deliver_packet(Protocol, Packet, Route) of
                        {error, Reason} = Error ->
                            lager:warning(RouteMD, "error ~p", [Reason]),
                            Error;
                        ok ->
                            lager:debug(RouteMD, "delivered"),
                            {Type, _} = hpr_packet_up:type(Packet),
                            ok = hpr_metrics:packet_up_per_oui(Type, hpr_route:oui(Route)),
                            {ok, IsFree}
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

-spec maybe_report_packet(
    Routes :: [hpr_route:route()],
    Routed :: non_neg_integer(),
    IsFree :: boolean(),
    Packet :: hpr_packet_up:packet(),
    ReceivedTime :: non_neg_integer()
) -> ok.
maybe_report_packet(_Routes, 0, _IsFree, _Packet, _ReceivedTime) ->
    lager:debug("not reporting packet");
maybe_report_packet([Route | _] = Routes, Routed, IsFree, Packet, ReceivedTime) when Routed > 0 ->
    UniqueOUINetID = lists:usort([{hpr_route:oui(R), hpr_route:net_id(R)} || R <- Routes]),
    case erlang:length(UniqueOUINetID) of
        1 ->
            ok = hpr_packet_reporter:report_packet(Packet, Route, IsFree, ReceivedTime);
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
        ?_test(find_routes_for_uplink_multi_route_failed()),
        ?_test(find_routes_for_uplink_ignore_empty_skf())
    ]}.

foreach_setup() ->
    true = erlang:register(hpr_sup, self()),
    hpr_route_ets:init(),
    ok.

foreach_cleanup(ok) ->
    true = ets:delete(hpr_route_devaddr_ranges_ets),
    true = ets:delete(hpr_route_eui_pairs_ets),
    lists:foreach(
        fun({_, {_, SKFETS}}) ->
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

    ?assertEqual({ok, [{Route1, 1}]}, find_routes_for_uplink(PacketUp, DevAddr1)),
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

    ?assertEqual({ok, [{Route1, 1}, {Route2, 0}]}, find_routes_for_uplink(PacketUp, DevAddr1)),

    %% Testing with both Routes having a good SKF the latest one only should be picked
    SKF2 = hpr_skf:new(#{
        route_id => RouteID2,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 2
    }),
    timer:sleep(1),
    ok = hpr_route_ets:insert_skf(SKF2),

    ?assertEqual({ok, [{Route2, 2}]}, find_routes_for_uplink(PacketUp, DevAddr1)),

    %% No SKF at all
    ok = hpr_route_ets:delete_skf(SKF1),
    ok = hpr_route_ets:delete_skf(SKF2),

    ?assertEqual({ok, [{Route2, 0}, {Route1, 0}]}, find_routes_for_uplink(PacketUp, DevAddr1)),

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

    ?assertEqual({ok, [{Route2, 0}]}, find_routes_for_uplink(PacketUp1, DevAddr1)),

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

    ?assertEqual({ok, [{Route1, 3}]}, find_routes_for_uplink(PacketUp2, DevAddr1)),

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

    ?assertEqual({ok, [{Route1, 1}]}, find_routes_for_uplink(PacketUp, DevAddr1)),

    %% Testing with both Routes having a good SKF the latest one only should be picked
    SKF2 = hpr_skf:new(#{
        route_id => RouteID2,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1),
        max_copies => 2
    }),
    timer:sleep(1),
    ok = hpr_route_ets:insert_skf(SKF2),

    ?assertEqual({ok, [{Route2, 2}]}, find_routes_for_uplink(PacketUp, DevAddr1)),

    %% No SKF at all
    ok = hpr_route_ets:delete_skf(SKF1),
    ok = hpr_route_ets:delete_skf(SKF2),

    ?assertEqual({ok, [{Route1, 0}]}, find_routes_for_uplink(PacketUp, DevAddr1)),

    ok.

-endif.
