%%%-------------------------------------------------------------------
%% @doc pp_cli_config
%% @end
%%%-------------------------------------------------------------------
-module(hpr_cli_config).

-behavior(clique_handler).

-include("hpr.hrl").

-export([register_cli/0]).

-export([
    get_api_routes/0,
    get_api_routes_for_oui/1
]).

-ifdef(TEST).

-export([
    config_route_sync/3
]).

-endif.

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
            "config route refresh_all                    - Refresh all routes\n",
            "    [--minimum] default: 1 (need a minimum of 1 SKFs ro be updated)\n",
            "config route refresh_broken                 - Refresh broken routes\n",
            "config route refresh <route_id>             - Refresh route's EUIs, SKFs, DevAddrRanges\n",
            "config route activate <route_id>            - Activate route\n",
            "config route deactivate <route_id>          - Deactivate route\n",
            "config route remove <route_id>              - Delete all remnants of a route\n",
            "config route sync [--oui=<oui>]             - Fetch all Routes from Config Service, creating new, removing old\n"
            "config skf <DevAddr/Session Key>            - List all Session Key Filters for Devaddr or Session Key\n",
            "config eui --app <app_eui> --dev <dev_eui>  - List all Routes with EUI pair\n"
            "\n\n",
            "config counts                       - Simple Counts of Configuration\n",
            "config checkpoint next              - Time until next writing of configuration to disk\n"
            "config checkpoint write             - Write current configuration to disk\n",
            "config reset checkpoint [--commit]  - Set checkpoint timestamp to beginning of time (0)\n",
            "config reset stream [--commit]      - Reset stream to Configuration Service\n",
            "config reset channel [--commit]     - Reset channel to Configuration Service\n"
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
        [
            ["config", "route", "refresh_all"],
            [],
            [
                {minimum, [{longname, "minimum"}, {datatype, integer}]}
            ],
            fun config_route_refresh_all/3
        ],
        [
            ["config", "route", "refresh_broken"],
            [],
            [],
            fun config_route_refresh_broken/3
        ],
        [
            ["config", "route", "refresh", '*'],
            [],
            [],
            fun config_route_refresh/3
        ],
        [
            ["config", "route", "activate", '*'],
            [],
            [],
            fun config_route_activate/3
        ],
        [
            ["config", "route", "deactivate", '*'],
            [],
            [],
            fun config_route_deactivate/3
        ],
        [
            ["config", "route", "remove", '*'],
            [],
            [],
            fun config_route_remove/3
        ],
        [
            ["config", "route", "sync"],
            [],
            [{oui, [{shortname, "o"}, {longname, "oui"}]}],
            fun config_route_sync/3
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
        ],
        [["config", "counts"], [], [], fun config_counts/3],
        [["config", "checkpoint", "next"], [], [], fun config_checkpoint_next/3],
        [["config", "checkpoint", "write"], [], [], fun config_checkpoint_write/3],
        [
            ["config", "reset", "checkpoint"],
            [],
            [{commit, [{longname, "commit"}, {datatype, boolean}]}],
            fun config_reset/3
        ],
        [
            ["config", "reset", "stream"],
            [],
            [{commit, [{longname, "commit"}, {datatype, boolean}]}],
            fun config_reset/3
        ],
        [
            ["config", "reset", "channel"],
            [],
            [{commit, [{longname, "commit"}, {datatype, boolean}]}],
            fun config_reset/3
        ]
    ].

config_list(["config", "ls"], [], []) ->
    Routes = lists:sort(
        fun(R1, R2) -> hpr_route:oui(R1) < hpr_route:oui(R2) end,
        hpr_route_storage:all_routes()
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
            {" Addr Ranges Cnt ", hpr_devaddr_range_storage:count_for_route(hpr_route:id(Route))},
            {" EUIs Cnt ", hpr_eui_pair_storage:count_for_route(hpr_route:id(Route))},
            {" SKFs Cnt ", hpr_skf_storage:count_route(hpr_route:id(Route))},
            {" Route ID ", hpr_route:id(Route)}
        ]
    end,
    c_table(lists:map(MkRow, Routes));
