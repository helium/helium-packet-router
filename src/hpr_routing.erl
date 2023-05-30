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
                    {Routed, IsFree} = maybe_deliver_packet_to_routes(Packet, Routes),
                    ok = maybe_report_packet(Routes, Routed, IsFree, Packet),
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
    case application:get_env(?APP, skf_enabled, true) of
        true ->
            find_routes_for_uplink(Packet);
        false ->
            {uplink, {_Type, DevAddr}} = hpr_packet_up:type(Packet),
            {ok, hpr_route_ets:lookup_devaddr_range(DevAddr)}
    end.

-record(frfu, {
    devaddr :: non_neg_integer(),
    payload :: binary(),
    routes :: [hpr_route:route()],
    dev_range_routes :: [hpr_route:route()],
    no_skf_routes :: [hpr_route:route()]
}).

-spec find_routes_for_uplink(Packet :: hpr_packet_up:packet()) ->
    {ok, [hpr_route:route()]} | {error, invalid_mic}.
find_routes_for_uplink(Packet) ->
    {uplink, {_Type, DevAddr}} = hpr_packet_up:type(Packet),
    case hpr_route_ets:select_skf(DevAddr) of
        '$end_of_table' ->
            {ok, hpr_route_ets:lookup_devaddr_range(DevAddr)};
        Any ->
            Payload = hpr_packet_up:payload(Packet),
            find_routes_for_uplink(
                #frfu{
                    devaddr = DevAddr,
                    payload = Payload,
                    routes = [],
                    dev_range_routes = hpr_route_ets:lookup_devaddr_range(DevAddr),
                    no_skf_routes = []
                },
                Any
            )
    end.

find_routes_for_uplink(#frfu{routes = [], no_skf_routes = []}, '$end_of_table') ->
    {error, invalid_mic};
find_routes_for_uplink(#frfu{routes = Routes, no_skf_routes = NoSKFRoutes}, '$end_of_table') ->
    {ok, lists:usort(Routes ++ NoSKFRoutes)};
find_routes_for_uplink(
    #frfu{
        payload = Payload,
        routes = Routes,
        dev_range_routes = DevRangeRoutes,
        no_skf_routes = NoSKFRoutes0
    } = FRFU,
    {SKFs, Continuation}
) ->
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
                        Rs -> {true, Rs}
                    end
            end
        end,
        SKFs
    ),
    SKFsRoutes = lists:usort([RouteID || {_Key, RouteID} <- SKFs]),
    NoSKFRoutes1 = lists:filtermap(
        fun(Route) ->
            RouteID = hpr_route:id(Route),
            not lists:member(RouteID, SKFsRoutes)
        end,
        DevRangeRoutes
    ),
    find_routes_for_uplink(
        FRFU#frfu{
            routes = lists:usort(lists:flatten(MicFilteredRoutes) ++ Routes),
            no_skf_routes = lists:usort(NoSKFRoutes0 ++ NoSKFRoutes1)
        },
        hpr_route_ets:select_skf(Continuation)
    ).

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
    Routes :: [hpr_route:route()]
) -> {non_neg_integer(), boolean()}.
maybe_deliver_packet_to_routes(Packet, Routes) ->
    case erlang:length(Routes) of
        1 ->
            [Route] = Routes,
            case maybe_deliver_packet_to_route(Packet, Route) of
                {ok, IsFree} -> {1, IsFree};
                {error, _} -> {0, false}
            end;
        X when X > 1 ->
            MaybeDelivered = hpr_utils:pmap(
                fun(Route) ->
                    maybe_deliver_packet_to_route(Packet, Route)
                end,
                Routes
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
    Packet :: hpr_packet_up:packet(),
    Routes :: hpr_route:route()
) -> {ok, boolean()} | {error, any()}.
maybe_deliver_packet_to_route(Packet, Route) ->
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
            case hpr_multi_buy:update_counter(Key, hpr_route:max_copies(Route)) of
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
    Packet :: hpr_packet_up:packet()
) -> ok.
maybe_report_packet(_Routes, 0, _IsFree, _Packet) ->
    lager:debug("not reporting packet");
maybe_report_packet([Route | _] = Routes, Routed, IsFree, Packet) when Routed > 0 ->
    UniqueOUINetID = lists:usort([{hpr_route:oui(R), hpr_route:net_id(R)} || R <- Routes]),
    case erlang:length(UniqueOUINetID) of
        1 ->
            ok = hpr_packet_reporter:report_packet(Packet, Route, IsFree);
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
        ?_test(find_routes_for_uplink_multi_route_skf_success())
    ]}.

foreach_setup() ->
    hpr_route_ets:init(),
    ok.

foreach_cleanup(ok) ->
    true = ets:delete(hpr_routes_ets),
    true = ets:delete(hpr_route_eui_pairs_ets),
    true = ets:delete(hpr_route_devaddr_ranges_ets),
    true = ets:delete(hpr_route_skfs_ets),
    ok.

