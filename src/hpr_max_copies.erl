-module(hpr_max_copies).

-export([
    init/0,
    check/2,
    cleanup/1
]).

-define(ETS, hpr_max_copies_ets).
-define(MAX_COPIES, max_copies).
-define(MAX_TOO_LOW, max_copies_max_too_low).
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

-spec check(Key :: binary(), Max :: non_neg_integer()) ->
    ok | {error, ?MAX_TOO_LOW | ?MAX_COPIES}.
check(_Key, Max) when Max =< 0 ->
    {error, ?MAX_TOO_LOW};
check(Key, Max) ->
    case
        ets:update_counter(
            ?ETS, Key, {2, 1}, {default, 0, erlang:system_time(millisecond)}
        )
    of
        C when C > Max ->
            {error, ?MAX_COPIES};
        _C ->
            ok
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
        ?_test(test_check()),
        ?_test(test_cleanup()),
        ?_test(test_scheduled_cleanup())
    ]}.

foreach_setup() ->
    ok = ?MODULE:init(),
    ok.

foreach_cleanup(ok) ->
    _ = catch ets:delete(?ETS),
    ok.

test_max_too_low() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 0,
    ?assertEqual({error, ?MAX_TOO_LOW}, ?MODULE:check(Key, Max)),
    ok.

test_check() ->
    Key = crypto:strong_rand_bytes(16),
    Max = 3,
    ?assertEqual(ok, ?MODULE:check(Key, Max)),
    ?assertEqual(ok, ?MODULE:check(Key, Max)),
    ?assertEqual(ok, ?MODULE:check(Key, Max)),
    ?assertEqual({error, ?MAX_COPIES}, ?MODULE:check(Key, Max)),
    ok.

test_cleanup() ->
    Key1 = crypto:strong_rand_bytes(16),
    Key2 = crypto:strong_rand_bytes(16),
    Max = 1,
    ?assertEqual(ok, ?MODULE:check(Key1, Max)),
    ?assertEqual(ok, ?MODULE:check(Key2, Max)),

    ?assertEqual(2, ets:info(?ETS, size)),

    timer:sleep(10),
    ?assertEqual(ok, ?MODULE:cleanup(10)),
    timer:sleep(10),

    ?assertEqual(0, ets:info(?ETS, size)),

    ok.

test_scheduled_cleanup() ->
    Key1 = crypto:strong_rand_bytes(16),
    Key2 = crypto:strong_rand_bytes(16),
    Max = 1,
    ?assertEqual(ok, ?MODULE:check(Key1, Max)),
    ?assertEqual(ok, ?MODULE:check(Key2, Max)),

    ?assertEqual(2, ets:info(?ETS, size)),

    timer:sleep(10),

    %% This will cleanup in 25ms 
    ?assertEqual(ok, scheduled_cleanup(25)),
    ?assertEqual(2, ets:info(?ETS, size)),

    timer:sleep(30),
    ?assertEqual(0, ets:info(?ETS, size)),

    ok.

-endif.
