%%%-------------------------------------------------------------------
%% @doc pp_cli_trace
%% @end
%%%-------------------------------------------------------------------
-module(hpr_cli_trace).

-behavior(clique_handler).

-include("hpr.hrl").

-export([register_cli/0]).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [trace_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [trace_cmd()]
    ).

%%--------------------------------------------------------------------
%% Config
%%--------------------------------------------------------------------

trace_usage() ->
    [
        ["trace"],
        [
            "\n\n",
            "trace gateway <gateway_name>    - Trace Gateway (ex: happy-yellow-bird)\n",
            "trace devaddr <devaddr>         - Trace Device Address (ex: 00000010)\n",
            "trace app_eui <app_eui>         - Trace App EUI (ex: B216CDC4ABB9437)\n",
            "trace dev_eui <dev_eui>         - Trace Dev EUI (ex: B216CDC4ABB9437)\n"
        ]
    ].

trace_cmd() ->
    [
        [["trace", "gateway", '*'], [], [], fun trace_gateway/3],
        [["trace", "devaddr", '*'], [], [], fun trace_devaddr/3],
        [["trace", "app_eui", '*'], [], [], fun trace_app_eui/3],
        [["trace", "dev_eui", '*'], [], [], fun trace_dev_eui/3]
    ].

trace_gateway(["trace", "gateway", GatewayName], [], []) ->
    FileName = hpr_utils:trace(stream_gateway, GatewayName),
    FileName = hpr_utils:trace(packet_gateway, GatewayName),
    c_text("Tracing gateway ~s in ~s", [GatewayName, FileName]);
trace_gateway(_, _, _) ->
    usage.

trace_devaddr(["trace", "devaddr", GatewayName], [], []) ->
    FileName = hpr_utils:trace(devaddr, GatewayName),
    c_text("Tracing devaddr ~s in ~s", [GatewayName, FileName]);
trace_devaddr(_, _, _) ->
    usage.

trace_app_eui(["trace", "app_eui", GatewayName], [], []) ->
    FileName = hpr_utils:trace(app_eui, GatewayName),
    c_text("Tracing app_eui ~s in ~s", [GatewayName, FileName]);
trace_app_eui(_, _, _) ->
    usage.

trace_dev_eui(["trace", "dev_eui", GatewayName], [], []) ->
    FileName = hpr_utils:trace(dev_eui, GatewayName),
    c_text("Tracing dev_eui ~s in ~s", [GatewayName, FileName]);
trace_dev_eui(_, _, _) ->
    usage.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).
