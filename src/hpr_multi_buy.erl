-module(hpr_multi_buy).

-include("grpc/autogen/multi_buy_pb.hrl").
-include("grpc/autogen/iot_config_pb.hrl").
-include("hpr.hrl").

-export([
    init/0,
    init_channel/1,
    update_channel/2,
    cleanup_channel/1,
    update_counter/5,
    cleanup/1,
    make_key/2,
    enabled/0
]).

-define(ETS, hpr_multi_buy_ets).
-define(BACKOFF_ETS, hpr_multi_buy_backoff_ets).
-define(MULTIBUY, multi_buy).
-define(MAX_TOO_LOW, multi_buy_max_too_low).
-define(DENIED, denied).
-define(FAIL_ON_UNAVAILABLE, fail_on_unavailable).
-define(CLEANUP_TIME, timer:minutes(30)).
-define(BACKOFF_MIN, timer:seconds(1)).
-define(BACKOFF_MAX, timer:minutes(5)).
%% A route that fails closed drops every packet while it backs off, so it
%% recovers much sooner than one that just falls back to local counting.
-define(BACKOFF_MAX_FAIL_ON_UNAVAILABLE, timer:seconds(60)).
%% How long a single probe holds the rest of the traffic back once a backoff
%% window expires. Matches the grpc call timeout so a probe that never answers
%% can't wedge the route.
-define(PROBE_HOLD, timer:seconds(5)).

-type b58_key() :: binary().

-spec init() -> ok.
init() ->
    %% Table structure
    %% {Key :: binary(), Counter :: non_neg_integer(), Timestamp :: integer()}
    ets:new(?ETS, [
        public,
        named_table,
        set,
        {write_concurrency, true}
    ]),
    ets:new(?BACKOFF_ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true}
    ]),
    ok = scheduled_cleanup(?CLEANUP_TIME),
    ok.