find_routes_for_uplink_no_skf() ->
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
    ok = hpr_route_ets:insert_route(Route1),

    DevAddr1 = 16#00000001,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_route_ets:insert_devaddr_range(DevAddrRange1),

    SessionKey1 = crypto:strong_rand_bytes(16),
    SKF1 = hpr_skf:test_new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1)
    }),
    ok = hpr_route_ets:insert_skf(SKF1),

    PacketUp = test_utils:uplink_packet_up(#{devaddr => DevAddr1, nwk_session_key => SessionKey1}),

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
    ok = hpr_route_ets:insert_route(Route1),

    DevAddr1 = 16#00000001,
    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => RouteID1, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_route_ets:insert_devaddr_range(DevAddrRange1),

    SessionKey1 = crypto:strong_rand_bytes(16),
    SKF1 = hpr_skf:test_new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1)
    }),
    ok = hpr_route_ets:insert_skf(SKF1),

    PacketUp = test_utils:uplink_packet_up(#{
        devaddr => DevAddr1, nwk_session_key => crypto:strong_rand_bytes(16)
    }),

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
    SKF1 = hpr_skf:test_new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1)
    }),
    ok = hpr_route_ets:insert_skf(SKF1),

    PacketUp = test_utils:uplink_packet_up(#{
        devaddr => DevAddr1, nwk_session_key => SessionKey1
    }),

    ?assertEqual({ok, [Route1, Route2]}, find_routes_for_uplink(PacketUp)),

    %% Testing with both Routes having a good SKF
    SKF2 = hpr_skf:test_new(#{
        route_id => RouteID2,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1)
    }),
    ok = hpr_route_ets:insert_skf(SKF2),

    ?assertEqual({ok, [Route1, Route2]}, find_routes_for_uplink(PacketUp)),

    %% No SKF at all
    ok = hpr_route_ets:delete_skf(SKF1),
    ok = hpr_route_ets:delete_skf(SKF2),

    ?assertEqual({ok, [Route1, Route2]}, find_routes_for_uplink(PacketUp)),

    ok.

find_routes_for_uplink_multi_route_skf_success() ->
    Routes = lists:map(
        fun(Idx) ->
            RouteID = io_lib:format("route_id_~p", [Idx]),
            Route = hpr_route:test_new(#{
                id => RouteID,
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

            ok = hpr_route_ets:insert_route(Route),
            {RouteID, Route}
        end,

        lists:seq(1, 250)
    ),

    MatchDevaddrRouteIndex = [1, 2, 112, 211],
    MatchSkfRouteIndex = [1, 211],
    %% NOTE: The config service prevents us from having SKFs in routes that do
    %% not have the corresponding devaddr range applied.
    %% MatchSkf = [1, 30, 40, 200, 211],

    DevAddr1 = 16#00000001,
    %% Insert devaddr range for 4 routes
    lists:foreach(
        fun(RouteIndex) ->
            {RouteID, _Route} = lists:nth(RouteIndex, Routes),
            DevAddrRange1 = hpr_devaddr_range:test_new(#{
                route_id => RouteID, start_addr => 16#00000000, end_addr => 16#00000002
            }),
            ok = hpr_route_ets:insert_devaddr_range(DevAddrRange1)
        end,
        MatchDevaddrRouteIndex
    ),

    %% Insert session key filter for 5 routes
    %% 2 of which overlap with the devaddr ranges.
    SessionKey1 = crypto:strong_rand_bytes(16),
    lists:foreach(
        fun(RouteIndex) ->
            {RouteID, _Route} = lists:nth(RouteIndex, Routes),
            SKF1 = hpr_skf:test_new(#{
                route_id => RouteID,
                devaddr => DevAddr1,
                session_key => hpr_utils:bin_to_hex_string(SessionKey1)
            }),
            ok = hpr_route_ets:insert_skf(SKF1),

            %% In between each valid session key filter, we're going to insert 100 fake
            %% skfs, to get the ets to page.
            lists:foreach(
                fun(_) ->
                    SKF2 = hpr_skf:test_new(#{
                        route_id => RouteID,
                        devaddr => DevAddr1,
                        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16))
                    }),
                    ok = hpr_route_ets:insert_skf(SKF2)
                end,
                lists:seq(1, 100)
            )
        end,
        MatchSkfRouteIndex
    ),

    PacketUp = test_utils:uplink_packet_up(#{
        devaddr => DevAddr1,
        nwk_session_key => SessionKey1
    }),

    %% We should find 4 matching routes
    %% - 1, 211 - Devaddr && SKF
    %% - 2, 112 - Devaddr
    %%
    %% 3 routes should be excluded
    %% - 30, 40, 200 - SKF only

    {ok, Found0} = find_routes_for_uplink(PacketUp),
    RouteIDs = lists:usort([erlang:list_to_binary(hpr_route:id(Route)) || Route <- Found0]),

    ?assertEqual(
        lists:usort([
            <<"route_id_1">>,
            <<"route_id_2">>,
            <<"route_id_112">>,
            <<"route_id_211">>
        ]),
        RouteIDs
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
        max_copies => 1,
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
        max_copies => 1,
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
    SKF1 = hpr_skf:test_new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey1)
    }),
    ok = hpr_route_ets:insert_skf(SKF1),

    PacketUp1 = test_utils:uplink_packet_up(#{
        devaddr => DevAddr1, nwk_session_key => crypto:strong_rand_bytes(16)
    }),

    ?assertEqual({ok, [Route2]}, find_routes_for_uplink(PacketUp1)),

    %% Testing with both Routes having a bad SKF
    SessionKey2 = crypto:strong_rand_bytes(16),
    SKF2 = hpr_skf:test_new(#{
        route_id => RouteID2,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey2)
    }),
    ok = hpr_route_ets:insert_skf(SKF2),

    ?assertEqual({error, invalid_mic}, find_routes_for_uplink(PacketUp1)),

    %% Testing one good SKF and one bad SKF
    SessionKey3 = crypto:strong_rand_bytes(16),
    SKF3 = hpr_skf:test_new(#{
        route_id => RouteID1,
        devaddr => DevAddr1,
        session_key => hpr_utils:bin_to_hex_string(SessionKey3)
    }),
    ok = hpr_route_ets:insert_skf(SKF3),

    PacketUp2 = test_utils:uplink_packet_up(#{devaddr => DevAddr1, nwk_session_key => SessionKey3}),

    ?assertEqual({ok, [Route1]}, find_routes_for_uplink(PacketUp2)),

    ok.

-endif.