config_list(_, _, _) ->
    usage.

config_oui_list(["config", "oui", OUIString], [], Flags) ->
    Options = maps:from_list(Flags),
    OUI = erlang:list_to_integer(OUIString),
    RoutesETS = hpr_route_storage:oui_routes_ets(OUI),

    %% OUI 4
    %% ========================================================
    %% - ID         :: 48088786-5465-4115-92de-5214a88e9a75
    %% - Nonce      :: 1
    %% - Net ID     :: C00053 (124781673)
    %% - Max Copies :: 1337
    %% - Server     :: Host:Port
    %% - Protocol   :: {gwmp, ...}
    %% - Backoff    :: 0
    %% - Active     :: true
    %% - Locked     :: false
    %% - Ignore Empty SKF :: true
    %% - DevAddr Ranges
    %% --- Start -> End
    %% --- Start -> End
    %% - EUI Count (AppEUI, DevEUI) :: 2
    %% --- (010203040506070809, 010203040506070809)
    %% --- (0A0B0C0D0E0F0G0102, 0A0B0C0D0E0F0G0102)
    %% - SKF (DevAddr, SKF, MaxCopies) :: 1
    %% --- (00000007, 91919193DA7B33923FFBE34078000010, 2, 1689030396950)

    Header = io_lib:format("OUI ~p~n", [OUI]),
    Spacer = io_lib:format("========================================================~n", []),

    DisplayOptions = #{
        display_euis => maps:is_key(display_euis, Options),
        display_skfs => maps:is_key(display_skfs, Options)
    },

    c_list(
        lists:foldl(
            fun(RouteETS, Lines) ->
                Lines ++ [Spacer | mk_route_info(RouteETS, DisplayOptions)]
            end,
            [Header],
            RoutesETS
        )
    );
config_oui_list(_, _, _) ->
    usage.

config_route(["config", "route", RouteID], [], Flags) ->
    Options = maps:from_list(Flags),
    {ok, RouteETS} = hpr_route_storage:lookup(RouteID),

    %% ========================================================
    %% - ID         :: 48088786-5465-4115-92de-5214a88e9a75
    %% - Nonce      :: 1
    %% - Net ID     :: C00053 (124781673)
    %% - Max Copies :: 1337
    %% - Server     :: Host:Port
    %% - Protocol   :: {gwmp, ...}
    %% - Backoff    :: 0
    %% - Active     :: true
    %% - Locked     :: false
    %% - Ignore Empty SKF :: true
    %% - DevAddr Ranges
    %% --- Start -> End
    %% --- Start -> End
    %% - EUI Count (AppEUI, DevEUI) :: 2
    %% --- (010203040506070809, 010203040506070809)
    %% --- (0A0B0C0D0E0F0G0102, 0A0B0C0D0E0F0G0102)
    %% - SKF (DevAddr, SKF, MaxCopies, Timestamp) :: 1
    %% --- (00000007, 91919193DA7B33923FFBE34078000010, 2, 1689030396950)

    Spacer = io_lib:format("========================================================~n", []),

    DisplayOptions = #{
        display_euis => maps:is_key(display_euis, Options),
        display_skfs => maps:is_key(display_skfs, Options)
    },

    c_list([Spacer | mk_route_info(RouteETS, DisplayOptions)]);
config_route(_, _, _) ->
    usage.