-spec update_counter(
    Key :: binary(),
    Max :: non_neg_integer(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Region :: atom(),
    Route :: hpr_route:route()
) ->
    {ok, boolean()} | {error, ?MAX_TOO_LOW | ?MULTIBUY | ?DENIED | ?FAIL_ON_UNAVAILABLE}.
update_counter(_Key, Max, _PubKeyBin, _Region, _Route) when Max =< 0 ->
    {error, ?MAX_TOO_LOW};
update_counter(Key, Max, PubKeyBin, Region, Route) ->
    B58PubKeyBin = erlang:list_to_binary(
        libp2p_crypto:bin_to_b58(PubKeyBin)
    ),
    case is_using_custom_multi_buy(Route) of
        false ->
            update_counter_default(Key, Max, B58PubKeyBin, Region);
        true ->
            update_counter_custom(Key, Max, B58PubKeyBin, Region, Route)
    end.

-spec init_channel(Route :: hpr_route:route()) -> ok.
init_channel(Route) ->
    %% Pre-warm the custom multi-buy grpc channel for a route so the first
    %% uplinks (e.g. right after a restart) don't race a cold channel and pile
    %% onto the 5s grpc timeout. No-op for default routes. Idempotent
    %% (`ensure_channel' returns fast if the channel is already up) and
    %% non-blocking so it never stalls boot or route processing.
    case is_using_custom_multi_buy(Route) of
        false ->
            ok;
        true ->
            _ = erlang:spawn(fun() ->
                _ = ensure_channel(
                    make_channel_key(Route),
                    hpr_route:multi_buy_protocol(Route),
                    hpr_route:multi_buy_host(Route),
                    hpr_route:multi_buy_port(Route),
                    hpr_route:id(Route)
                )
            end),
            ok
    end.

-spec update_channel(Previous :: hpr_route:route() | undefined, Route :: hpr_route:route()) -> ok.
update_channel(undefined, Route) ->
    init_channel(Route);
update_channel(Previous, Route) ->
    %% A route update can point multi-buy at a different service. The channel
    %% key carries the host and port, so without this the old channel stays
    %% connected for the life of the node with a stale backoff entry behind it.
    case make_channel_key(Previous) =:= make_channel_key(Route) of
        true -> ok;
        false -> ok = cleanup_channel(Previous)
    end,
    init_channel(Route).

-spec cleanup_channel(Route :: hpr_route:route()) -> ok.
cleanup_channel(Route) ->
    case is_using_custom_multi_buy(Route) of
        false ->
            ok;
        true ->
            Channel = make_channel_key(Route),
            true = ets:delete(?BACKOFF_ETS, Channel),
            lager:info("stopping multi-buy channel for route ~s", [hpr_route:id(Route)]),
            try grpcbox_channel:stop(Channel) of
                _ -> ok
            catch
                _Class:_Reason -> ok
            end
    end.

-spec cleanup(Duration :: non_neg_integer()) -> ok.
cleanup(Duration) ->
    erlang:spawn(fun() ->
        Time = erlang:system_time(millisecond) - Duration,
        Deleted = ets:select_delete(?ETS, [
            {{'_', '_', '$3'}, [{'<', '$3', Time}], [true]}
        ]),
        lager:debug("expiring ~w keys", [Deleted])
    end),
    ok.

-spec make_key(hpr_packet_up:packet(), hpr_route:route()) -> binary().
make_key(PacketUp, Route) ->
    crypto:hash(sha256, <<
        (hpr_packet_up:phash(PacketUp))/binary,
        (hpr_route:lns(Route))/binary
    >>).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec update_counter_default(
    Key :: binary(),
    Max :: non_neg_integer(),
    B58PubKeyBin :: b58_key(),
    Region :: atom()
) ->
    {ok, boolean()} | {error, ?MULTIBUY | ?DENIED}.
update_counter_default(Key, Max, B58PubKeyBin, Region) ->
    case
        ets:update_counter(
            ?ETS, Key, {2, 1}, {default, 0, erlang:system_time(millisecond)}
        )
    of
        LocalCounter when LocalCounter > Max ->
            {error, ?MULTIBUY};
        LocalCounter ->
            case enabled() of
                false ->
                    %% ETS-only mode: no external service configured
                    {ok, false};
                true ->
                    case request_default(Key, B58PubKeyBin, Region) of
                        {ok, _ServiceCounter, true} ->
                            ets:update_counter(
                                ?ETS,
                                Key,
                                {2, Max - LocalCounter + 1},
                                {default, 0, erlang:system_time(millisecond)}
                            ),
                            lager:info("denied hotspot/region for ~s", [
                                hpr_utils:bin_to_hex_string(Key)
                            ]),
                            {error, ?DENIED};
                        {ok, ServiceCounter, _Denied} when ServiceCounter > Max ->
                            ets:update_counter(
                                ?ETS,
                                Key,
                                {2, Max - LocalCounter + 1},
                                {default, 0, erlang:system_time(millisecond)}
                            ),
                            {error, ?MULTIBUY};
                        {ok, _ServiceCounter, _Denied} ->
                            {ok, false};
                        {error, Reason} ->
                            lager:error("failed to get a counter for ~s: ~p", [
                                hpr_utils:bin_to_hex_string(Key), Reason
                            ]),
                            %% Unknown error packet is free
                            {ok, true}
                    end
            end
    end.

-spec request_default(
    Key :: binary(), B58PubKeyBin :: b58_key(), Region :: atom()
) ->
    {ok, non_neg_integer(), boolean()} | {error, any()}.
request_default(Key, B58PubKeyBin, Region) ->
    {Time, Result} = timer:tc(fun() ->
        Req = #multi_buy_inc_req_v1_pb{
            key = hpr_utils:bin_to_hex_string(Key),
            hotspot_key = B58PubKeyBin,
            region = Region
        },
        try helium_multi_buy_multi_buy_client:inc(Req, #{channel => ?MULTI_BUY_CHANNEL}) of
            {ok, #multi_buy_inc_res_v1_pb{count = Count, denied = Denied}, _} ->
                {ok, Count, Denied =:= true};
            _Any ->
                {error, _Any}
        catch
            _Class:Any -> {error, Any}
        end
    end),
    hpr_metrics:observe_multi_buy("default", Result, Time),
    Result.

-spec update_counter_custom(
    Key :: binary(),
    Max :: non_neg_integer(),
    B58PubKeyBin :: b58_key(),
    Region :: atom(),
    Route :: hpr_route:route()
) ->
    {ok, boolean()} | {error, ?MULTIBUY | ?DENIED | ?FAIL_ON_UNAVAILABLE}.
update_counter_custom(Key, Max, B58PubKeyBin, Region, Route) ->
    Channel = make_channel_key(Route),
    RouteID = hpr_route:id(Route),
    case check_backoff(Channel) of
        backoff ->
            FailOnUnavailable = hpr_route:multi_buy_fail_on_unavailable(Route),
            case FailOnUnavailable of
                true ->
                    ok = hpr_metrics:multi_buy_decision(RouteID, backoff_drop),
                    {error, ?FAIL_ON_UNAVAILABLE};
                false ->
                    ok = hpr_metrics:multi_buy_decision(RouteID, backoff_pass),
                    {ok, false}
            end;
        ready ->
            case request_custom(Key, B58PubKeyBin, Region, Route) of
                {ok, Count, true} ->
                    reset_backoff(Channel),
                    ok = hpr_metrics:multi_buy_decision(RouteID, denied),
                    lager:info("denied hotspot/region for ~s with ~p", [
                        hpr_utils:bin_to_hex_string(Key), Count
                    ]),
                    {error, ?DENIED};
                {ok, ServiceCounter, _Denied} when ServiceCounter > Max ->
                    reset_backoff(Channel),
                    ok = hpr_metrics:multi_buy_decision(RouteID, multi_buy),
                    {error, ?MULTIBUY};
                {ok, _ServiceCounter, _Denied} ->
                    reset_backoff(Channel),
                    ok = hpr_metrics:multi_buy_decision(RouteID, ok),
                    {ok, false};
                {error, Reason, false} ->
                    inc_backoff(Channel, backoff_max(false)),
                    ok = hpr_metrics:multi_buy_decision(RouteID, error_decision(Reason, false)),
                    lager:warning("failed to get a counter for ~s: ~p", [
                        hpr_utils:bin_to_hex_string(Key), Reason
                    ]),
                    update_counter_default(Key, Max, B58PubKeyBin, Region);
                {error, Reason, true} ->
                    inc_backoff(Channel, backoff_max(true)),
                    ok = hpr_metrics:multi_buy_decision(RouteID, error_decision(Reason, true)),
                    lager:warning("failed to get a counter for ~s: ~p", [
                        hpr_utils:bin_to_hex_string(Key), Reason
                    ]),
                    {error, ?FAIL_ON_UNAVAILABLE}
            end
    end.

-spec error_decision(Reason :: any(), FailOnUnavailable :: boolean()) -> atom().
error_decision(channel_not_ready, true) -> channel_not_ready_drop;
error_decision(channel_not_ready, false) -> channel_not_ready_fallback;
error_decision(_Reason, true) -> error_drop;
error_decision(_Reason, false) -> error_fallback.

-spec backoff_max(FailOnUnavailable :: boolean()) -> non_neg_integer().
backoff_max(true) -> ?BACKOFF_MAX_FAIL_ON_UNAVAILABLE;
backoff_max(false) -> ?BACKOFF_MAX.

-spec request_custom(
    Key :: binary(),
    B58PubKeyBin :: b58_key(),
    Region :: atom(),
    Route :: hpr_route:route()
) ->
    {ok, non_neg_integer(), boolean()} | {error, any(), boolean()}.
request_custom(Key, B58PubKeyBin, Region, Route) ->
    Protocol = hpr_route:multi_buy_protocol(Route),
    Host = hpr_route:multi_buy_host(Route),
    Port = hpr_route:multi_buy_port(Route),
    RouteID = hpr_route:id(Route),
    Channel = make_channel_key(Route),
    FailOnUnavailable = hpr_route:multi_buy_fail_on_unavailable(Route),
    %% Only issue the grpc call once the channel actually has a ready connection.
    %% Right after a restart the channel is cold: `ensure_channel' would connect
    %% (sync_start) and return `ok' before the HTTP/2 connection is up, so every
    %% request would then block on the 5s grpc timeout. Instead we fail fast and
    %% start the channel in the background, which lets the caller's backoff engage
    %% within milliseconds and short-circuit the rest of the burst.
    case grpcbox_channel:pick(Channel, unary) of
        {ok, _} ->
            {Time, Result} = timer:tc(fun() ->
                Req = #multi_buy_inc_req_v1_pb{
                    key = hpr_utils:bin_to_hex_string(Key),
                    hotspot_key = B58PubKeyBin,
                    region = Region
                },
                %% We do not need to set a rcv_timeout on the grpc call here because
                %% by default it is 5s which is the default rx window as well
                try helium_multi_buy_multi_buy_client:inc(Req, #{channel => Channel}) of
                    {ok, #multi_buy_inc_res_v1_pb{count = Count, denied = Denied}, _} ->
                        {ok, Count, Denied =:= true};
                    _Any ->
                        {error, _Any, FailOnUnavailable}
                catch
                    _Class:Any -> {error, Any, FailOnUnavailable}
                end
            end),
            hpr_metrics:observe_multi_buy(RouteID, Result, Time),
            Result;
        {error, _PickReason} ->
            _ = ensure_channel(Channel, Protocol, Host, Port, RouteID),
            {error, channel_not_ready, FailOnUnavailable}
    end.

-spec ensure_channel(
    Channel :: list(),
    Protocol :: http | https,
    Host :: string(),
    Port :: non_neg_integer(),
    RouteID :: hpr_route:id()
) -> ok | {error, any()}.
ensure_channel(Channel, Protocol, Host, Port, RouteID) ->
    case grpcbox_channel:pick(Channel, unary) of
        {ok, _} ->
            ok;
        {error, _PickReason} ->
            lager:info("starting multi-buy channel for route ~s", [RouteID]),
            try
                grpcbox_client:connect(Channel, [{Protocol, Host, Port, []}], #{
                    sync_start => true
                })
            of
                {ok, _Pid} ->
                    ok;
                {error, Reason} ->
                    lager:warning("failed to start multi-buy channel for route ~s: ~p", [
                        RouteID, Reason
                    ]),
                    {error, Reason}
            catch
                Class:Error ->
                    lager:warning("failed to start multi-buy channel for route ~s: ~p:~p", [
                        RouteID, Class, Error
                    ]),
                    {error, {Class, Error}}
            end
    end.

-spec make_channel_key(Route :: hpr_route:route()) -> list().
make_channel_key(Route) ->
    [
        hpr_route:id(Route),
        hpr_route:multi_buy_protocol(Route),
        hpr_route:multi_buy_host(Route),
        hpr_route:multi_buy_port(Route)
    ].

-spec is_using_custom_multi_buy(Route :: hpr_route:route()) -> boolean().
is_using_custom_multi_buy(Route) ->
    case hpr_route:multi_buy(Route) of
        undefined -> false;
        _ -> true
    end.

%% Table structure
%% {Channel :: list(), Until :: integer(), Backoff :: backoff:backoff(),
%%  ProbeUntil :: integer()}
%%
%% `Until' is when the backoff window ends, `ProbeUntil' how long a single
%% in-flight probe holds the rest of the traffic back past that point.
-spec check_backoff(Channel :: list()) -> ready | backoff.
check_backoff(Channel) ->
    Now = erlang:system_time(millisecond),
    case ets:lookup(?BACKOFF_ETS, Channel) of
        [] ->
            ready;
        [{_, Until, _, ProbeUntil}] when Now < Until orelse Now < ProbeUntil ->
            backoff;
        [{_, _, _, _}] ->
            claim_probe(Channel, Now)
    end.

%% Once the window expires every packet for the route would otherwise rush the
%% service at once. Let a single one through to probe it and hold the rest back
%% until that probe reports, so a service that is still down costs one timed-out
%% call instead of one per packet.
-spec claim_probe(Channel :: list(), Now :: integer()) -> ready | backoff.
claim_probe(Channel, Now) ->
    MS = [
        {
            {Channel, '$1', '$2', '$3'},
            [{'=<', '$1', Now}, {'=<', '$3', Now}],
            [{{{const, Channel}, '$1', '$2', {const, Now + ?PROBE_HOLD}}}]
        }
    ],
    case ets:select_replace(?BACKOFF_ETS, MS) of
        1 ->
            ready;
        0 ->
            %% Either another packet claimed the probe first, or a success
            %% cleared the entry in between.
            case ets:lookup(?BACKOFF_ETS, Channel) of
                [] -> ready;
                _ -> backoff
            end
    end.

-spec inc_backoff(Channel :: list(), MaxDelay :: non_neg_integer()) -> ok.
inc_backoff(Channel, MaxDelay) ->
    Now = erlang:system_time(millisecond),
    case ets:lookup(?BACKOFF_ETS, Channel) of
        [{_, Until, _Backoff0, _ProbeUntil}] when Now < Until ->
            %% Already backing off from a very recent failure: every request
            %% that was in flight when the channel died lands here at once.
            %% Without this guard each one would double the delay again,
            %% turning one dropped connection into minutes of dropped packets.
            %% Let the window run out before escalating further.
            ok;
        [{_, _, Backoff0, _ProbeUntil}] ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            true = ets:insert(?BACKOFF_ETS, {Channel, Now + Delay, Backoff1, 0});
        [] ->
            Backoff = backoff:init(?BACKOFF_MIN, MaxDelay),
            Delay = backoff:get(Backoff),
            true = ets:insert(?BACKOFF_ETS, {Channel, Now + Delay, Backoff, 0})
    end,
    ok.

-spec reset_backoff(Channel :: list()) -> ok.
reset_backoff(Channel) ->
    ets:delete(?BACKOFF_ETS, Channel),
    ok.

-spec enabled() -> boolean().
enabled() ->
    application:get_env(hpr, multi_buy_enabled, true).

-spec scheduled_cleanup(Duration :: non_neg_integer()) -> ok.
scheduled_cleanup(Duration) ->
    {ok, _} = timer:apply_interval(Duration, ?MODULE, cleanup, [Duration]),
    ok.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_SLEEP, 250).
-define(TEST_PERF, 1000).
-define(TEST_HOTSPOT_KEY, <<"test_hotspot_key">>).
-define(TEST_REGION, 'US915').
-define(TEST_ROUTE, #iot_config_route_v1_pb{multi_buy = undefined}).
-define(TEST_CUSTOM_ROUTE(FailOnUnavailable), #iot_config_route_v1_pb{
    id = "test-custom-route",
    multi_buy = #iot_config_multi_buy_v1_pb{
        protocol = http,
        host = "localhost",
        port = 9999,
        fail_on_unavailable = FailOnUnavailable
    }
}).

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        ?_test(test_max_too_low()),
        ?_test(test_update_counter()),
        ?_test(test_update_counter_with_service()),
        ?_test(test_update_counter_denied()),
        ?_test(test_update_counter_ets_only()),
        ?_test(test_cleanup()),
        ?_test(test_scheduled_cleanup()),
        ?_test(test_is_using_custom_multi_buy()),
        ?_test(test_update_counter_custom_success()),
        ?_test(test_update_counter_custom_denied()),
        ?_test(test_update_counter_custom_fail_on_unavailable()),
        ?_test(test_update_counter_custom_no_fail()),
        ?_test(test_update_counter_custom_backoff()),
        ?_test(test_update_counter_custom_concurrent_failures_dont_stack_backoff()),
        ?_test(test_update_counter_custom_single_flight_probe()),
        ?_test(test_backoff_max_capped_for_fail_on_unavailable()),
        ?_test(test_update_counter_custom_decision_metrics()),
        ?_test(test_update_counter_custom_channel_not_ready()),
        ?_test(test_init_channel()),
        ?_test(test_cleanup_channel()),
        ?_test(test_update_channel())
    ]}.

