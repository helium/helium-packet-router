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
            "config ls                                   - List\n",
            "config oui <oui>                            - Info for OUI\n",
            "    [--display_euis] default: false (EUIs not included)\n",
            "    [--display_skfs] default: false (SKFs not included)\n",
            "config route <route_id>                     - Info for route\n",
            "    [--display_euis] default: false (EUIs not included)\n",
            "    [--display_skfs] default: false (SKFs not included)\n",
            "config skf <DevAddr/Session Key>            - List all Session Key Filters for Devaddr or Session Key\n",
            "config eui --app <app_eui> --dev <dev_eui>  - List all Routes with EUI pair\n"
        ]
    ].

config_cmd() ->
    [
        [["config", "ls"], [], [], fun config_list/3],
        [
            ["config", "oui", '*'],
            [],
            [
                {display_euis, [{longname, "display_euis"}, {datatype, boolean}]},
                {display_skfs, [{longname, "display_skfs"}, {datatype, boolean}]}
            ],
            fun config_oui_list/3
        ],
        [
            ["config", "route", '*'],
            [],
            [
                {display_euis, [{longname, "display_euis"}, {datatype, boolean}]},
                {display_skfs, [{longname, "display_skfs"}, {datatype, boolean}]}
            ],
            fun config_route/3
        ],
        [["config", "skf", '*'], [], [], fun config_skf/3],
        [
            ["config", "eui"],
            [],
            [
                {app_eui, [
                    {shortname, "a"},
                    {longname, "app"}
                ]},
                {dev_eui, [
                    {shortname, "d"},
                    {longname, "dev"}
                ]}
            ],
            fun config_eui/3
        ]
    ].