config_route_refresh_all(["config", "route", "refresh_all"], [], Flags) ->
    Options = maps:from_list(Flags),
    Min = maps:get(minimum, Options, 1),
    Pid = erlang:spawn(fun() ->
        List = lists:filtermap(
            fun(RouteETS) ->
                RouteID = hpr_route:id(hpr_route_ets:route(RouteETS)),
                SKFETS = hpr_route_ets:skf_ets(RouteETS),
                Size = ets:info(SKFETS, size),
                case Size >= Min of
                    true -> {true, {RouteID, Size}};
                    false -> false
                end
            end,
            hpr_route_storage:all_route_ets()
        ),
        Sorted = lists:sort(fun({_, A}, {_, B}) -> A > B end, List),
        RouteIDs = [ID || {ID, _} <- Sorted],
        Total = erlang:length(RouteIDs),
        lager:info("Found ~p routes to update", [Total]),
        routes_refresh(Total, RouteIDs)
    end),
    c_text(
        "command spawned @ ~p, look at logs and `tail -F /opt/hpr/log/info.log | grep hpr_cli_config`",
        [Pid]
    );
config_route_refresh_all(_, _, _) ->
    usage.

config_route_refresh_broken(["config", "route", "refresh_broken"], [], _Flags) ->
    Pid = erlang:spawn(fun() ->
        RouteIDsWithDevAddr =
            hpr_devaddr_range_storage:foldl(
                fun({_, RouteID}, Acc) ->
                    sets:add_element(RouteID, Acc)
                end,
                sets:new()
            ),
        RouteIDs = hpr_route_storage:foldl(
            fun(RouteETS, RouteIDs) ->
                SKFCount =
                    case ets:info(hpr_route_ets:skf_ets(RouteETS), size) of
                        undefined -> 0;
                        N -> N
                    end,
                Route = hpr_route_ets:route(RouteETS),
                RouteID = hpr_route:id(Route),
                case SKFCount > 0 andalso not sets:is_element(RouteID, RouteIDsWithDevAddr) of
                    true ->
                        lager:warning(
                            [{route_id, RouteID}, {oui, hpr_route:oui(Route)}],
                            "BROKEN_ROUTES route has no devaddr ranges but has (~p) skfs",
                            [SKFCount]
                        ),
                        [RouteID | RouteIDs];
                    false ->
                        RouteIDs
                end
            end,
            []
        ),
        Total = erlang:length(RouteIDs),
        lager:info("Found ~p routes to fix", [Total]),
        routes_refresh(Total, RouteIDs)
    end),
    c_text(
        "command spawned @ ~p, look at logs and `tail -F /opt/hpr/log/info.log | grep hpr_cli_config`",
        [Pid]
    );
config_route_refresh_broken(_, _, _) ->
    usage.

routes_refresh(_Total, []) ->
    lager:info("All done!");
routes_refresh(Total, [RouteID | RouteIDs]) ->
    CurrTotal = erlang:length(RouteIDs),
    IDX = Total - CurrTotal + 1,
    lager:info("~p/~p===== ~s =====", [
        IDX, Total, RouteID
    ]),
    Start = erlang:system_time(millisecond),
    try hpr_route_stream_worker:refresh_route(RouteID, 3) of
        {ok, Map} ->
            lager:info("| Type | Before  |  After  | Removed |  Added  |"),
            lager:info("|------|---------|---------|---------|---------|"),
            lager:info("| ~4w | ~7w | ~7w | ~7w | ~7w |", [
                addr,
                maps:get(devaddr_before, Map),
                maps:get(devaddr_after, Map),
                maps:get(devaddr_removed, Map),
                maps:get(devaddr_added, Map)
            ]),
            lager:info("| ~4w | ~7w | ~7w | ~7w | ~7w |", [
                eui,
                maps:get(eui_before, Map),
                maps:get(eui_after, Map),
                maps:get(eui_removed, Map),
                maps:get(eui_added, Map)
            ]),
            lager:info("| ~4w | ~7w | ~7w | ~7w | ~7w |", [
                skf,
                maps:get(skf_before, Map),
                maps:get(skf_after, Map),
                maps:get(skf_removed, Map),
                maps:get(skf_added, Map)
            ]);
        {error, _R} ->
            lager:error("error ~p", [_R])
    catch
        _E:_R ->
            lager:critical("crashed ~p", [_R])
    end,
    End = erlang:system_time(millisecond),
    lager:info("took ~pms", [End - Start]),
    routes_refresh(Total, RouteIDs).

