%%%-------------------------------------------------------------------
%% @doc pp_cli_info
%% @end
%%%-------------------------------------------------------------------
-module(hpr_cli_info).

-behavior(clique_handler).

-include("hpr.hrl").

-export([register_cli/0]).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [info_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [info_cmd()]
    ).

%%--------------------------------------------------------------------
%% Config
%%--------------------------------------------------------------------

info_usage() ->
    [
        ["info"],
        [
            "\n\n",
            "info key       - Print HPR's Public Key\n"
        ]
    ].

info_cmd() ->
    [
        [["info", "key"], [], [], fun info_key/3]
    ].

info_key(["info", "key"], [], []) ->
    {PubKey, _SigFun} = persistent_term:get(?HPR_KEY),
    B58 = libp2p_crypto:pubkey_to_b58(PubKey),
    c_text("KEY=~s", [B58]);
info_key(_, _, _) ->
    usage.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).