foreach_setup() ->
    meck:new(hpr_metrics, [passthrough]),
    meck:expect(hpr_metrics, observe_multi_buy, fun(_, _, _) -> ok end),
    meck:expect(hpr_metrics, multi_buy_decision, fun(_, _) -> ok end),
    meck:new(helium_multi_buy_multi_buy_client, [passthrough]),
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(_, _) -> {error, not_implemented} end),
    meck:new(grpcbox_channel, [passthrough]),
    meck:expect(grpcbox_channel, pick, fun(_, _) -> {ok, {self(), undefined}} end),
    meck:new(grpcbox_client, [passthrough]),
    meck:expect(grpcbox_client, connect, fun(_, _, _) -> {ok, self()} end),
    ok = ?MODULE:init(),
    application:set_env(hpr, multi_buy_enabled, true),
    ok.

foreach_cleanup(ok) ->
    _ = catch ets:delete(?ETS),
    _ = catch ets:delete(?BACKOFF_ETS),
    ?assert(meck:validate(hpr_metrics)),
    meck:unload(hpr_metrics),
    ?assert(meck:validate(helium_multi_buy_multi_buy_client)),
    meck:unload(helium_multi_buy_multi_buy_client),
    ?assert(meck:validate(grpcbox_channel)),
    meck:unload(grpcbox_channel),
    ?assert(meck:validate(grpcbox_client)),
    meck:unload(grpcbox_client),
    application:set_env(hpr, multi_buy_enabled, false),
    ok.