config_route_refresh(["config", "route", "refresh", RouteID], [], _Flags) ->
    case hpr_route_stream_worker:refresh_route(RouteID, 3) of
        {ok, RefreshMap} ->
            Table = [
                [
                    {" Type ", eui},
                    {" Before ", maps:get(eui_before, RefreshMap)},
                    {" After ", maps:get(eui_after, RefreshMap)},
                    {" Removed ", maps:get(eui_removed, RefreshMap)},
                    {" Added ", maps:get(eui_added, RefreshMap)}
                ],
                [
                    {" Type ", skf},
                    {" Before ", maps:get(skf_before, RefreshMap)},
                    {" After ", maps:get(skf_after, RefreshMap)},
                    {" Removed ", maps:get(skf_removed, RefreshMap)},
                    {" Added ", maps:get(skf_added, RefreshMap)}
                ],
                [
                    {" Type ", devaddr_range},
                    {" Before ", maps:get(devaddr_before, RefreshMap)},
                    {" After ", maps:get(devaddr_after, RefreshMap)},
                    {" Removed ", maps:get(devaddr_removed, RefreshMap)},
                    {" Added ", maps:get(devaddr_added, RefreshMap)}
                ]
            ],
            c_table(Table);
        Err ->
            c_text("Something went wrong:~n~p", [Err])
    end;
config_route_refresh(_, _, _) ->
    usage.

config_route_activate(["config", "route", "activate", RouteID], [], _Flags) ->
    case hpr_route_storage:lookup(RouteID) of
        {error, not_found} ->
            c_text("Route ~s not found", [RouteID]);
        {ok, RouteETS} ->
            Route0 = hpr_route_ets:route(RouteETS),
            Route1 = hpr_route:active(true, Route0),
            ok = hpr_route_storage:insert(Route1),
            c_text("Route ~s activated", [RouteID])
    end;
config_route_activate(_, _, _) ->
    usage.

config_route_deactivate(["config", "route", "deactivate", RouteID], [], _Flags) ->
    case hpr_route_storage:lookup(RouteID) of
        {error, not_found} ->
            c_text("Route ~s not found", [RouteID]);
        {ok, RouteETS} ->
            Route0 = hpr_route_ets:route(RouteETS),
            Route1 = hpr_route:active(false, Route0),
            ok = hpr_route_storage:insert(Route1),
            c_text("Route ~s deactivated", [RouteID])
    end;
config_route_deactivate(_, _, _) ->
    usage.

config_route_remove(["config", "route", "remove", RouteID], [], []) ->
    case hpr_route_storage:lookup(RouteID) of
        {ok, RouteETS} ->
            Route = hpr_route_ets:route(RouteETS),
            hpr_route_storage:delete(Route),
            c_text("Deleted Route: ~p", [RouteID]);
        {error, not_found} ->
            c_text("Could not find ~p", [RouteID])
    end;
config_route_remove(_, _, _) ->
    usage.

config_route_sync(["config", "route", "sync"], [], Flags) ->
    Updates =
        case maps:from_list(Flags) of
            #{oui := OUI0} ->
                OUI = erlang:list_to_integer(OUI0, 10),
                APIRoutes = get_api_routes_for_oui(OUI),
                ExistingRoutes = hpr_route_storage:oui_routes(OUI),
                sync_routes(APIRoutes, ExistingRoutes);
            #{} ->
                APIRoutes = get_api_routes(),
                ExistingRoutes = hpr_route_storage:all_routes(),
                sync_routes(APIRoutes, ExistingRoutes)
        end,

    FormatRoute = fun(Route) ->
        io_lib:format(" - ~s OUI=~p~n", [hpr_route:id(Route), hpr_route:oui(Route)])
    end,
    Added = lists:map(FormatRoute, maps:get(added, Updates, [])),
    Removed = lists:map(FormatRoute, maps:get(removed, Updates, [])),

    c_list(
        [io_lib:format("=== Added (~p) ===~n", [length(Added)])] ++ Added ++
            [io_lib:format("=== Removed (~p) ===~n", [length(Removed)])] ++ Removed
    );
