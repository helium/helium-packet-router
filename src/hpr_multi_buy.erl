-module(hpr_multi_buy).

-include("grpc/autogen/multi_buy_pb.hrl").
-include("grpc/autogen/iot_config_pb.hrl").
-include("hpr.hrl").

-export([
    init/0,
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
            Any -> {error, Any}
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
    case is_in_backoff(Channel) of
        true ->
            FailOnUnavailable = hpr_route:multi_buy_fail_on_unavailable(Route),
            case FailOnUnavailable of
                true -> {error, ?FAIL_ON_UNAVAILABLE};
                false -> {ok, false}
            end;
        false ->
            case request_custom(Key, B58PubKeyBin, Region, Route) of
                {ok, Count, true} ->
                    reset_backoff(Channel),
                    lager:info("denied hotspot/region for ~s with ~p", [
                        hpr_utils:bin_to_hex_string(Key), Count
                    ]),
                    {error, ?DENIED};
                {ok, ServiceCounter, _Denied} when ServiceCounter > Max ->
                    reset_backoff(Channel),
                    {error, ?MULTIBUY};
                {ok, _ServiceCounter, _Denied} ->
                    reset_backoff(Channel),
                    {ok, false};
                {error, Reason, false} ->
                    inc_backoff(Channel),
                    lager:warning("failed to get a counter for ~s: ~p", [
                        hpr_utils:bin_to_hex_string(Key), Reason
                    ]),
                    update_counter_default(Key, Max, B58PubKeyBin, Region);
                {error, Reason, true} ->
                    inc_backoff(Channel),
                    lager:warning("failed to get a counter for ~s: ~p", [
                        hpr_utils:bin_to_hex_string(Key), Reason
                    ]),
                    {error, ?FAIL_ON_UNAVAILABLE}
            end
    end.

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
    case ensure_channel(Channel, Protocol, Host, Port, RouteID) of
        ok ->
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
                    Any -> {error, Any, FailOnUnavailable}
                end
            end),
            hpr_metrics:observe_multi_buy(RouteID, Result, Time),
            Result;
        {error, ConnectReason} ->
            {error, ConnectReason, FailOnUnavailable}
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

-spec is_in_backoff(Channel :: list()) -> boolean().
is_in_backoff(Channel) ->
    case ets:lookup(?BACKOFF_ETS, Channel) of
        [{_, Until, _}] -> erlang:system_time(millisecond) < Until;
        [] -> false
    end.

-spec inc_backoff(Channel :: list()) -> ok.
inc_backoff(Channel) ->
    Now = erlang:system_time(millisecond),
    case ets:lookup(?BACKOFF_ETS, Channel) of
        [{_, _, Backoff0}] ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            true = ets:insert(?BACKOFF_ETS, {Channel, Now + Delay, Backoff1});
        [] ->
            Backoff = backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX),
            Delay = backoff:get(Backoff),
            true = ets:insert(?BACKOFF_ETS, {Channel, Now + Delay, Backoff})
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
        ?_test(test_update_counter_custom_backoff())
    ]}.

foreach_setup() ->
    meck:new(hpr_metrics, [passthrough]),
    meck:expect(hpr_metrics, observe_multi_buy, fun(_, _, _) -> ok end),
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

-endif.
