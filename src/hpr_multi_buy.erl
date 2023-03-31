-module(hpr_multi_buy).

-include("grpc/autogen/multi_buy_pb.hrl").
-include("hpr.hrl").

-export([
    init/0,
    update_counter/2,
    cleanup/1
]).

-define(ETS, hpr_multi_buy_ets).
-define(MULTIBUY, multi_buy).
-define(MAX_TOO_LOW, multi_buy_max_too_low).
-define(CLEANUP_TIME, timer:hours(1)).

-spec init() -> ok.
init() ->
    %% Table structure
    %% {Key :: binary(), Counter :: non_neg_integer() :: Timestamp :: integer()}
    ets:new(?ETS, [
        public,
        named_table,
        set,
        {write_concurrency, true}
    ]),
    ok = scheduled_cleanup(?CLEANUP_TIME),
    ok.

-spec update_counter(Key :: binary(), Max :: non_neg_integer()) ->
    {ok, boolean()} | {error, ?MAX_TOO_LOW | ?MULTIBUY}.
update_counter(_Key, Max) when Max =< 0 ->
    {error, ?MAX_TOO_LOW};
update_counter(Key, Max) ->
    case request(Key) of
        {ok, C} when C > Max ->
            {error, ?MULTIBUY};
        {ok, _C} ->
            {ok, false};
        {error, Reason} ->
            lager:error("failed to get a counter for ~s: ~p", [
                hpr_utils:bin_to_hex_string(Key), Reason
            ]),
            case
                ets:update_counter(
                    ?ETS, Key, {2, 1}, {default, 0, erlang:system_time(millisecond)}
                )
            of
                C when C > Max ->
                    {error, ?MULTIBUY};
                _C ->
                    {ok, true}
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

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec scheduled_cleanup(Duration :: non_neg_integer()) -> ok.
scheduled_cleanup(Duration) ->
    {ok, _} = timer:apply_interval(Duration, ?MODULE, cleanup, [Duration]),
    ok.

-spec request(Key :: binary()) -> {ok, non_neg_integer()} | {error, any()}.
request(Key) ->
    {Time, Result} = timer:tc(fun() ->
        Req = #multi_buy_inc_req_v1_pb{key = hpr_utils:bin_to_hex_string(Key)},
        case helium_multi_buy_multi_buy_client:inc(Req, #{channel => ?MULTI_BUY_CHANNEL}) of
            {ok, #multi_buy_inc_res_v1_pb{count = Count}, _} ->
                {ok, Count};
            _Any ->
                {error, _Any}
        end
    end),
    hpr_metrics:observe_multi_buy(Result, Time),
    Result.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_SLEEP, 250).
-define(TEST_PERF, 1000).

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        ?_test(test_max_too_low()),
        ?_test(test_update_counter()),
        ?_test(test_update_counter_with_service()),
        ?_test(test_cleanup()),
        ?_test(test_scheduled_cleanup())
    ]}.

foreach_setup() ->
    meck:new(hpr_metrics, [passthrough]),
    meck:expect(hpr_metrics, observe_multi_buy, fun(_, _) -> ok end),
    meck:new(helium_multi_buy_multi_buy_client, [passthrough]),
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(_, _) -> {error, not_implemented} end),
    ok = ?MODULE:init(),
    ok.

foreach_cleanup(ok) ->
    _ = catch ets:delete(?ETS),
    ?assert(meck:validate(hpr_metrics)),
    meck:unload(hpr_metrics),
    ?assert(meck:validate(helium_multi_buy_multi_buy_client)),
    meck:unload(helium_multi_buy_multi_buy_client),
    ok.

test_max_too_low() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 0,
    ?assertEqual({error, ?MAX_TOO_LOW}, ?MODULE:update_counter(Key, Max)),
    ok.

test_update_counter() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 3,
    ?assertEqual({ok, true}, ?MODULE:update_counter(Key, Max)),
    ?assertEqual({ok, true}, ?MODULE:update_counter(Key, Max)),
    ?assertEqual({ok, true}, ?MODULE:update_counter(Key, Max)),
    ?assertEqual({error, ?MULTIBUY}, ?MODULE:update_counter(Key, Max)),
    ok.

test_update_counter_with_service() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 3,
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(#multi_buy_inc_req_v1_pb{key = K}, _) ->
        Map = persistent_term:get(test_update_counter_with_service_map, #{}),
        OldCount = maps:get(K, Map, 0),
        NewCount = OldCount + 1,
        persistent_term:put(test_update_counter_with_service_map, Map#{K => NewCount}),
        {ok, #multi_buy_inc_res_v1_pb{count = NewCount}, undefined}
    end),

    ?assertEqual({ok, false}, ?MODULE:update_counter(Key, Max)),
    ?assertEqual({ok, false}, ?MODULE:update_counter(Key, Max)),
    ?assertEqual({ok, false}, ?MODULE:update_counter(Key, Max)),
    ?assertEqual({error, ?MULTIBUY}, ?MODULE:update_counter(Key, Max)),
    ok.

test_cleanup() ->
    Key1 = crypto:strong_rand_bytes(16),
    Key2 = crypto:strong_rand_bytes(16),
    Max = 1,
    ?assertEqual({ok, true}, ?MODULE:update_counter(Key1, Max)),
    ?assertEqual({ok, true}, ?MODULE:update_counter(Key2, Max)),

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
    ?assertEqual({ok, true}, ?MODULE:update_counter(Key1, Max)),
    ?assertEqual({ok, true}, ?MODULE:update_counter(Key2, Max)),

    ?assertEqual(2, ets:info(?ETS, size)),

    timer:sleep(50),

    %% This will cleanup in 25ms
    ?assertEqual(ok, scheduled_cleanup(25)),
    ?assertEqual(2, ets:info(?ETS, size)),

    timer:sleep(50),
    ?assertEqual(0, ets:info(?ETS, size)),

    ok.

-endif.
