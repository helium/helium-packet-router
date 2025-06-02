-module(hpr_netid_stats).

-export([
    init/0,
    maybe_report_net_id/1,
    export/0
]).

-define(ETS, hpr_netid_stats_ets).

-spec init() -> ok.
init() ->
    ets:new(?ETS, [
        public,
        named_table,
        set,
        {write_concurrency, true}
    ]),
    ok.

-spec maybe_report_net_id(PacketUp :: hpr_packet_up:packet()) -> ok.
maybe_report_net_id(PacketUp) ->
    case hpr_packet_up:net_id(PacketUp) of
        {error, _Reason} ->
            ok;
        {ok, NetId} ->
            ets:update_counter(
                ?ETS, NetId, {2, 1}, {default, 0}
            ),
            ok
    end.

-spec export() -> list({non_neg_integer(), non_neg_integer()}).
export() ->
    ets:tab2list(?ETS).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        ?_test(test_maybe_report_net_id())
    ]}.

foreach_setup() ->
    ok = ?MODULE:init(),
    ok.

foreach_cleanup(ok) ->
    _ = catch ets:delete(?ETS),
    ok.

test_maybe_report_net_id() ->
    PacketUp = test_utils:uplink_packet_up(#{}),

    ?assertEqual(ok, maybe_report_net_id(PacketUp)),
    ?assertEqual(ok, maybe_report_net_id(PacketUp)),
    ?assertEqual(ok, maybe_report_net_id(PacketUp)),

    ?assertEqual([{0, 3}], ets:tab2list(?ETS)),

    ok.

-endif.