config_route_sync(_, _, _) ->
    usage.

config_skf(["config", "skf", DevAddrOrSKF], [], []) ->
    SKFS =
        case hpr_utils:hex_to_bin(erlang:list_to_binary(DevAddrOrSKF)) of
            <<DevAddr:32/integer-unsigned-little>> ->
                lists:foldl(
                    fun(RouteETS, Acc) ->
                        Route = hpr_route_ets:route(RouteETS),
                        RouteID = hpr_route:id(Route),
                        ETS = hpr_route_ets:skf_ets(RouteETS),
                        [
                            {DevAddr, SK, RouteID, MaxCopies}
                         || {SK, MaxCopies} <- hpr_skf_storage:lookup(ETS, DevAddr)
                        ] ++ Acc
                    end,
                    [],
                    hpr_devaddr_range_storage:lookup(DevAddr)
                );
            SKF ->
                RoutesETS = hpr_route_storage:all_route_ets(),
                find_skf(SKF, RoutesETS, [])
        end,
    case SKFS of
        [] ->
            c_text("No SKF found for ~p", [DevAddrOrSKF]);
        SKFs ->
            MkRow = fun({DevAddr, SK, RouteID, MaxCopies}) ->
                [
                    {" Route ID ", RouteID},
                    {" Session Key ", hpr_utils:bin_to_hex_string(SK)},
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
find_skf(SKToFind, [RouteETS | RoutesETS], Acc0) ->
    Route = hpr_route_ets:route(RouteETS),
    RouteID = hpr_route:id(Route),
    case hpr_skf_storage:lookup_route(RouteID) of
        [] ->
            find_skf(SKToFind, RoutesETS, Acc0);
        SKFs ->
            Acc1 = lists:filtermap(
                fun({{SK, DevAddr}, MaxCopies}) ->
                    case SK =:= SKToFind of
                        true ->
                            {true, {DevAddr, SK, RouteID, MaxCopies}};
                        false ->
                            false
                    end
                end,
                SKFs
            ),
            find_skf(SKToFind, RoutesETS, Acc0 ++ Acc1)
    end.

config_eui(["config", "eui"], [], Flags) ->
    case maps:from_list(Flags) of
        #{app_eui := AppEUI, dev_eui := DevEUI} -> do_config_eui(AppEUI, DevEUI);
        #{app_eui := AppEUI} -> do_single_eui(app_eui, AppEUI);
        #{dev_eui := DevEUI} -> do_single_eui(dev_eui, DevEUI);
        _ -> usage
    end;
config_eui(_, _, _) ->
    usage.

do_config_eui(AppEUI, DevEUI) ->
    AppEUINum = erlang:list_to_integer(AppEUI, 16),
    DevEUINum = erlang:list_to_integer(DevEUI, 16),

    Found = hpr_eui_pair_storage:lookup(AppEUINum, DevEUINum),

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
        fun(RouteETS) ->
            Route = hpr_route_ets:route(RouteETS),
            io_lib:format("  -- (~p, ~p)~n", [hpr_route:oui(Route), hpr_route:id(Route)])
        end,
        Found
    ),

    c_list(Spacer ++ Info ++ Routes).

