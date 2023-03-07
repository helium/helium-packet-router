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
            "config ls             - List\n",
            "config oui <oui>      - Info for OUI\n",
            "    [--display_euis] default: false (EUIs not included)\n",
            "config skf <devaddr>  - List all Session Key Filters for Devaddr\n"
        ]
    ].

config_cmd() ->
    [
        [["config", "ls"], [], [], fun config_list/3],
        [
            ["config", "oui", '*'],
            [],
            [{display_euis, [{longname, "display_euis"}, {datatype, boolean}]}],
            fun config_oui_list/3
        ],
        [["config", "skf", '*'], [], [], fun config_skf/3]
    ].

config_list(["config", "ls"], [], []) ->
    Routes = lists:sort(
        fun(R1, R2) -> hpr_route:oui(R1) < hpr_route:oui(R2) end, hpr_route_ets:all_routes()
    ),
    %% | OUI | Net ID | Protocol     | Max Copies | Addr Range Cnt | EUI Cnt | Route ID                             |
    %% |-----+--------+--------------+------------+----------------+---------+--------------------------------------|
    %% |   1 | 000001 | gwmp         |         15 |              4 |       4 | b1eed652-b85c-11ed-8c9d-bfa0a604afc0 |
    %% |   4 | 000002 | http_roaming |        999 |              3 |       4 | 91236f72-a98a-11ed-aacb-830d346922b8 |
    MkRow = fun(Route) ->
        Server = hpr_route:server(Route),
        [
            {" OUI ", hpr_route:oui(Route)},
            {" Net ID ", hpr_utils:net_id_display(hpr_route:net_id(Route))},
            {" Protocol ", hpr_route:protocol_type(Server)},
            {" Max Copies ", hpr_route:max_copies(Route)},
            {" Addr Range Cnt ",
                erlang:length(hpr_route_ets:devaddr_ranges_for_route(hpr_route:id(Route)))},
            {" EUI Cnt ", erlang:length(hpr_route_ets:eui_pairs_for_route(hpr_route:id(Route)))},
            {" Route ID ", hpr_route:id(Route)}
        ]
    end,
    c_table(lists:map(MkRow, Routes));
config_list(_, _, _) ->
    usage.

config_oui_list(["config", "oui", OUIString], [], Flags) ->
    Options = maps:from_list(Flags),
    OUI = erlang:list_to_integer(OUIString),
    Routes = hpr_route_ets:oui_routes(OUI),

    %% OUI 4
    %% ========================================================
    %% - ID :: 48088786-5465-4115-92de-5214a88e9a75
    %% - Nonce :: 1
    %% - Net ID :: C00053 (124781673)
    %% - Max Copies :: 1337
    %% - Server :: Host:Port
    %% - Protocol :: {gwmp, ...}
    %% - DevAddr Ranges
    %% --- Start -> End
    %% --- Start -> End
    %% - EUI Count :: 2  (AppEUI, DevEUI)
    %% --- (010203040506070809, 010203040506070809)
    %% --- (0A0B0C0D0E0F0G0102, 0A0B0C0D0E0F0G0102)

    Header = io_lib:format("OUI ~p~n", [OUI]),
    Spacer = io_lib:format("========================================================~n", []),

    DevAddrHeader = io_lib:format("- DevAddr Ranges~n", []),

    FormatDevAddr = fun({S, E}) ->
        io_lib:format("  - ~s -> ~s~n", [hpr_utils:int_to_hex(S), hpr_utils:int_to_hex(E)])
    end,
    FormatEUI = fun({App, Dev}) ->
        io_lib:format("  - (~s, ~s)~n", [hpr_utils:int_to_hex(App), hpr_utils:int_to_hex(Dev)])
    end,

    MkRow = fun(Route) ->
        NetID = hpr_route:net_id(Route),
        Server = hpr_route:server(Route),

        DevAddrRanges = lists:map(
            FormatDevAddr, hpr_route_ets:devaddr_ranges_for_route(hpr_route:id(Route))
        ),
        DevAddrInfo = [DevAddrHeader | DevAddrRanges],

        EUIs = hpr_route_ets:eui_pairs_for_route(hpr_route:id(Route)),
        EUIHeader = io_lib:format("- EUI (AppEUI, DevEUI) :: ~p~n", [erlang:length(EUIs)]),
        EUIInfo =
            case maps:is_key(display_euis, Options) of
                false ->
                    [EUIHeader];
                true ->
                    [EUIHeader | lists:map(FormatEUI, EUIs)]
            end,

        Info = [
            io_lib:format("- ID         :: ~s~n", [hpr_route:id(Route)]),
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

config_skf(["config", "skf", DevAddrString], [], []) ->
    <<DevAddr:32/integer-unsigned-little>> = hpr_utils:hex_to_bin(
        erlang:list_to_binary(DevAddrString)
    ),
    case hpr_skf_ets:lookup_devaddr(DevAddr) of
        {error, _} ->
            c_text("No SKF found");
        {ok, SKFs} ->
            MkRow = fun(SKF) ->
                [
                    {" Session Key ", hpr_utils:bin_to_hex(SKF)},
                    {" DevAddr ", DevAddrString}
                ]
            end,
            c_table(lists:map(MkRow, SKFs))
    end;
config_skf(_, _, _) ->
    usage.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

-spec c_table(list(proplists:proplist()) | proplists:proplist()) -> clique_status:status().
c_table(PropLists) -> [clique_status:table(PropLists)].

-spec c_list(list(string())) -> clique_status:status().
c_list(L) -> [clique_status:list(L)].

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].
