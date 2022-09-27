-module(hpr_config_worker).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1
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
    terminate/2
]).

-record(config_service, {
    transport :: tcp | ssl,
    host :: string(),
    port :: integer(),
    receive_timeout :: non_neg_integer(),
    svcname :: atom(),
    rpcname :: atom(),
    retry_interval :: non_neg_integer(),
    dets_backup_enabled :: boolean(),
    dets_backup_path :: string()
}).

-record(state, {
    service :: #config_service{},
    connection :: grpc_client:connection() | undefined,
    stream :: grpc_client:stream() | undefined,
    dets :: reference() | undefined
}).

-define(RCV_CFG_UPDATE, receive_config_update).

-type transport() :: 'tcp' | 'ssl'.

-type config_worker_opts() :: #{
    enabled := boolean(),
    transport := transport(),
    host := string(),
    port := integer(),
    receive_timeout => non_neg_integer(),
    svcname := atom(),
    rpcname := atom(),
    retry_interval => non_neg_integer(),
    dets_backup_enabled => boolean(),
    dets_backup_path => string()
}.

-type routes_req_v1_map() :: #{
    routes := [map()]
}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(config_worker_opts()) -> any().
start_link(#{enabled := false}) ->
    ignore;
start_link(
    #{
        transport := Transport,
        host := Host,
        port := Port,
        svcname := SvcName,
        rpcname := RpcName,
        retry_interval := Interval
    } = Args
) ->
    Service = #config_service{
        transport = Transport,
        host = Host,
        port = Port,
        receive_timeout = maps:get(receive_timeout, Args, 2000),
        svcname = SvcName,
        rpcname = RpcName,
        retry_interval = Interval,
        dets_backup_enabled = maps:get(dets_backup_enabled, Args, false),
        dets_backup_path = maps:get(dets_backup_path, Args, undefined)
    },
    State = #state{
        service = Service,
        connection = undefined,
        stream = undefined,
        dets = undefined
    },
    gen_server:start_link(?MODULE, [State], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([#state{} = State1]) ->
    lager:info("starting hpr_config_worker"),
    State2 = maybe_init_dets(State1),
    ok = maybe_load_from_dets(State2),
    {ok, State2, {continue, connect}}.

handle_continue(connect, #state{service = Service} = State) ->
    #config_service{
        transport = Transport,
        host = Host,
        port = Port,
        retry_interval = Interval
    } = Service,
    lager:info("connecting to config service= ~p ~p", [Host, Port]),
    case grpc_client:connect(Transport, Host, Port) of
        {ok, Connection} ->
            {noreply, State#state{connection = Connection}, {continue, init_stream}};
        {error, E} ->
            lager:error("error connecting to config service: ~p, sleeping", [E, Interval]),
            timer:sleep(Interval),
            {noreply, State, {continue, connect}}
    end;
handle_continue(
    init_stream,
    #state{
        service = Service,
        connection = Connection
    } = State
) ->
    #config_service{
        svcname = SvcName,
        rpcname = RpcName
    } = Service,
    {ok, Stream} = grpc_client:new_stream(Connection, SvcName, RpcName, config_pb),
    ok = grpc_client:send_last(Stream, #{}),
    self() ! ?RCV_CFG_UPDATE,
    {noreply, State#state{stream = Stream}}.

handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

handle_info(
    ?RCV_CFG_UPDATE, #state{connection = Connection, stream = Stream, service = Service} = State
) ->
    #config_service{receive_timeout = RcvTimeout} = Service,
    case grpc_client:rcv(Stream, RcvTimeout) of
        {headers, _Headers} ->
            self() ! ?RCV_CFG_UPDATE,
            {noreply, State};
        {data, RoutesResV1} ->
            lager:debug("config update: ~p", [RoutesResV1]),
            ok = process_config_update(RoutesResV1, State),
            self() ! ?RCV_CFG_UPDATE,
            {noreply, State};
        eof ->
            lager:info("received eof from config service.", []),
            _ = grpc_client:stop_connection(Connection),
            {noreply, State, {continue, connect}};
        {error, timeout} ->
            self() ! ?RCV_CFG_UPDATE,
            {noreply, State};
        {error, E} ->
            lager:error("error receiving config update: ~p.  Exiting.", [E]),
            {stop, {error, E}}
    end;
handle_info(Msg, State) ->
    lager:warning("unexpected info message: ~p.", [Msg]),
    {noreply, State}.

terminate(Reason, #state{connection = Connection}) ->
    _ = grpc_client:stop_connection(Connection),
    lager:info("hpr_config_worker terminating with reason ~p.", [Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec process_config_update(routes_req_v1_map(), #state{}) -> ok.
process_config_update(RoutesResV1, State) ->
    ok = hpr_config:update_routes(RoutesResV1),
    maybe_cache_response(RoutesResV1, State),
    lager:info("Config update complete."),
    ok.

-spec maybe_init_dets(#state{}) -> #state{}.
maybe_init_dets(
    #state{
        service = #config_service{dets_backup_enabled = false}
    } = State
) ->
    State;
maybe_init_dets(
    #state{
        service = #config_service{
            dets_backup_enabled = true,
            dets_backup_path = Path
        }
    } = State
) ->
    {ok, Dets} = dets:open_file(Path, [{type, set}]),
    State#state{dets = Dets}.

-spec maybe_cache_response(RoutesResV1 :: routes_req_v1_map(), #state{}) -> ok.
maybe_cache_response(_RoutesResV1, #state{dets = undefined}) ->
    ok;
maybe_cache_response(RoutesResV1, #state{dets = Dets}) ->
    dets:insert(Dets, {last_update, RoutesResV1}).

-spec insert(Route :: hpr_route:route()) -> ok.
insert(Route) ->
    EUIs = hpr_route:euis(Route),
    EUIRoutes = [{{AppEUI, DevEUI}, Route} || {AppEUI, DevEUI} <- EUIs],
    NetID = hpr_route:net_id(Route),
    DevAddrRangesRoutes =
        case hpr_route:devaddr_ranges(Route) of
            [] ->
                [{{NetID, 0, 0}, Route}];
            DevAddrRanges ->
                [{{NetID, Start, End}, Route} || {Start, End} <- DevAddrRanges]
        end,
    true = ets:insert(?EUIS_ETS, EUIRoutes),
    true = ets:insert(?DEVADDRS_ETS, DevAddrRangesRoutes),
    ok.

-endif.

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
        lists:sort([Route1, Route2]), lists:sort(?MODULE:lookup_devaddr(16#00000000))
    ),
    ?assertEqual(
        lists:sort([Route1, Route2]), lists:sort(?MODULE:lookup_devaddr(16#0000000A))
    ),
    ?assertEqual(
        lists:sort([Route1, Route2]), lists:sort(?MODULE:lookup_devaddr(16#0000000C))
    ),
    ?assertEqual(
        lists:sort([Route1, Route2]), lists:sort(?MODULE:lookup_devaddr(16#00000010))
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
    {ok, ?DETS} =
        dets:open_file(?DETS, [{file, filename:join(BaseDir, erlang:atom_to_list(?DETS))}]),
    {ok, NetID} = lora_subnet:parse_netid(16#00000000, big),
    Route1 = hpr_route:new(
        NetID,
        [{16#00000000, 16#0000000A}, {16#0000000C, 16#00000010}],
        [{1, 1}, {2, 0}],
        <<"lsn.lora.com>">>,
        gwmp,
        1
    ),
    Route2 = hpr_route:new(
        NetID, [], [{2, 1}, {3, 0}], <<"lsn.lora.com>">>, http_roaming, 2
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