test_max_too_low() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 0,
    ?assertEqual(
        {error, ?MAX_TOO_LOW},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    ok.

test_update_counter() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 3,
    ?assertEqual(
        {ok, true}, ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    ?assertEqual(
        {ok, true}, ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    ?assertEqual(
        {ok, true}, ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    ?assertEqual(
        {error, ?MULTIBUY},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    ok.

test_update_counter_with_service() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 3,
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(#multi_buy_inc_req_v1_pb{key = K}, _) ->
        Map = persistent_term:get(test_update_counter_with_service_map, #{}),
        OldCount = maps:get(K, Map, 0),
        NewCount = OldCount + 1,
        persistent_term:put(test_update_counter_with_service_map, Map#{K => NewCount}),
        {ok, #multi_buy_inc_res_v1_pb{count = NewCount, denied = false}, undefined}
    end),

    ?assertEqual(
        {ok, false},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    ?assertEqual(
        {ok, false},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    ?assertEqual(
        {ok, false},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    ?assertEqual(
        {error, ?MULTIBUY},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    ok.

test_update_counter_denied() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 3,
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(#multi_buy_inc_req_v1_pb{}, _) ->
        {ok, #multi_buy_inc_res_v1_pb{count = 1, denied = true}, undefined}
    end),

    ?assertEqual(
        {error, ?DENIED},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    ok.

test_update_counter_ets_only() ->
    %% Disable external multi-buy service (ETS-only mode)
    application:set_env(hpr, multi_buy_enabled, false),

    Key = crypto:strong_rand_bytes(16),
    Max = 3,

    %% The external service should never be called in ETS-only mode
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(_, _) ->
        error(should_not_be_called)
    end),

    %% In ETS-only mode, successful updates return {ok, false} (not free)
    ?assertEqual(
        {ok, false},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    ?assertEqual(
        {ok, false},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    ?assertEqual(
        {ok, false},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    %% Once max is exceeded, still get multi_buy error from local ETS
    ?assertEqual(
        {error, ?MULTIBUY},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),

    %% Re-enable for other tests
    application:set_env(hpr, multi_buy_enabled, true),
    ok.

test_cleanup() ->
    Key1 = crypto:strong_rand_bytes(16),
    Key2 = crypto:strong_rand_bytes(16),
    Max = 1,
    ?assertEqual(
        {ok, true},
        ?MODULE:update_counter(Key1, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    ?assertEqual(
        {ok, true},
        ?MODULE:update_counter(Key2, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),

    ?assertEqual(2, ets:info(?ETS, size)),

    timer:sleep(50),
    ?assertEqual(ok, ?MODULE:cleanup(10)),
    timer:sleep(50),

    ?assertEqual(0, ets:info(?ETS, size)),

    ok.

test_scheduled_cleanup() ->
    Key1 = crypto:strong_rand_bytes(16),
    Key2 = crypto:strong_rand_bytes(16),
    Max = 1,
    ?assertEqual(
        {ok, true},
        ?MODULE:update_counter(Key1, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),
    ?assertEqual(
        {ok, true},
        ?MODULE:update_counter(Key2, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, ?TEST_ROUTE)
    ),

    ?assertEqual(2, ets:info(?ETS, size)),

    timer:sleep(50),

    %% This will cleanup in 25ms
    ?assertEqual(ok, scheduled_cleanup(25)),
    ?assertEqual(2, ets:info(?ETS, size)),

    timer:sleep(50),
    ?assertEqual(0, ets:info(?ETS, size)),

    ok.

test_is_using_custom_multi_buy() ->
    ?assertNot(is_using_custom_multi_buy(?TEST_ROUTE)),
    ?assert(is_using_custom_multi_buy(?TEST_CUSTOM_ROUTE(false))),
    ok.

test_update_counter_custom_success() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 3,
    Route = ?TEST_CUSTOM_ROUTE(false),
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(#multi_buy_inc_req_v1_pb{key = K}, _) ->
        Map = persistent_term:get(test_update_counter_custom_success_map, #{}),
        OldCount = maps:get(K, Map, 0),
        NewCount = OldCount + 1,
        persistent_term:put(test_update_counter_custom_success_map, Map#{K => NewCount}),
        {ok, #multi_buy_inc_res_v1_pb{count = NewCount, denied = false}, undefined}
    end),

    ?assertEqual(
        {ok, false}, ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route)
    ),
    ?assertEqual(
        {ok, false}, ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route)
    ),
    ?assertEqual(
        {ok, false}, ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route)
    ),
    ?assertEqual(
        {error, ?MULTIBUY},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route)
    ),
    ok.

test_update_counter_custom_denied() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 3,
    Route = ?TEST_CUSTOM_ROUTE(false),
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(#multi_buy_inc_req_v1_pb{}, _) ->
        {ok, #multi_buy_inc_res_v1_pb{count = 1, denied = true}, undefined}
    end),

    ?assertEqual(
        {error, ?DENIED},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route)
    ),
    ok.

test_update_counter_custom_fail_on_unavailable() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 3,
    Route = ?TEST_CUSTOM_ROUTE(true),
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(_, _) ->
        {error, unavailable}
    end),

    ?assertEqual(
        {error, ?FAIL_ON_UNAVAILABLE},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route)
    ),
    ok.

test_update_counter_custom_no_fail() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 3,
    Route = ?TEST_CUSTOM_ROUTE(false),
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(_, _) ->
        {error, unavailable}
    end),

    ?assertEqual(
        {ok, true},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route)
    ),
    ok.

test_update_counter_custom_backoff() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 3,
    Route = ?TEST_CUSTOM_ROUTE(true),
    Channel = make_channel_key(Route),

    %% First request fails, triggering backoff
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(_, _) ->
        {error, unavailable}
    end),
    ?assertEqual(
        {error, ?FAIL_ON_UNAVAILABLE},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route)
    ),

    %% Second request should be rejected by backoff without calling the service
    CallsBefore = meck:num_calls(helium_multi_buy_multi_buy_client, inc, 2),
    ?assertEqual(
        {error, ?FAIL_ON_UNAVAILABLE},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route)
    ),
    CallsAfter = meck:num_calls(helium_multi_buy_multi_buy_client, inc, 2),
    ?assertEqual(CallsBefore, CallsAfter),

    %% Reset backoff and verify service is called again
    reset_backoff(Channel),
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(#multi_buy_inc_req_v1_pb{}, _) ->
        {ok, #multi_buy_inc_res_v1_pb{count = 1, denied = false}, undefined}
    end),
    ?assertEqual(
        {ok, false},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route)
    ),
    ok.

test_update_counter_custom_concurrent_failures_dont_stack_backoff() ->
    %% Regression test: several requests in flight when a channel dies all
    %% fail at roughly the same time. Each one calls inc_backoff, but only the
    %% first should actually escalate the backoff for that window; the rest
    %% must be no-ops so one bad connection doesn't turn into minutes of
    %% dropped packets.
    Route = ?TEST_CUSTOM_ROUTE(true),
    Channel = make_channel_key(Route),
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(_, _) ->
        {error, unavailable}
    end),

    %% First failure starts the backoff window at BACKOFF_MIN.
    ?assertEqual(
        {error, ?FAIL_ON_UNAVAILABLE},
        update_counter_custom(
            crypto:strong_rand_bytes(16), 3, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route
        )
    ),
    [{_, UntilAfterFirst, _, _}] = ets:lookup(?BACKOFF_ETS, Channel),

    %% Simulate other in-flight requests failing within that same window by
    %% calling inc_backoff directly (update_counter_custom would otherwise be
    %% short-circuited by check_backoff, matching production behavior once the
    %% first failure lands).
    MaxDelay = backoff_max(true),
    inc_backoff(Channel, MaxDelay),
    inc_backoff(Channel, MaxDelay),
    inc_backoff(Channel, MaxDelay),

    [{_, UntilAfterMore, _, _}] = ets:lookup(?BACKOFF_ETS, Channel),
    ?assertEqual(UntilAfterFirst, UntilAfterMore),

    ok.

test_update_counter_custom_single_flight_probe() ->
    Max = 3,
    Route = ?TEST_CUSTOM_ROUTE(true),
    Channel = make_channel_key(Route),
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(_, _) ->
        {error, unavailable}
    end),

    %% One failure opens the backoff window.
    ?assertEqual(
        {error, ?FAIL_ON_UNAVAILABLE},
        update_counter_custom(
            crypto:strong_rand_bytes(16), Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route
        )
    ),

    %% Expire it, as if we had waited out the delay.
    true = ets:update_element(?BACKOFF_ETS, Channel, {2, 0}),

    %% The first packet past the window claims the probe. While that probe is
    %% still in flight the rest are held back rather than all piling onto a
    %% service that may still be down.
    ?assertEqual(ready, check_backoff(Channel)),
    ?assertEqual(backoff, check_backoff(Channel)),
    ?assertEqual(backoff, check_backoff(Channel)),

    %% A probe that never reports can't wedge the route: the hold expires.
    true = ets:update_element(?BACKOFF_ETS, Channel, {4, 0}),
    ?assertEqual(ready, check_backoff(Channel)),

    %% A success clears the whole thing, traffic resumes immediately.
    reset_backoff(Channel),
    ?assertEqual(ready, check_backoff(Channel)),

    %% End to end: a burst arriving after the window costs one call, not one
    %% per packet.
    ok = inc_backoff(Channel, backoff_max(true)),
    true = ets:update_element(?BACKOFF_ETS, Channel, {2, 0}),
    CallsBefore = meck:num_calls(helium_multi_buy_multi_buy_client, inc, 2),
    lists:foreach(
        fun(_) ->
            ?assertEqual(
                {error, ?FAIL_ON_UNAVAILABLE},
                update_counter_custom(
                    crypto:strong_rand_bytes(16), Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route
                )
            )
        end,
        lists:seq(1, 5)
    ),
    ?assertEqual(
        CallsBefore + 1, meck:num_calls(helium_multi_buy_multi_buy_client, inc, 2)
    ),

    %% The failed probe escalated the window rather than being swallowed by the
    %% anti-stacking guard.
    [{_, Until, _, _}] = ets:lookup(?BACKOFF_ETS, Channel),
    ?assert(Until > erlang:system_time(millisecond)),
    ok.

test_backoff_max_capped_for_fail_on_unavailable() ->
    ?assertEqual(timer:seconds(60), backoff_max(true)),
    ?assertEqual(timer:minutes(5), backoff_max(false)),

    Channel = make_channel_key(?TEST_CUSTOM_ROUTE(true)),
    MaxDelay = backoff_max(true),
    Delays = lists:map(
        fun(_) ->
            ok = inc_backoff(Channel, MaxDelay),
            [{_, Until, _, _}] = ets:lookup(?BACKOFF_ETS, Channel),
            Delay = Until - erlang:system_time(millisecond),
            %% Expire the window so the next failure escalates.
            true = ets:update_element(?BACKOFF_ETS, Channel, {2, 0}),
            Delay
        end,
        lists:seq(1, 10)
    ),

    ?assert(lists:max(Delays) =< timer:seconds(60)),
    ?assert(lists:last(Delays) > timer:seconds(59)),
    ok.

test_update_counter_custom_decision_metrics() ->
    Max = 3,
    Route = ?TEST_CUSTOM_ROUTE(true),
    RouteID = hpr_route:id(Route),
    Channel = make_channel_key(Route),

    %% A bought packet.
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(#multi_buy_inc_req_v1_pb{}, _) ->
        {ok, #multi_buy_inc_res_v1_pb{count = 1, denied = false}, undefined}
    end),
    ?assertEqual(
        {ok, false},
        update_counter_custom(
            crypto:strong_rand_bytes(16), Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route
        )
    ),
    ?assertEqual(1, meck:num_calls(hpr_metrics, multi_buy_decision, [RouteID, ok])),

    %% A failed call drops the packet and opens the window.
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(_, _) ->
        {error, unavailable}
    end),
    ?assertEqual(
        {error, ?FAIL_ON_UNAVAILABLE},
        update_counter_custom(
            crypto:strong_rand_bytes(16), Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route
        )
    ),
    ?assertEqual(1, meck:num_calls(hpr_metrics, multi_buy_decision, [RouteID, error_drop])),

    %% Packets dropped while backing off are counted too: this is the path that
    %% used to be invisible in metrics.
    ?assertEqual(
        {error, ?FAIL_ON_UNAVAILABLE},
        update_counter_custom(
            crypto:strong_rand_bytes(16), Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route
        )
    ),
    ?assertEqual(1, meck:num_calls(hpr_metrics, multi_buy_decision, [RouteID, backoff_drop])),

    %% So is a cold channel.
    reset_backoff(Channel),
    meck:expect(grpcbox_channel, pick, fun(_, _) -> {error, no_endpoints} end),
    ?assertEqual(
        {error, ?FAIL_ON_UNAVAILABLE},
        update_counter_custom(
            crypto:strong_rand_bytes(16), Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route
        )
    ),
    ?assertEqual(
        1, meck:num_calls(hpr_metrics, multi_buy_decision, [RouteID, channel_not_ready_drop])
    ),
    ok.

test_cleanup_channel() ->
    meck:expect(grpcbox_channel, stop, fun(_) -> ok end),

    Route = ?TEST_CUSTOM_ROUTE(true),
    Channel = make_channel_key(Route),
    ok = inc_backoff(Channel, backoff_max(true)),
    ?assertMatch([_], ets:lookup(?BACKOFF_ETS, Channel)),

    ?assertEqual(ok, ?MODULE:cleanup_channel(Route)),
    ?assertEqual([], ets:lookup(?BACKOFF_ETS, Channel)),
    ?assertEqual(1, meck:num_calls(grpcbox_channel, stop, [Channel])),

    %% Default routes have no channel to clean up.
    ?assertEqual(ok, ?MODULE:cleanup_channel(?TEST_ROUTE)),
    ?assertEqual(1, meck:num_calls(grpcbox_channel, stop, ['_'])),
    ok.

test_update_channel() ->
    meck:expect(grpcbox_channel, stop, fun(_) -> ok end),

    Route = ?TEST_CUSTOM_ROUTE(true),
    Channel = make_channel_key(Route),

    %% Same config: nothing to tear down.
    ok = inc_backoff(Channel, backoff_max(true)),
    ?assertEqual(ok, ?MODULE:update_channel(Route, Route)),
    ?assertMatch([_], ets:lookup(?BACKOFF_ETS, Channel)),
    ?assertEqual(0, meck:num_calls(grpcbox_channel, stop, ['_'])),

    %% Pointed at a different service: the old channel and its backoff go away.
    MovedRoute = Route#iot_config_route_v1_pb{
        multi_buy = #iot_config_multi_buy_v1_pb{
            protocol = http,
            host = "localhost",
            port = 10000,
            fail_on_unavailable = true
        }
    },
    ?assertEqual(ok, ?MODULE:update_channel(Route, MovedRoute)),
    ?assertEqual([], ets:lookup(?BACKOFF_ETS, Channel)),
    ?assertEqual(1, meck:num_calls(grpcbox_channel, stop, [Channel])),
    ok.

test_update_counter_custom_channel_not_ready() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 3,
    Route = ?TEST_CUSTOM_ROUTE(true),

    %% Channel is cold (e.g. right after a restart): `pick' has no ready endpoint.
    meck:expect(grpcbox_channel, pick, fun(_, _) -> {error, no_endpoints} end),
    %% The grpc `inc' must never be called while the channel is cold: we fail fast
    %% instead of blocking on the 5s grpc timeout.
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(_, _) ->
        error(should_not_be_called)
    end),

    ?assertEqual(
        {error, ?FAIL_ON_UNAVAILABLE},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route)
    ),
    ?assertEqual(0, meck:num_calls(helium_multi_buy_multi_buy_client, inc, 2)),

    %% The first fast failure engages backoff, so the next request short-circuits
    %% without even attempting to connect.
    ?assertEqual(backoff, check_backoff(make_channel_key(Route))),
    ?assertEqual(
        {error, ?FAIL_ON_UNAVAILABLE},
        ?MODULE:update_counter(Key, Max, ?TEST_HOTSPOT_KEY, ?TEST_REGION, Route)
    ),
    ?assertEqual(0, meck:num_calls(helium_multi_buy_multi_buy_client, inc, 2)),
    ok.

test_init_channel() ->
    %% Cold channel so `ensure_channel' has to connect.
    meck:expect(grpcbox_channel, pick, fun(_, _) -> {error, no_endpoints} end),

    %% Default route: nothing to pre-warm, no channel connect attempted.
    ConnectsBefore = meck:num_calls(grpcbox_client, connect, ['_', '_', '_']),
    ?assertEqual(ok, ?MODULE:init_channel(?TEST_ROUTE)),
    timer:sleep(50),
    ?assertEqual(
        ConnectsBefore, meck:num_calls(grpcbox_client, connect, ['_', '_', '_'])
    ),

    %% Custom route with a cold channel: connected in the background.
    Route = ?TEST_CUSTOM_ROUTE(false),
    ?assertEqual(ok, ?MODULE:init_channel(Route)),
    ok = meck:wait(grpcbox_client, connect, ['_', '_', '_'], timer:seconds(1)),
    ?assert(meck:num_calls(grpcbox_client, connect, ['_', '_', '_']) > ConnectsBefore),
    ok.

-endif.
