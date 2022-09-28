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

-record(state, {
    host :: string(),
    port :: integer(),
    connection :: grpc_client:connection() | undefined,
    stream :: grpc_client:stream() | undefined,
    dets_backup_path :: string() | undefined,
    dets :: reference() | undefined
}).

-type config_worker_opts() :: #{
    enabled := boolean(),
    host := string(),
    port := integer(),
    dets_backup_path => string()
}.

-type routes_req_v1_map() :: #{
    routes := [map()]
}.

-define(SERVER, ?MODULE).
-define(RCV_CFG_UPDATE, receive_config_update).
-define(RCV_TIMEOUT, timer:seconds(1)).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(config_worker_opts()) -> any().
start_link(#{host := Host, port := Port} = Args) when is_list(Host) andalso is_number(Port) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []);
start_link(_) ->
    ignore.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(#{host := Host, port := Port} = Args) ->
    State = #state{
        host = Host,
        port = Port,
        connection = undefined,
        stream = undefined,
        dets_backup_path = maps:get(dets_backup_path, Args, undefined),
        dets = undefined
    },
    {ok, maybe_init_dets(State), {continue, connect}}.

handle_continue(connect, #state{host = Host, port = Port} = State) ->
    case grpc_client:connect(tcp, Host, Port) of
        {ok, Connection} ->
            {noreply, State#state{connection = Connection}, {continue, init_stream}};
        {error, _E} ->
            timer:sleep(timer:seconds(1)),
            {noreply, State, {continue, connect}}
    end;
handle_continue(
    init_stream,
    #state{
        connection = Connection
    } = State
) ->
    {ok, Stream} = grpc_client:new_stream(
        Connection, 'helium.config.config_service', route_updates, config_pb
    ),
    ok = grpc_client:send_last(Stream, #{}),
    ok = cfg_update(),
    {noreply, State#state{stream = Stream}}.

handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

handle_info(?RCV_CFG_UPDATE, #state{connection = Connection, stream = Stream} = State) ->
    case grpc_client:rcv(Stream, ?RCV_TIMEOUT) of
        {headers, _Headers} ->
            ok = cfg_update(),
            {noreply, State};
        {data, RoutesResV1} ->
            ok = process_config_update(RoutesResV1, State),
            ok = cfg_update(),
            {noreply, State};
        eof ->
            _ = grpc_client:stop_connection(Connection),
            {noreply, State, {continue, connect}};
        {error, timeout} ->
            ok = cfg_update(),
            {noreply, State};
        {error, E} ->
            {stop, {error, E}}
    end;
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{connection = Connection}) ->
    _ = grpc_client:stop_connection(Connection),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec maybe_init_dets(#state{}) -> #state{}.
maybe_init_dets(#state{dets_backup_path = undefined} = State) ->
    State;
maybe_init_dets(#state{dets_backup_path = Path} = State) ->
    ok = filelib:ensure_dir(Path),
    {ok, Dets} = dets:open_file(Path, [{type, set}]),
    case dets:lookup(Dets, last_update) of
        [{last_update, LastRoutesResV1}] ->
            ok = hpr_config:update_routes(LastRoutesResV1),
            ok;
        [] ->
            ok
    end,
    State#state{dets = Dets}.

-spec cfg_update() -> ok.
cfg_update() ->
    self() ! ?RCV_CFG_UPDATE,
    ok.

-spec process_config_update(routes_req_v1_map(), #state{}) -> ok.
process_config_update(RoutesResV1, State) ->
    ok = hpr_config:update_routes(RoutesResV1),
    maybe_cache_response(RoutesResV1, State),
    ok.

-spec maybe_cache_response(RoutesResV1 :: routes_req_v1_map(), #state{}) -> ok.
maybe_cache_response(_RoutesResV1, #state{dets = undefined}) ->
    ok;
maybe_cache_response(RoutesResV1, #state{dets = Dets}) ->
    dets:insert(Dets, {last_update, RoutesResV1}).
