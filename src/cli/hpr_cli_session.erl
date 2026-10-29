%%%-------------------------------------------------------------------
%% @doc hpr_cli_session
%%
%% Gateway sessions on this node: how many are open, and spreading out when
%% they reconnect. See the "Session spread" section of
%% hpr_packet_router_service for why that matters.
%% @end
%%%-------------------------------------------------------------------
-module(hpr_cli_session).

-behavior(clique_handler).

-export([register_cli/0]).

-define(DEFAULT_SPREAD_MINUTES, 30).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [session_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [session_cmd()]
    ).

%%--------------------------------------------------------------------
%% Session
%%--------------------------------------------------------------------

session_usage() ->
    [
        ["session"],
        [
            "\n\n",
            "session count                 - Number of gateways with an open stream on this node\n",
            "session spread --commit       - Close every gateway's stream once, at a random time\n",
            "                                within the window, so they stop reconnecting in step\n",
            "    [--minutes] default: 30 (use 30 or more; anything shorter only narrows the wave)\n",
            "session spread status         - Progress of a running spread\n",
            "session spread cancel         - Stop a running spread\n",
            "\n",
            "Run the spread on every node behind the same load balancer: a gateway whose\n",
            "close fires after it has moved to another node is skipped here.\n"
        ]
    ].

session_cmd() ->
    [
        [["session", "count"], [], [], fun session_count/3],
        [
            ["session", "spread"],
            [],
            [
                {minutes, [{longname, "minutes"}, {datatype, integer}]},
                {commit, [{longname, "commit"}, {datatype, boolean}]}
            ],
            fun session_spread/3
        ],
        [["session", "spread", "status"], [], [], fun session_spread_status/3],
        [["session", "spread", "cancel"], [], [], fun session_spread_cancel/3]
    ].

session_count(["session", "count"], [], []) ->
    c_text("~w gateways connected", [hpr_packet_router_service:connected_count()]);
session_count(_, _, _) ->
    usage.

session_spread(["session", "spread"], [], Flags) ->
    Options = maps:from_list(Flags),
    Minutes = maps:get(minutes, Options, ?DEFAULT_SPREAD_MINUTES),
    case {maps:is_key(commit, Options), Minutes > 0} of
        {_, false} ->
            c_text("--minutes must be at least 1");
        {false, true} ->
            c_text(
                "Would close ~w gateway streams over ~w minutes. Add --commit to do it.",
                [hpr_packet_router_service:connected_count(), Minutes]
            );
        {true, true} ->
            case hpr_packet_router_service:spread_sessions(timer:minutes(Minutes)) of
                {ok, Count} ->
                    c_text(
                        "Closing ~w gateway streams over ~w minutes. "
                        "Watch it with: session spread status",
                        [Count, Minutes]
                    );
                {error, already_running} ->
                    c_text("A spread is already running. See: session spread status")
            end
    end;
session_spread(_, _, _) ->
    usage.

session_spread_status(["session", "spread", "status"], [], []) ->
    case hpr_packet_router_service:spread_status() of
        not_running ->
            c_text("No spread running");
        {running, #{total := Total, closed := Closed, not_found := NotFound, ends_in_ms := EndsIn}} ->
            c_text(
                "~w of ~w done: ~w closed, ~w no longer on this node; window ends in ~ws",
                [Closed + NotFound, Total, Closed, NotFound, max(0, EndsIn) div 1000]
            )
    end;
session_spread_status(_, _, _) ->
    usage.

session_spread_cancel(["session", "spread", "cancel"], [], []) ->
    case hpr_packet_router_service:cancel_spread() of
        ok -> c_text("Spread cancelled; closes not yet made are dropped");
        not_running -> c_text("No spread running")
    end;
session_spread_cancel(_, _, _) ->
    usage.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).