do_single_eui(app_eui, AppEUI) ->
    EUINum = erlang:list_to_integer(AppEUI, 16),
    Found = lists:foldl(
        fun({App, Dev, RouteID}, Acc) ->
            EUIs = maps:get(RouteID, Acc, []),
            maps:put(RouteID, [{App, Dev} | EUIs], Acc)
        end,
        #{},
        hpr_eui_pair_storage:lookup_app_eui(EUINum)
    ),

    %% ======================================================
    %% - App EUI  :: 6081F9413229AD32 (6954113358046539058) found in X Routes
    %% - Route ID :: 817aaade-562a-99aa-8757-235e5f2e148e
    %% - Count    :: 1 (AppEUI, DevEUI)
    %%   -- (6081F9413229AD32, 0102030405060708)
    %%
    Spacer = [
        io_lib:format("========================================================~n", []),
        io_lib:format("- App EUI  :: ~s (~p) found in ~p Routes ~n", [
            AppEUI, EUINum, maps:size(Found)
        ])
    ],
    Info =
        maps:fold(
            fun(RouteID, EUIs, Acc) ->
                Acc ++
                    [
                        io_lib:format("- Route ID :: ~p~n", [RouteID]),
                        io_lib:format("- Count    :: ~p (AppEUI, DevEUI)~n", [erlang:length(EUIs)])
                    ] ++
                    lists:map(fun format_eui/1, EUIs)
            end,
            [],
            Found
        ),
    c_list(Spacer ++ Info);
do_single_eui(dev_eui, DevEUI) ->
    EUINum = erlang:list_to_integer(DevEUI, 16),
    Found = lists:foldl(
        fun({App, Dev, RouteID}, Acc) ->
            EUIs = maps:get(RouteID, Acc, []),
            maps:put(RouteID, [{App, Dev} | EUIs], Acc)
        end,
        #{},
        hpr_eui_pair_storage:lookup_dev_eui(EUINum)
    ),

    %% ======================================================
    %% - Dev EUI :: 6081F9413229AD32 (6954113358046539058) found in X Routes
    %% - Route ID :: 817aaade-562a-99aa-8757-235e5f2e148e
    %% - Count    :: 1 (AppEUI, DevEUI)
    %%   -- (6081F9413229AD32, 0102030405060708)
    %%

    Spacer = [
        io_lib:format("========================================================~n", []),
        io_lib:format("- App EUI  :: ~s (~p) found in ~p Routes ~n", [
            DevEUI, EUINum, maps:size(Found)
        ])
    ],
    Info =
        maps:fold(
            fun(RouteID, EUIs, Acc) ->
                Acc ++
                    [
                        io_lib:format("- Route ID :: ~p~n", [RouteID]),
                        io_lib:format("- Count    :: ~p (AppEUI, DevEUI)~n", [erlang:length(EUIs)])
                    ] ++
                    lists:map(fun format_eui/1, EUIs)
            end,
            [],
            Found
        ),
    c_list(Spacer ++ Info).

config_counts(["config", "counts"], [], []) ->
    Counts = hpr_metrics:counts(),
    c_table([
        [
            {" Routes ", proplists:get_value(routes, Counts)},
            {" EUI Pairs ", proplists:get_value(eui_pairs, Counts)},
            {" SKF ", proplists:get_value(skfs, Counts)},
            {" DevAddr Ranges ", proplists:get_value(devaddr_ranges, Counts)}
        ]
    ]);
config_counts(_, _, _) ->
    usage.

config_checkpoint_next(["config", "checkpoint", "next"], [], []) ->
    Msg = hpr_route_stream_worker:print_next_checkpoint(),
    c_text(Msg);
config_checkpoint_next(_, _, _) ->
    usage.

config_checkpoint_write(["config", "checkpoint", "write"], [], []) ->
    case timer:tc(fun() -> hpr_route_stream_worker:do_checkpoint(erlang:system_time(second)) end) of
        {Time0, ok} ->
            Time = erlang:convert_time_unit(Time0, microsecond, millisecond),
            c_text("Wrote checkpoint in ~wms", [Time]);
        Other ->
            c_text("Something went wrong: ~p", [Other])
    end;
config_checkpoint_write(_, _, _) ->
    usage.

