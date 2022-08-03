-module(hpr_routing_config).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    lookup_eui/2,
    lookup_devaddr/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(INIT_ASYNC, init_async).
-define(EUIS_ETS, hpr_routing_config_euis_ets).
-define(DEVADDRS_ETS, hpr_routing_config_devaddrs_ets).
-define(DETS, hpr_routing_config_dets).

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec lookup_eui(AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()) ->
    [hpr_routing_config_route:route()].
lookup_eui(AppEUI, DevEUI) ->
    Routes0 = ets:lookup(?EUIS_ETS, {AppEUI, DevEUI}),
    Routes1 = ets:lookup(?EUIS_ETS, {AppEUI, 0}),
    [Route || {_, Route} <- Routes1 ++ Routes0].

-spec lookup_devaddr(DevAddr :: non_neg_integer()) ->
    [hpr_routing_config_route:route()].
lookup_devaddr(DevAddr) ->
    case lora_subnet:parse_netid(DevAddr, big) of
        {ok, NetID} ->
            %% MS = ets:fun2ms(
            %%     fun
            %%         ({{NetID0, Start, End}, Route}) when
            %%             NetID0 == NetID andalso Start == 0 andalso End == 0
            %%         ->
            %%             Route;
            %%         ({{NetID0, Start, End}, Route}) when
            %%             NetID0 == NetID andalso Start =< DevAddr andalso DevAddr =< End
            %%         ->
            %%             Route
            %%     end
            %% ),
            MS = [
                {
                    {{'$1', '$2', '$3'}, '$4'},
                    [
                        {'andalso', {'==', '$1', NetID},
                            {'andalso', {'==', '$2', 0}, {'==', '$3', 0}}}
                    ],
                    ['$4']
                },
                {
                    {{'$1', '$2', '$3'}, '$4'},
                    [
                        {'andalso', {'==', '$1', NetID},
                            {'andalso', {'=<', '$2', DevAddr}, {'=<', DevAddr, '$3'}}}
                    ],
                    ['$4']
                }
            ],
            ets:select(?DEVADDRS_ETS, MS);
        _Err ->
            []
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(#{base_dir := BaseDir} = _Args) ->
    {ok, ?DETS} = dets:open_file(?DETS, [{file, filename:join(BaseDir, erlang:atom_to_list(?DETS))}]),
    _ = ets:new(?EUIS_ETS, [
        public,
        named_table,
        bag,
        {read_concurrency, true}
    ]),
    _ = ets:new(?DEVADDRS_ETS, [
        public,
        named_table,
        bag,
        {read_concurrency, true}
    ]),
    ok = init_ets(),
    {ok, #state{}, {continue, ?INIT_ASYNC}}.

handle_continue(?INIT_ASYNC, State) ->
    %% Connect to Config Service to get updates
    {noreply, State};
handle_continue(_Msg, State) ->
    {noreply, State}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    _ = dets:close(?DETS),
    _ = ets:delete(?EUIS_ETS),
    _ = ets:delete(?DEVADDRS_ETS),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec init_ets() -> ok.
init_ets() ->
    {EUIRoutes, DevAddrRoutes} = dets:foldl(
        fun({_OUI, Route}, {EUIRoutesAcc, DevAddrRoutesAcc}) ->
            EUIs = hpr_routing_config_route:euis(Route),
            EUIRoutes = [{{AppEUI, DevEUI}, Route} || {AppEUI, DevEUI} <- EUIs],
            NetID = hpr_routing_config_route:net_id(Route),
            DevAddrRangeRoutes =
                case hpr_routing_config_route:devaddr_ranges(Route) of
                    [] ->
                        [{{NetID, 0, 0}, Route}];
                    DevAddrRanges ->
                        [{{NetID, Start, End}, Route} || {Start, End} <- DevAddrRanges]
                end,
            {EUIRoutes ++ EUIRoutesAcc, DevAddrRangeRoutes ++ DevAddrRoutesAcc}
        end,
        {[], []},
        ?DETS
    ),
    true = ets:insert(?EUIS_ETS, EUIRoutes),
    true = ets:insert(?DEVADDRS_ETS, DevAddrRoutes),
    ok.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-define(BASE_TMP_DIR, "./_build/test/tmp").
-define(BASE_TMP_DIR_TEMPLATE, "XXXXXXXXXX").

init_test() ->
    BaseDir = tmp_dir("init_test"),
    _ = init_dets(BaseDir),
    {ok, Pid} = ?MODULE:start_link(#{base_dir => BaseDir}),

    ?assertEqual(4, ets:info(?EUIS_ETS, size)),
    ?assertEqual(3, ets:info(?DEVADDRS_ETS, size)),

    ok = gen_server:stop(Pid),
    ok.

lookup_eui_test() ->
    BaseDir = tmp_dir("lookup_eui_test"),
    [Route1, Route2] = init_dets(BaseDir),
    {ok, Pid} = ?MODULE:start_link(#{base_dir => BaseDir}),

    ?assertEqual(
        [Route1], ?MODULE:lookup_eui(1, 1)
    ),
    ?assertEqual([Route1, Route2], ?MODULE:lookup_eui(2, 1)),

    ok = gen_server:stop(Pid),
    ok.

lookup_devaddr_test() ->
    BaseDir = tmp_dir("lookup_devaddr_test"),
    [Route1, Route2] = init_dets(BaseDir),
    {ok, Pid} = ?MODULE:start_link(#{base_dir => BaseDir}),

    ?assertEqual(
        [Route1, Route2], ?MODULE:lookup_devaddr(16#00000000)
    ),
    ?assertEqual(
        [Route1, Route2], ?MODULE:lookup_devaddr(16#0000000A)
    ),
    ?assertEqual(
        [Route2, Route1], ?MODULE:lookup_devaddr(16#0000000C)
    ),
    ?assertEqual(
        [Route2, Route1], ?MODULE:lookup_devaddr(16#00000010)
    ),
    ?assertEqual(
        [Route2], ?MODULE:lookup_devaddr(16#0000000B)
    ),
    ?assertEqual(
        [Route2], ?MODULE:lookup_devaddr(16#00000100)
    ),

    ok = gen_server:stop(Pid),
    ok.

init_dets(BaseDir) ->
    {ok, NetID} = lora_subnet:parse_netid(16#00000000, big),

    {ok, ?DETS} = dets:open_file(?DETS, [{file, filename:join(BaseDir, erlang:atom_to_list(?DETS))}]),
    Route1 = hpr_routing_config_route:new(
        NetID,
        [{16#00000000, 16#0000000A}, {16#0000000C, 16#00000010}],
        [{1, 1}, {2, 0}],
        <<"lsn.lora.com>">>,
        gwmp,
        1
    ),
    Route2 = hpr_routing_config_route:new(
        NetID, [], [{2, 1}, {3, 0}], <<"lsn.lora.com>">>, http, 2
    ),
    ok = dets:insert(?DETS, [{1, Route1}, {2, Route2}]),
    ok = dets:close(?DETS),
    [Route1, Route2].

tmp_dir(SubDir) ->
    Path = filename:join(?BASE_TMP_DIR, SubDir),
    os:cmd("mkdir -p " ++ Path),
    create_tmp_dir(Path ++ "/" ++ ?BASE_TMP_DIR_TEMPLATE).

-spec create_tmp_dir(list()) -> list().
create_tmp_dir(Path) ->
    nonl(os:cmd("mktemp -d " ++ Path)).

nonl([$\n | T]) -> nonl(T);
nonl([H | T]) -> [H | nonl(T)];
nonl([]) -> [].

-endif.
