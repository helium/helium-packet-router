-module(hpr_device_stats).

-export([
    init/0,
    update/1,
    run/0
]).

-define(ETS, hpr_device_stats_ets).

-record(entry, {
    key :: binary() | non_neg_integer(),
    time :: non_neg_integer()
}).

-spec init() -> ok.
init() ->
    ets:new(?ETS, [
        public,
        named_table,
        set,
        {write_concurrency, true}
    ]),
    ok.

-spec update(Key :: binary() | non_neg_integer()) -> ok.
update(Key) ->
    Now = erlang:system_time(millisecond),
    ets:insert(?ETS, #entry{
        key = Key,
        time = Now
    }),
    ok.

-spec run() -> non_neg_integer().
run() ->
    Now = erlang:system_time(millisecond),
    OneDayAgo = Now - 24 * 60 * 60 * 1000,
    % MS = ets:fun2ms(
    %     fun(#entry{time = Time}) when Time < OneDayAgo -> true end
    % ),
    MS = [
        {
            {entry, '_', '$1'},
            [{'<', '$1', OneDayAgo}],
            [true]
        }
    ],
    DeletedCount = ets:select_delete(?ETS, MS),
    lager:debug("remove ~p entries", [DeletedCount]),
    ets:info(?ETS, size).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        ?_test(test_update_run())
    ]}.

foreach_setup() ->
    ok = ?MODULE:init(),
    ok.

foreach_cleanup(ok) ->
    _ = catch ets:delete(?ETS),
    ok.

test_update_run() ->
    Key = <<>>,
    ?MODULE:update(Key),
    ?MODULE:update(Key),
    ?MODULE:update(Key),
    ?assertEqual(1, ?MODULE:run()),
    ?assertEqual(1, ?MODULE:run()),
    ok.

-endif.
