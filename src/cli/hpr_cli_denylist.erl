%%%-------------------------------------------------------------------
%% @doc hpr_cli_denylist
%%
%% CLI to manage the ephemeral gateway denylist (see hpr_denylist).
%% @end
%%%-------------------------------------------------------------------
-module(hpr_cli_denylist).

-behavior(clique_handler).

-export([register_cli/0]).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(fun(Args) -> apply(clique, register_usage, Args) end, [denylist_usage()]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
                  [denylist_cmd()]).

%%--------------------------------------------------------------------
%% Denylist
%%--------------------------------------------------------------------

denylist_usage() ->
    [["denylist"],
     ["\n\n",
      "denylist ls                 - List denylisted gateways\n",
      "denylist add <gateway>      - Add a gateway (b58 address) to "
      "the denylist\n",
      "denylist remove <gateway>   - Remove a gateway (b58 address) "
      "from the denylist\n",
      "denylist reset              - Remove the entire denylist\n"]].

denylist_cmd() ->
    [[["denylist", "ls"], [], [], fun denylist_list/3],
     [["denylist", "add", '*'], [], [], fun denylist_add/3],
     [["denylist", "remove", '*'], [], [], fun denylist_remove/3],
     [["denylist", "reset"], [], [], fun denylist_reset/3]].

denylist_list(["denylist", "ls"], [], []) ->
    case hpr_denylist:list() of
        [] ->
            c_text("Denylist is empty");
        Gateways ->
            Rows =
                lists:map(fun(Gateway) ->
                             B58 = libp2p_crypto:bin_to_b58(Gateway),
                             [{" Gateway ", B58}, {" Name ", hpr_utils:gateway_name(B58)}]
                          end,
                          Gateways),
            c_table(Rows)
    end;
denylist_list(_, _, _) ->
    usage.

denylist_add(["denylist", "add", GatewayStr], [], []) ->
    case parse_gateway(GatewayStr) of
        {ok, Gateway} ->
            ok = hpr_denylist:add(Gateway),
            c_text("Added ~s to denylist", [GatewayStr]);
        error ->
            c_text("Invalid gateway address: ~s", [GatewayStr])
    end;
denylist_add(_, _, _) ->
    usage.

denylist_remove(["denylist", "remove", GatewayStr], [], []) ->
    case parse_gateway(GatewayStr) of
        {ok, Gateway} ->
            ok = hpr_denylist:remove(Gateway),
            c_text("Removed ~s from denylist", [GatewayStr]);
        error ->
            c_text("Invalid gateway address: ~s", [GatewayStr])
    end;
denylist_remove(_, _, _) ->
    usage.

denylist_reset(["denylist", "reset"], [], []) ->
    Count = hpr_denylist:count(),
    ok = hpr_denylist:reset(),
    c_text("Removed denylist (~p gateways)", [Count]);
denylist_reset(_, _, _) ->
    usage.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

-spec parse_gateway(string()) -> {ok, binary()} | error.
parse_gateway(GatewayStr) ->
    try
        {ok, libp2p_crypto:b58_to_bin(GatewayStr)}
    catch
        _E:_R ->
            error
    end.

-spec c_text(string()) -> clique_status:status().
c_text(T) ->
    [clique_status:text([T])].

-spec c_text(string(), [term()]) -> clique_status:status().
c_text(F, Args) ->
    c_text(io_lib:format(F, Args)).

-spec c_table([proplists:proplist()]) -> clique_status:status().
c_table(PropLists) ->
    [clique_status:table(PropLists)].