config_reset(["config", "reset", ResetType], [], Flags) ->
    Options = maps:from_list(Flags),
    case maps:is_key(commit, Options) of
        true ->
            case ResetType of
                "checkpoint" ->
                    ok = hpr_route_stream_worker:reset_timestamp(),
                    c_text("Checkpoint reset");
                "channel" ->
                    ok = hpr_route_stream_worker:reset_channel(),
                    c_text("New Channel");
                "stream" ->
                    ok = hpr_route_stream_worker:reset_stream(),
                    c_text("New Stream");
                _ ->
                    c_text("cannot reset ~s", [ResetType])
            end;
        false ->
            c_text("Must specify --commit to reset ~s", [ResetType])
    end;
config_reset(_, _, _) ->
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

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).

-spec mk_route_info(hpr_route_ets:route(), DisplayOptions :: map()) -> list(string()).
mk_route_info(RouteETS, #{display_euis := DisplayEUIs, display_skfs := DisplaySKFs}) ->
    Route = hpr_route_ets:route(RouteETS),
    RouteID = hpr_route:id(Route),

    DevAddrHeader = io_lib:format("- DevAddr Ranges~n", []),
    DevAddrRanges = lists:map(
        fun format_devaddr/1, hpr_devaddr_range_storage:lookup_for_route(RouteID)
    ),
    DevAddrInfo = [DevAddrHeader | DevAddrRanges],

    EUIInfo =
        case DisplayEUIs of
            false ->
                Count = hpr_eui_pair_storage:count_for_route(RouteID),
                EUIHeader = io_lib:format("- EUI (AppEUI, DevEUI) :: ~p~n", [Count]),
                [EUIHeader];
            true ->
                EUIs = hpr_eui_pair_storage:lookup_for_route(RouteID),
                EUIHeader = io_lib:format("- EUI (AppEUI, DevEUI) :: ~p~n", [
                    erlang:length(EUIs)
                ]),
                [EUIHeader | lists:map(fun format_eui/1, EUIs)]
        end,

    SKFInfo =
        case DisplaySKFs of
            false ->
                SKFsCount = hpr_skf_storage:count_route(RouteID),
                SKFHeader = io_lib:format(
                    "- SKF (DevAddr, SKF, MaxCopies) :: ~p~n", [SKFsCount]
                ),
                [SKFHeader];
            true ->
                SKFs = hpr_skf_storage:lookup_route(RouteID),
                SKFHeader = io_lib:format(
                    "- SKF (DevAddr, SKF, MaxCopies) :: ~p~n", [
                        erlang:length(SKFs)
                    ]
                ),
                [SKFHeader | lists:map(fun format_skf/1, SKFs)]
        end,

    mk_top_level_route_info(RouteETS) ++ DevAddrInfo ++ EUIInfo ++ SKFInfo.

-spec mk_top_level_route_info(hpr_route_ets:route()) -> list(string()).
mk_top_level_route_info(RouteETS) ->
    Route = hpr_route_ets:route(RouteETS),
    RouteID = hpr_route:id(Route),
    NetID = hpr_route:net_id(Route),
    Server = hpr_route:server(Route),
    Backoff =
        case hpr_route_ets:backoff(RouteETS) of
            undefined -> 0;
            {Timestamp, _} -> Timestamp
        end,
    [
        io_lib:format("- ID         :: ~s~n", [RouteID]),
        io_lib:format("- Net ID     :: ~s (~p)~n", [hpr_utils:net_id_display(NetID), NetID]),
        io_lib:format("- Max Copies :: ~p~n", [hpr_route:max_copies(Route)]),
        io_lib:format("- Server     :: ~s~n", [hpr_route:lns(Route)]),
        io_lib:format("- Protocol   :: ~p~n", [hpr_route:protocol(Server)]),
        io_lib:format("- Backoff    :: ~w~n", [Backoff]),
        io_lib:format("- Active     :: ~w~n", [hpr_route:active(Route)]),
        io_lib:format("- Locked     :: ~w~n", [hpr_route:locked(Route)]),
        io_lib:format("- Ignore Empty SKF :: ~w~n", [hpr_route:ignore_empty_skf(Route)])
    ].

format_devaddr({S, E}) ->
    io_lib:format("  - ~s -> ~s~n", [
        hpr_utils:int_to_hex_string(S), hpr_utils:int_to_hex_string(E)
    ]).

format_eui({App, Dev}) ->
    io_lib:format("  - (~s, ~s)~n", [
        hpr_utils:int_to_hex_string(App), hpr_utils:int_to_hex_string(Dev)
    ]).

format_skf({{SKF, DevAddr}, MaxCopies}) ->
    io_lib:format("  - (~s, ~s, ~w)~n", [
        hpr_utils:int_to_hex_string(DevAddr),
        hpr_utils:bin_to_hex_string(SKF),
        MaxCopies
    ]).

-spec get_api_routes() -> list(hpr_route:route()).
get_api_routes() ->
    {ok, OrgList, _Meta} = helium_iot_config_org_client:list(
        hpr_org_list_req:new(),
        #{channel => ?IOT_CONFIG_CHANNEL}
    ),

    lists:flatmap(
        fun(OUI) -> get_api_routes_for_oui(OUI) end,
        hpr_org_list_res:org_ouis(OrgList)
    ).

-spec get_api_routes_for_oui(OUI :: non_neg_integer()) -> list(hpr_route:route()).
get_api_routes_for_oui(OUI) ->
    PubKeyBin = hpr_utils:pubkey_bin(),
    SigFun = hpr_utils:sig_fun(),

    ListReq = hpr_route_list_req:new(PubKeyBin, OUI),
    SignedReq = hpr_route_list_req:sign(ListReq, SigFun),
    {ok, RouteListRes, _Meta} = helium_iot_config_route_client:list(
        SignedReq,
        #{channel => ?IOT_CONFIG_CHANNEL}
    ),
    hpr_route_list_res:routes(RouteListRes).

-spec sync_routes(
    APIRoutes :: list(hpr_route:route()),
    ExistingRoutes :: list(hpr_route:route())
) -> #{added => list(hpr_route:route()), removed => list(hpr_route:route())}.
sync_routes(APIRoutes, ExistingRoutes) ->
    sync_routes(APIRoutes, ExistingRoutes, #{added => [], removed => []}).

-spec sync_routes(
    APIRoutes :: list(hpr_route:route()),
    ExistingRoutes :: list(hpr_route:route()),
    Updates :: map()
) -> #{added => list(hpr_route:route()), removed => list(hpr_route:route())}.
sync_routes([], [], Updates) ->
    Updates;
sync_routes([], [Route | LeftoverRoutes], #{removed := RemovedRoutes} = Updates) ->
    RouteID = hpr_route:id(Route),
    lager:info([{route_id, RouteID}], "removing leftover route: ~p"),
    ok = hpr_route_storage:delete(Route),
    sync_routes(
        [],
        LeftoverRoutes,
        Updates#{removed => [Route | RemovedRoutes]}
    );
sync_routes([Route | Routes], ExistingRoutes, #{added := AddedRoutes} = Updates) ->
    RouteID = hpr_route:id(Route),
    case hpr_route_storage:lookup(RouteID) of
        {ok, _RouteETS} ->
            lager:info([{route_id, RouteID}], "doing nothing, route already exists"),
            sync_routes(
                Routes,
                remove_route(Route, ExistingRoutes),
                Updates
            );
        {error, not_found} ->
            lager:info([{route_id, RouteID}], "syncing new route"),
            ok = hpr_route_storage:insert(Route),
            hpr_route_stream_worker:refresh_route(hpr_route:id(Route), 3),

            sync_routes(
                Routes,
                remove_route(Route, ExistingRoutes),
                Updates#{added => [Route | AddedRoutes]}
            )
    end.

-spec remove_route(
    Target :: hpr_route:route(),
    Coll :: list(hpr_route:route())
) -> list(hpr_route:route()).
remove_route(Target, RouteList) ->
    ID = hpr_route:id(Target),
    lists:filter(fun(R) -> hpr_route:id(R) =/= ID end, RouteList).
