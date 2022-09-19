-module(hpr_routing_config_worker).

-export([
    start_link/1,
    init/1
]).

-record(config_service, {
    transport,
    host,
    port,
    svcname,
    rpcname,
    retry_interval,
    dets_backup_enabled,
    dets_backup_path
}).

-record(state, {
    parent,
    service,
    connection,
    stream,
    dets
}).

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
        svcname = SvcName,
        rpcname = RpcName,
        retry_interval = Interval,
        dets_backup_enabled = maps:get(dets_backup_enabled, Args, false),
        dets_backup_path = maps:get(dets_backup_path, Args, nil)
    },
    proc_lib:start_link(?MODULE, init, [#state{parent = self(), service = Service}]).

init(#state{parent = Parent} = State1) ->
    lager:info("Starting hpr_routing_config_worker ~p.", [self()]),
    State2 = maybe_init_dets(State1),
    ok = maybe_load_from_dets(State2),
    proc_lib:init_ack(Parent, {ok, self()}),
    connect(State2).

connect(
    #state{service = Service} = State
) ->
    #config_service{
        transport = Transport,
        host = Host,
        port = Port,
        retry_interval = Interval
    } = Service,
    lager:info("Connecting to config service."),
    case grpc_client:connect(Transport, Host, Port) of
        {ok, Connection} ->
            init_stream(State#state{connection = Connection});
        {error, E} ->
            lager:error("Error connecting to config service: ~p.", [E]),
            lager:warning("Sleeping ~p milliseconds.", [Interval]),
            timer:sleep(Interval),
            connect(State)
    end.

init_stream(
    #state{
        service = Service,
        connection = Connection
    } = State
) ->
    #config_service{
        svcname = SvcName,
        rpcname = RpcName,
        retry_interval = Interval
    } = Service,
    case grpc_client:new_stream(Connection, SvcName, RpcName, config_pb) of
        {ok, Stream} ->
            send_routes_req(State#state{stream = Stream});
        {error, E} ->
            lager:error("Error creating routes stream: ~p.", [E]),
            lager:warning("Sleeping ~p milliseconds.", [Interval]),
            timer:sleep(Interval),
            reconnect(State)
    end.

reconnect(#state{connection = Connection} = State) ->
    case is_process_alive(Connection) of
        true ->
            grpc_client:stop_connection(Connection);
        _ ->
            ok
    end,
    connect(State#state{connection = nil, stream = nil}).

send_routes_req(#state{stream = Stream} = State) ->
    ok = grpc_client:send_last(Stream, #{}),
    receive_config_updates(State).

receive_config_updates(#state{stream = Stream} = State) ->
    case grpc_client:rcv(Stream) of
        {headers, Headers} ->
            lager:debug("Received headers: ~p", [Headers]),
            receive_config_updates(State);
        {data, RoutesResV1} ->
            lager:info("Received a config update."),
            lager:debug("Config update: ~p", [RoutesResV1]),
            process_config_update(RoutesResV1, State);
        eof ->
            lager:info("Received eof from config service.", []),
            reconnect(State);
        {error, E} ->
            lager:error("Error receiving config update: ~p.  Exiting.", [E]),
            {error, E}
    end.

process_config_update(RoutesResV1, State) ->
    ok = hpr_config_db:update_routes(RoutesResV1),
    maybe_cache_response(RoutesResV1, State),
    lager:info("Config update complete."),
    receive_config_updates(State).

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

maybe_cache_response(_RoutesResV1, #state{dets = nil}) ->
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
