%%%-------------------------------------------------------------------
%% @doc pp_cli_config
%% @end
%%%-------------------------------------------------------------------
-module(hpr_cli_config).

-behavior(clique_handler).

-export([register_cli/0]).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [config_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [config_cmd()]
    ).

%%--------------------------------------------------------------------
%% Config
%%--------------------------------------------------------------------

config_usage() ->
    [
        ["config"],
        [
            "\n\n",
            "config ls        - list\n",
            "config oui <oui> - info for OUI\n"
        ]
    ].

config_cmd() ->
    [
        [["config", "ls"], [], [], fun config_list/3],
        [["config", "oui", '*'], [], [], fun config_oui_list/3]
    ].

config_list(["config", "ls"], [], []) ->
    Routes = hpr_config:all_routes(),

    %% | Net ID | OUI | Protocol     | Max Copies | Addr Range Cnt | EUI Cnt |
    %% |--------+-----+--------------+------------+----------------+---------|
    %% | 000001 |   1 | gwmp         |         15 |              4 |       4 |
    %% | 000002 |   4 | http_roaming |        999 |              3 |       4 |

    MkRow = fun(Route) ->
        Server = hpr_route:server(Route),
        [
            {" ID ", hpr_route:id(Route)},
            {" Nonce ", hpr_route:nonce(Route)},
            {" Net ID ", hpr_utils:net_id_display(hpr_route:net_id(Route))},
            {" OUI ", hpr_route:oui(Route)},
            {" Protocol ", hpr_route:protocol_type(Server)},
            {" Max Copies ", hpr_route:max_copies(Route)},
            {" Addr Range Cnt ", erlang:length(hpr_route:devaddr_ranges(Route))},
            {" EUI Cnt ", erlang:length(hpr_route:euis(Route))}
        ]
    end,
    c_table(lists:map(MkRow, Routes));
config_list(_, _, _) ->
    usage.

config_oui_list(["config", "oui", OUIString], [], []) ->
    OUI = erlang:list_to_integer(OUIString),
    Routes = hpr_config:oui_routes(OUI),

    %% OUI 4
    %% ========================================================
    %% - Net ID :: C00053 (124781673)
    %% - Max Copies :: 1337
    %% - Server :: Host:Port
    %% - Protocol :: {gwmp, ...}
    %% - DevAddr Ranges
    %% --- Start -> End
    %% --- Start -> End
    %% - EUI Cnt (AppEUI, DevEUI)
    %% --- (010203040506070809, 010203040506070809)
    %% --- (0A0B0C0D0E0F0G0102, 0A0B0C0D0E0F0G0102)

    Header = io_lib:format("OUI ~p~n", [OUI]),
    Spacer = io_lib:format("========================================================~n", []),

    DevAddrHeader = io_lib:format("- DevAddr Ranges~n", []),
    EUIHeader = io_lib:format("- EUI (AppEUI, DevEUI)~n", []),

    FormatDevAddr = fun({S, E}) ->
        io_lib:format("  - ~s -> ~s~n", [hpr_utils:int_to_hex(S), hpr_utils:int_to_hex(E)])
    end,
    FormatEUI = fun({App, Dev}) ->
        io_lib:format("  - (~s, ~s)~n", [hpr_utils:int_to_hex(App), hpr_utils:int_to_hex(Dev)])
    end,

    MkRow = fun(Route) ->
        NetID = hpr_route:net_id(Route),
        Server = hpr_route:server(Route),

        DevAddrRanges = lists:map(FormatDevAddr, hpr_route:devaddr_ranges(Route)),
        DevAddrInfo = [DevAddrHeader | DevAddrRanges],

        EUIs = lists:map(FormatEUI, hpr_route:euis(Route)),
        EUIInfo = [EUIHeader | EUIs],

        Info = [
            io_lib:format("- Net ID     :: ~s (~p)~n", [hpr_utils:net_id_display(NetID), NetID]),
            io_lib:format("- Max Copies :: ~p~n", [hpr_route:max_copies(Route)]),
            io_lib:format("- Server     :: ~s~n", [hpr_route:lns(Route)]),
            io_lib:format("- Protocol   :: ~p~n", [hpr_route:protocol(Server)])
        ],

        Info ++ DevAddrInfo ++ EUIInfo
    end,

    c_list(
        lists:foldl(
            fun(Route, Lines) ->
                Lines ++ [Spacer | MkRow(Route)]
            end,
            [Header],
            Routes
        )
    );
config_oui_list(_, _, _) ->
    usage.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

-spec c_table(list(proplists:proplist()) | proplists:proplist()) -> clique_status:status().
c_table(PropLists) -> [clique_status:table(PropLists)].

-spec c_list(list(string())) -> clique_status:status().
c_list(L) -> [clique_status:list(L)].