config_list(["config", "ls"], [], []) ->
    Routes = lists:sort(
        fun(R1, R2) -> hpr_route:oui(R1) < hpr_route:oui(R2) end,
        hpr_route_ets:all_routes()
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
            {" Addr Ranges Cnt ",
                hpr_route_ets:devaddr_ranges_count_for_route(hpr_route:id(Route))},
            {" EUIs Cnt ", hpr_route_ets:eui_pairs_count_for_route(hpr_route:id(Route))},
            {" SKFs Cnt ", hpr_route_ets:skfs_count_for_route(hpr_route:id(Route))},
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
    %% - SKF (DevAddr, SKF, MaxCopies, Timestamp) :: 1
    %% --- (00000007, 91919193DA7B33923FFBE34078000010, 2, 1689030396950)

    Header = io_lib:format("OUI ~p~n", [OUI]),
    Spacer = io_lib:format("========================================================~n", []),

    DevAddrHeader = io_lib:format("- DevAddr Ranges~n", []),

    FormatDevAddr = fun({S, E}) ->
        io_lib:format("  - ~s -> ~s~n", [
            hpr_utils:int_to_hex_string(S), hpr_utils:int_to_hex_string(E)
        ])
    end,
    FormatEUI = fun({App, Dev}) ->
        io_lib:format("  - (~s, ~s)~n", [
            hpr_utils:int_to_hex_string(App), hpr_utils:int_to_hex_string(Dev)
        ])
    end,
    FormatSKF = fun({{Timestamp, SKF}, {DevAddr, MaxCopies}}) ->
        io_lib:format("  - (~s, ~s, ~w, ~w)~n", [
            hpr_utils:int_to_hex_string(DevAddr),
            hpr_utils:bin_to_hex_string(SKF),
            MaxCopies,
            Timestamp * -1
        ])
    end,

    MkRow = fun(Route) ->
        RouteID = hpr_route:id(Route),
        NetID = hpr_route:net_id(Route),
        Server = hpr_route:server(Route),

        DevAddrRanges = lists:map(
            FormatDevAddr, hpr_route_ets:devaddr_ranges_for_route(RouteID)
        ),
        DevAddrInfo = [DevAddrHeader | DevAddrRanges],

        EUIInfo =
            case maps:is_key(display_euis, Options) of
                false ->
                    Count = hpr_route_ets:eui_pairs_count_for_route(RouteID),
                    EUIHeader = io_lib:format("- EUI (AppEUI, DevEUI) :: ~p~n", [Count]),
                    [EUIHeader];
                true ->
                    EUIs = hpr_route_ets:eui_pairs_for_route(RouteID),
                    EUIHeader = io_lib:format("- EUI (AppEUI, DevEUI) :: ~p~n", [
                        erlang:length(EUIs)
                    ]),
                    [EUIHeader | lists:map(FormatEUI, EUIs)]
            end,

        SKFInfo =
            case maps:is_key(display_skfs, Options) of
                false ->
                    SKFsCount = hpr_route_ets:skfs_count_for_route(RouteID),
                    SKFHeader = io_lib:format(
                        "- SKF (DevAddr, SKF, MaxCopies, Timestamp) :: ~p~n", [SKFsCount]
                    ),
                    [SKFHeader];
                true ->
                    SKFs = hpr_route_ets:skfs_for_route(RouteID),
                    SKFHeader = io_lib:format(
                        "- SKF (DevAddr, SKF, MaxCopies, Timestamp) :: ~p~n", [
                            erlang:length(SKFs)
                        ]
                    ),
                    [SKFHeader | lists:map(FormatSKF, SKFs)]
            end,

        Info = [
            io_lib:format("- ID         :: ~s~n", [RouteID]),
            io_lib:format("- Net ID     :: ~s (~p)~n", [hpr_utils:net_id_display(NetID), NetID]),
            io_lib:format("- Max Copies :: ~p~n", [hpr_route:max_copies(Route)]),
            io_lib:format("- Server     :: ~s~n", [hpr_route:lns(Route)]),
            io_lib:format("- Protocol   :: ~p~n", [hpr_route:protocol(Server)])
        ],

        Info ++ DevAddrInfo ++ EUIInfo ++ SKFInfo
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

config_route(["config", "route", RouteID], [], Flags) ->
    Options = maps:from_list(Flags),
    Routes = hpr_route_ets:lookup_route(RouteID),

    %% ========================================================
    %% - ID :: 48088786-5465-4115-92de-5214a88e9a75
    %% - OUI :: 1
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
    %% - SKF (DevAddr, SKF, MaxCopies, Timestamp) :: 1
    %% --- (00000007, 91919193DA7B33923FFBE34078000010, 2, 1689030396950)

    Spacer = io_lib:format("========================================================~n", []),

    DevAddrHeader = io_lib:format("- DevAddr Ranges~n", []),

    FormatDevAddr = fun({S, E}) ->
        io_lib:format("  - ~s -> ~s~n", [
            hpr_utils:int_to_hex_string(S), hpr_utils:int_to_hex_string(E)
        ])
    end,
    FormatEUI = fun({App, Dev}) ->
        io_lib:format("  - (~s, ~s)~n", [
            hpr_utils:int_to_hex_string(App), hpr_utils:int_to_hex_string(Dev)
        ])
    end,
    FormatSKF = fun({{Timestamp, SKF}, {DevAddr, MaxCopies}}) ->
        io_lib:format("  - (~s, ~s, ~w, ~w)~n", [
            hpr_utils:int_to_hex_string(DevAddr),
            hpr_utils:bin_to_hex_string(SKF),
            MaxCopies,
            Timestamp * -1
        ])
    end,

    MkRow = fun(Route) ->
        RouteID = hpr_route:id(Route),
        NetID = hpr_route:net_id(Route),
        Server = hpr_route:server(Route),

        DevAddrRanges = lists:map(
            FormatDevAddr, hpr_route_ets:devaddr_ranges_for_route(RouteID)
        ),
        DevAddrInfo = [DevAddrHeader | DevAddrRanges],

        EUIInfo =
            case maps:is_key(display_euis, Options) of
                false ->
                    Count = hpr_route_ets:eui_pairs_count_for_route(RouteID),
                    EUIHeader = io_lib:format("- EUI (AppEUI, DevEUI) :: ~p~n", [Count]),
                    [EUIHeader];
                true ->
                    EUIs = hpr_route_ets:eui_pairs_for_route(RouteID),
                    EUIHeader = io_lib:format("- EUI (AppEUI, DevEUI) :: ~p~n", [
                        erlang:length(EUIs)
                    ]),
                    [EUIHeader | lists:map(FormatEUI, EUIs)]
            end,

        SKFInfo =
            case maps:is_key(display_skfs, Options) of
                false ->
                    SKFsCount = hpr_route_ets:skfs_count_for_route(RouteID),
                    SKFHeader = io_lib:format(
                        "- SKF (DevAddr, SKF, MaxCopies, Timestamp) :: ~p~n", [SKFsCount]
                    ),
                    [SKFHeader];
                true ->
                    SKFs = hpr_route_ets:skfs_for_route(RouteID),
                    SKFHeader = io_lib:format(
                        "- SKF (DevAddr, SKF, MaxCopies, Timestamp) :: ~p~n", [
                            erlang:length(SKFs)
                        ]
                    ),
                    [SKFHeader | lists:map(FormatSKF, SKFs)]
            end,

        Info = [
            io_lib:format("- ID         :: ~s~n", [RouteID]),
            io_lib:format("- OUI        :: ~w~n", [hpr_route:oui(Route)]),
            io_lib:format("- Net ID     :: ~s (~p)~n", [hpr_utils:net_id_display(NetID), NetID]),
            io_lib:format("- Max Copies :: ~p~n", [hpr_route:max_copies(Route)]),
            io_lib:format("- Server     :: ~s~n", [hpr_route:lns(Route)]),
            io_lib:format("- Protocol   :: ~p~n", [hpr_route:protocol(Server)])
        ],

        Info ++ DevAddrInfo ++ EUIInfo ++ SKFInfo
    end,

    c_list(
        lists:foldl(
            fun(Route, Lines) ->
                Lines ++ [Spacer | MkRow(Route)]
            end,
            [],
            Routes
        )
    );
config_route(_, _, _) ->
    usage.

config_skf(["config", "skf", DevAddrOrSKF], [], []) ->
    SKFS =
        case hpr_utils:hex_to_bin(erlang:list_to_binary(DevAddrOrSKF)) of
            <<DevAddr:32/integer-unsigned-little>> ->
                lists:foldl(
                    fun({Route, ETS}, Acc) ->
                        RouteID = hpr_route:id(Route),
                        [
                            {DevAddr, SK, RouteID, LastUsed * -1, MaxCopies}
                         || {SK, LastUsed, MaxCopies} <- hpr_route_ets:lookup_skf(ETS, DevAddr)
                        ] ++ Acc
                    end,
                    [],
                    hpr_route_ets:lookup_devaddr_range(DevAddr)
                );
            SKF ->
                Routes = hpr_route_ets:all_routes(),
                find_skf(SKF, Routes, [])
        end,
    case SKFS of
        [] ->
            c_text("No SKF found for ~p", [DevAddrOrSKF]);
        SKFs ->
            MkRow = fun({DevAddr, SK, RouteID, LastUsed, MaxCopies}) ->
                [
                    {" Route ID ", RouteID},
                    {" Session Key ", hpr_utils:bin_to_hex_string(SK)},
                    {" Last Used ", LastUsed},
                    {" Max Copies ", MaxCopies},
                    {" DevAddr ", hpr_utils:int_to_hex_string(DevAddr)}
                ]
            end,
            c_table(lists:map(MkRow, SKFs))
    end;
config_skf(_, _, _) ->
    usage.

find_skf(_SKToFind, [], Acc) ->
    Acc;
find_skf(SKToFind, [Route | Routes], Acc0) ->
    RouteID = hpr_route:id(Route),
    case hpr_route_ets:skfs_for_route(RouteID) of
        [] ->
            find_skf(SKToFind, Routes, Acc0);
        SKFs ->
            Acc1 = lists:filtermap(
                fun({{LastUsed, SK}, {DevAddr, MaxCopies}}) ->
                    case SK =:= SKToFind of
                        true ->
                            {true, {DevAddr, SK, RouteID, LastUsed * -1, MaxCopies}};
                        false ->
                            false
                    end
                end,
                SKFs
            ),
            find_skf(SKToFind, Routes, Acc0 ++ Acc1)
    end.

config_eui(["config", "eui"], [], Flags) ->
    case maps:from_list(Flags) of
        #{app_eui := AppEUI, dev_eui := DevEUI} -> do_config_eui(AppEUI, DevEUI);
        _ -> usage
    end;
config_eui(_, _, _) ->
    usage.

do_config_eui(AppEUI, DevEUI) ->
    AppEUINum = erlang:list_to_integer(AppEUI, 16),
    DevEUINum = erlang:list_to_integer(DevEUI, 16),

    Found = hpr_route_ets:lookup_eui_pair(AppEUINum, DevEUINum),

    %% ======================================================
    %% - App EUI :: 6081F9413229AD32 (6954113358046539058)
    %% - Dev EUI :: D52B4AD7C7D613C5 (15360453244708328389)
    %% - Routes  :: 1 (OUI, Route ID)
    %%   -- (60, "7c3071f8-b4ae-11ed-becd-7f254cab7af3")
    %%

    Spacer = [io_lib:format("========================================================~n", [])],
    Info = [
        io_lib:format("- App EUI :: ~p (~p)~n", [AppEUI, AppEUINum]),
        io_lib:format("- Dev EUI :: ~p (~p)~n", [DevEUI, DevEUINum]),
        io_lib:format("- Routes  :: ~p (OUI, Route ID)~n", [erlang:length(Found)])
    ],

    Routes = lists:map(
        fun(Route) ->
            io_lib:format("  -- (~p, ~p)~n", [hpr_route:oui(Route), hpr_route:id(Route)])
        end,
        Found
    ),

    c_list(Spacer ++ Info ++ Routes).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

-spec c_table(list(proplists:proplist()) | proplists:proplist()) -> clique_status:status().
c_table(PropLists) -> [clique_status:table(PropLists)].

-spec c_list(list(string())) -> clique_status:status().
c_list(L) -> [clique_status:list(L)].

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).
