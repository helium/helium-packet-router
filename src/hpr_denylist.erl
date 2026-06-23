%% @doc Ephemeral gateway denylist.
%%
%% Gateways (identified by their libp2p `pubkey_bin') on this list have their
%% uplinks dropped by hpr_routing during packet validation. The backing ETS
%% table does not exist by default and is created lazily on the first `add/1';
%% `reset/0' removes it entirely. The denylist is in-memory only and is cleared
%% on restart.
%%
%% Because the table is usually created from a transient CLI/RPC process, it is
%% given `hpr_sup' as its heir so ownership survives that process exiting.
-module(hpr_denylist).

-export([
    is_denied/1,
    add/1,
    remove/1,
    reset/0,
    list/0,
    count/0
]).

-define(DENYLIST, hpr_gateway_denylist_ets).
-define(HEIR, hpr_sup).

-spec is_denied(Gateway :: binary()) -> boolean().
is_denied(Gateway) ->
    case ets:whereis(?DENYLIST) of
        undefined -> false;
        _ -> ets:member(?DENYLIST, Gateway)
    end.

-spec add(Gateway :: binary()) -> ok.
add(Gateway) ->
    Tab = ensure_table(),
    true = ets:insert(Tab, {Gateway}),
    ok.

-spec remove(Gateway :: binary()) -> ok.
remove(Gateway) ->
    case ets:whereis(?DENYLIST) of
        undefined -> ok;
        _ -> true = ets:delete(?DENYLIST, Gateway)
    end,
    ok.

-spec reset() -> ok.
reset() ->
    case ets:whereis(?DENYLIST) of
        undefined -> ok;
        _ -> true = ets:delete(?DENYLIST)
    end,
    ok.

-spec list() -> [binary()].
list() ->
    case ets:whereis(?DENYLIST) of
        undefined -> [];
        _ -> [Gateway || {Gateway} <- ets:tab2list(?DENYLIST)]
    end.

-spec count() -> non_neg_integer().
count() ->
    case ets:info(?DENYLIST, size) of
        undefined -> 0;
        Size -> Size
    end.

%% ------------------------------------------------------------------
%% Internal Functions
%% ------------------------------------------------------------------

%% @doc Return the denylist table, creating it if needed.
%%
%% The table is given `hpr_sup' as its heir so it outlives the (often transient)
%% process that first creates it. When `hpr_sup' is not running (e.g. in tests)
%% it is created with no heir.
-spec ensure_table() -> ets:table().
ensure_table() ->
    case ets:whereis(?DENYLIST) of
        undefined ->
            Heir =
                case erlang:whereis(?HEIR) of
                    undefined -> {heir, none};
                    Pid -> {heir, Pid, undefined}
                end,
            try
                ets:new(?DENYLIST, [
                    public,
                    named_table,
                    set,
                    {read_concurrency, true},
                    Heir
                ])
            catch
                %% Another process created it between the whereis and the new.
                error:badarg -> ?DENYLIST
            end;
        _ ->
            ?DENYLIST
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        ?_test(test_missing_table()),
        ?_test(test_add_remove()),
        ?_test(test_reset())
    ]}.

foreach_setup() ->
    ok.

foreach_cleanup(ok) ->
    _ = catch ets:delete(?DENYLIST),
    ok.

%% By default the table does not exist; reads are safe and report "not denied".
test_missing_table() ->
    Gateway = <<"gw1">>,
    ?assertEqual(undefined, ets:whereis(?DENYLIST)),
    ?assertEqual(false, ?MODULE:is_denied(Gateway)),
    ?assertEqual([], ?MODULE:list()),
    ?assertEqual(0, ?MODULE:count()),
    %% remove/reset are no-ops when the table is missing
    ?assertEqual(ok, ?MODULE:remove(Gateway)),
    ?assertEqual(ok, ?MODULE:reset()),
    ?assertEqual(undefined, ets:whereis(?DENYLIST)),
    ok.

test_add_remove() ->
    Gateway1 = <<"gw1">>,
    Gateway2 = <<"gw2">>,

    %% add lazily creates the table (with the {heir, none} fallback since hpr_sup
    %% is not running under eunit)
    ?assertEqual(ok, ?MODULE:add(Gateway1)),
    ?assertNotEqual(undefined, ets:whereis(?DENYLIST)),
    ?assert(?MODULE:is_denied(Gateway1)),
    ?assertEqual(false, ?MODULE:is_denied(Gateway2)),
    ?assertEqual(1, ?MODULE:count()),

    ?assertEqual(ok, ?MODULE:add(Gateway2)),
    ?assertEqual(2, ?MODULE:count()),
    ?assertEqual(lists:sort([Gateway1, Gateway2]), lists:sort(?MODULE:list())),

    %% adding the same gateway again is idempotent
    ?assertEqual(ok, ?MODULE:add(Gateway1)),
    ?assertEqual(2, ?MODULE:count()),

    ?assertEqual(ok, ?MODULE:remove(Gateway1)),
    ?assertEqual(false, ?MODULE:is_denied(Gateway1)),
    ?assert(?MODULE:is_denied(Gateway2)),
    ?assertEqual(1, ?MODULE:count()),
    ok.

test_reset() ->
    Gateway = <<"gw1">>,
    ?assertEqual(ok, ?MODULE:add(Gateway)),
    ?assert(?MODULE:is_denied(Gateway)),

    %% reset removes the whole table
    ?assertEqual(ok, ?MODULE:reset()),
    ?assertEqual(undefined, ets:whereis(?DENYLIST)),
    ?assertEqual(false, ?MODULE:is_denied(Gateway)),

    %% add after reset recreates it
    ?assertEqual(ok, ?MODULE:add(Gateway)),
    ?assert(?MODULE:is_denied(Gateway)),
    ok.

-endif.
