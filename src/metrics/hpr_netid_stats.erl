-module(hpr_netid_stats).

-export([
    init/0,
    maybe_report_net_id/1,
    export/0
]).

-define(ETS, hpr_netid_stats_ets).
-define(CLEANER, hpr_netid_stats_cleaner).
-define(HOUR_MS, timer:hours(1)).

-spec init() -> ok.
init() ->
    ets:new(?ETS, [
        public,
        named_table,
        set,
        {write_concurrency, true}
    ]),
    ok = ensure_cleaner(),
    ok.

-spec maybe_report_net_id(PacketUp :: hpr_packet_up:packet()) -> ok.
maybe_report_net_id(PacketUp) ->
    case hpr_packet_up:net_id(PacketUp) of
        {error, _Reason} ->
            ok;
        {ok, NetId} ->
            ets:update_counter(
                ?ETS, NetId, {2, 1}, {default, 0, erlang:system_time(millisecond)}
            ),
            ok
    end.

-spec export() -> list({non_neg_integer(), non_neg_integer()}).
export() ->
    ets:tab2list(?ETS).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

ensure_cleaner() ->
    case erlang:whereis(?CLEANER) of
        undefined ->
            Pid = erlang:spawn(fun cleaner_loop/0),
            true = erlang:register(?CLEANER, Pid),
            ok;
        _Pid ->
            ok
    end.

cleaner_loop() ->
    catch cleanup_old(),
    receive
        stop -> ok
    after ?HOUR_MS ->
        cleaner_loop()
    end.

-spec cleanup_old() -> ok.
cleanup_old() ->
    Now = erlang:system_time(millisecond),
    OneDayAgo = Now - 24 * 60 * 60 * 1000,
    %% Match-spec: match any {_, _, TS} where TS < OneDayAgo, delete it.
    MS = [
        {{'_', '_', '$1'}, [{'<', '$1', OneDayAgo}], [true]}
    ],
    DeletedCount = ets:select_delete(?ETS, MS),
    lager:debug("removed ~p entries older than 24h", [DeletedCount]).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        ?_test(test_maybe_report_net_id()),
        ?_test(test_cleanup_old())
    ]}.

foreach_setup() ->
    application:ensure_all_started(lager),
    ok = ?MODULE:init(),
    ok.

foreach_cleanup(ok) ->
    _ = catch ets:delete(?ETS),
    application:stop(lager),
    ok.

test_maybe_report_net_id() ->
    PacketUp = test_utils:uplink_packet_up(#{}),

    ?assertEqual(ok, maybe_report_net_id(PacketUp)),
    ?assertEqual(ok, maybe_report_net_id(PacketUp)),
    ?assertEqual(ok, maybe_report_net_id(PacketUp)),

    ?assertMatch([{0, 3, _}], ets:tab2list(?ETS)),

    ok.

test_cleanup_old() ->
    %% seed: one fresh, one old
    T0 = erlang:system_time(millisecond),
    ets:insert(?ETS, {1, 3, T0}),
    ets:insert(?ETS, {2, 5, T0 - 25 * 60 * 60 * 1000}),
    ok = cleanup_old(),
    ?assertEqual([{1, 3, T0}], lists:sort(ets:tab2list(?ETS))).

-endif.
