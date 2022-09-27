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
    handle_cast/2,
    handle_call/3,
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
    lager:info("Starting hpr_config_worker ~p.", [self()]),
    State2 = maybe_init_dets(State1),
    ok = maybe_load_from_dets(State2),
    connect(),
    {ok, State2}.

handle_cast(connect, #state{service = Service} = State) ->
    #config_service{
        transport = Transport,
        host = Host,
        port = Port,
        retry_interval = Interval
    } = Service,
    lager:info("Connecting to config service."),
    case grpc_client:connect(Transport, Host, Port) of
        {ok, Connection} ->
            init_stream(),
            {noreply, State#state{connection = Connection}};
        {error, E} ->
            lager:error("Error connecting to config service: ~p.", [E]),

            %% TODO:  Use a backoff strategy here.
            lager:warning("Sleeping ~p milliseconds.", [Interval]),
            timer:sleep(Interval),

            connect(),
            {noreply, State}
    end;
handle_cast(
    init_stream,
    #state{
        service = Service,
        connection = Connection
    } = State
) ->
    #config_service{
        svcname = SvcName,
        rpcname = RpcName
        % retry_interval = Interval
    } = Service,
    case grpc_client:new_stream(Connection, SvcName, RpcName, config_pb) of
        {ok, Stream} ->
            send_routes_req(),
            {noreply, State#state{stream = Stream}}
        % _E ->
        %     lager:error("Error creating routes stream: ~p.", [_E]),

        %     %% TODO:  Use a backoff strategry here.
        %     lager:warning("Sleeping ~p milliseconds.", [Interval]),
        %     timer:sleep(Interval),

        %     reconnect(),
        %     {noreply, State}
    end;
handle_cast(reconnect, #state{connection = Connection} = State) ->
    _ = grpc_client:stop_connection(Connection),
    connect(),
    {noreply, State#state{connection = undefined, stream = undefined}};
handle_cast(send_routes_req, #state{stream = Stream} = State) ->
    %% We send a RoutesReqV1 to the server to start the stream of
    %% config updates.  RoutesReqV1 is essentially an "empty envelope"
    %% as it has no fields for us to fill in.  Thus, we send an empty
    %% map.

    %% Note that we must use grpc_client:send_last/2 to indicate to
    %% the server that we are done talking.  If we use
    %% grpc_client:send/2, the server will not respond.

    ok = grpc_client:send_last(Stream, #{}),
    receive_config_update(),
    {noreply, State};
handle_cast(receive_config_update, #state{stream = Stream, service = Service} = State) ->
    #config_service{receive_timeout = RcvTimeout} = Service,
    case grpc_client:rcv(Stream, RcvTimeout) of
        {headers, Headers} ->
            lager:debug("Received headers: ~p", [Headers]),
            receive_config_update(),
            {noreply, State};
        {data, RoutesResV1} ->
            lager:info("Received a config update."),
            lager:debug("Config update: ~p", [RoutesResV1]),
            ok = process_config_update(RoutesResV1, State),
            receive_config_update(),
            {noreply, State};
        eof ->
            lager:info("Received eof from config service.", []),
            reconnect(),
            {noreply, State};
        {error, timeout} ->
            %% No update received.  Check for system messages and resume waiting.
            receive_config_update(),
            {noreply, State};
        {error, E} ->
            lager:error("Error receiving config update: ~p.  Exiting.", [E]),
            {stop, {error, E}}
    end.

handle_call(Msg, From, State) ->
    lager:error("Received unexpected call: ~p from ~p.  This is a bug.", [Msg, From]),
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State) ->
    %% 'EXIT' messages are likely the result of disconnects from the config server.
    lager:warning("Received EXIT from ~p with reason ~p.", [Pid, Reason]),
    {noreply, State};
handle_info(Msg, State) ->
    lager:error("Unexpected info message: ~p.", [Msg]),
    {noreply, State}.

terminate(Reason, _State) ->
    lager:info("hpr_config_worker terminating with reason ~p.", [Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec connect() -> ok.
connect() ->
    gen_server:cast(self(), connect).

-spec reconnect() -> ok.
reconnect() ->
    gen_server:cast(self(), reconnect).

-spec init_stream() -> ok.
init_stream() ->
    gen_server:cast(self(), init_stream).

-spec send_routes_req() -> ok.
send_routes_req() ->
    gen_server:cast(self(), send_routes_req).

-spec receive_config_update() -> ok.
receive_config_update() ->
    gen_server:cast(self(), receive_config_update).

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
