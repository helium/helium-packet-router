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
            "info ips       - Export all connected hotspots IPs to /tmp/hotspot_ip.json\n"
            "info netids    - Export net ids stats as json to /tmp/net_ids.json\n"
        ]
    ].

info_cmd() ->
    [
        [["info", "key"], [], [], fun info_key/3],
        [["info", "ips"], [], [], fun info_ips/3],
        [["info", "netids"], [], [], fun info_netids/3]
    ].

info_key(["info", "key"], [], []) ->
    B58 = hpr_utils:b58(),
    c_text("KEY=~s", [B58]);
info_key(_, _, _) ->
    usage.

info_ips(["info", "ips"], [], []) ->
    List = lists:map(
        fun({_Pid, {IP, PubKeyBin}}) ->
            B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
            Name = hpr_utils:gateway_name(B58),
            #{
                key => binary:list_to_bin(B58),
                name => binary:list_to_bin(Name),
                ip => binary:list_to_bin(IP)
            }
        end,
        gproc:lookup_local_properties(hpr_packet_router_service:ip_key())
    ),
    Json = jsx:encode(List),
    case file:open("/tmp/hotspot_ip.json", [write]) of
        {ok, File} ->
            file:write(File, Json),
            file:close(File),
            c_text("Exported to /tmp/hotspot_ip.json");
        {error, Reason} ->
            c_text("Failed to export ~p", [Reason])
    end;
info_ips(_, _, _) ->
    usage.

info_netids(["info", "netids"], [], []) ->
    List = lists:map(
        fun({NetID, Count}) ->
            #{
                net_id => hpr_utils:net_id_display(NetID),
                count => Count
            }
        end,
        hpr_netid_stats:export()
    ),
    Json = jsx:encode(List),
    case file:open("/tmp/net_ids.json", [write]) of
        {ok, File} ->
            file:write(File, Json),
            file:close(File),
            c_text("Exported to /tmp/net_ids.json");
        {error, Reason} ->
            c_text("Failed to export ~p", [Reason])
    end;
info_netids(_, _, _) ->
    usage.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).
