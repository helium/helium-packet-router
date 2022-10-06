-module(hpr_config_worker).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    tmp_load/0,
    tmp_save/1
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
    file_backup_path :: string() | undefined
}).

-type config_worker_opts() :: #{
    host := string(),
    port := integer() | string(),
    file_backup_path => string()
}.

-define(SERVER, ?MODULE).
-define(CONNECT, connect).
-define(INIT_STREAM, init_stream).
-define(RCV_CFG_UPDATE, receive_config_update).
-define(RCV_TIMEOUT, timer:seconds(1)).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(config_worker_opts()) -> any().
start_link(#{host := ""}) ->
    %% TODO: Remove once HCS running
    ok = tmp_load(),
    ignore;
start_link(#{host := Host, port := Port} = Args) when is_list(Host) andalso is_number(Port) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []);
start_link(#{host := Host, port := PortStr} = Args) when is_list(Host) andalso is_list(PortStr) ->
    gen_server:start_link(
        {local, ?SERVER}, ?SERVER, Args#{port := erlang:list_to_integer(PortStr)}, []
    );
start_link(_) ->
    ignore.

%% TODO: Remove once HCS running
-spec tmp_load() -> ok.
tmp_load() ->
    ConfigWorkerConf = application:get_env(hpr, config_worker, #{}),
    BackupFilePath = maps:get(file_backup_path, ConfigWorkerConf),
    maybe_init_from_file(#state{host = "", file_backup_path = BackupFilePath}),
    ok.

%% TODO: Remove once HCS running
-spec tmp_save(NewRoutes :: [client_config_pb:route_v1_pb()]) -> ok.
tmp_save(NewRoutes) ->
    ConfigWorkerConf = application:get_env(hpr, config_worker, #{}),
    BackupFilePath = maps:get(file_backup_path, ConfigWorkerConf),
    Map =
        case file:read_file(BackupFilePath) of
            {ok, Binary} ->
                #{routes := OldRoutes} = erlang:binary_to_term(Binary),
                #{routes => lists:usort(OldRoutes ++ NewRoutes)};
            {error, Reason} ->
                lager:warning("failed to read to file ~p", [Reason]),
                #{routes => NewRoutes}
        end,
    ok = hpr_config:update_routes(Map),
    ok = file:write_file(BackupFilePath, erlang:term_to_binary(Map)),
    ok.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(#{host := Host, port := Port} = Args) ->
    Path = maps:get(file_backup_path, Args, undefined),
    State = #state{
        host = Host,
        port = Port,
        connection = undefined,
        stream = undefined,
        file_backup_path = Path
    },
    lager:info("starting config worker ~s:~w file=~s", [Host, Port, Path]),
    ok = maybe_init_from_file(State),
    {ok, State, {continue, ?CONNECT}}.

handle_continue(?CONNECT, #state{host = Host, port = Port} = State) ->
    case grpc_client:connect(tcp, Host, Port) of
        {ok, Connection} ->
            lager:info("connected"),
            {noreply, State#state{connection = Connection}, {continue, ?INIT_STREAM}};
        {error, _E} ->
            lager:error("failed to connect ~p", [_E]),
            timer:sleep(timer:seconds(1)),
            {noreply, State, {continue, ?CONNECT}}
    end;
handle_continue(
    ?INIT_STREAM,
    #state{
        connection = Connection
    } = State
) ->
    {ok, Stream} = grpc_client:new_stream(
        Connection, 'helium.config.config_service', route_updates, client_config_pb
    ),
    %% Sending Route Request
    RouteReq = #{},
    ok = grpc_client:send_last(Stream, RouteReq),
    lager:info("stream initialized"),
    {noreply, State#state{stream = Stream}, {continue, ?RCV_CFG_UPDATE}};
handle_continue(?RCV_CFG_UPDATE, #state{connection = Connection, stream = Stream} = State) ->
    case grpc_client:rcv(Stream, ?RCV_TIMEOUT) of
        {headers, _Headers} ->
            {noreply, State, {continue, ?RCV_CFG_UPDATE}};
        {data, RoutesResV1} ->
            lager:info("got router update"),
            ok = process_routes_update(RoutesResV1, State),
            {noreply, State, {continue, ?RCV_CFG_UPDATE}};
        eof ->
            lager:warning("got eof"),
            _ = grpc_client:stop_connection(Connection),
            {noreply, State, {continue, ?CONNECT}};
        {error, timeout} ->
            {noreply, State, {continue, ?RCV_CFG_UPDATE}};
        {error, E} ->
            lager:error("failed to rcv ~p", [E]),
            {stop, {error, E}}
    end.

handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{connection = Connection}) ->
    lager:error("terminate ~p", [_Reason]),
    _ = grpc_client:stop_connection(Connection),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec maybe_init_from_file(#state{}) -> ok.
maybe_init_from_file(#state{file_backup_path = undefined}) ->
    ok;
maybe_init_from_file(#state{file_backup_path = Path}) ->
    ok = filelib:ensure_dir(Path),
    case file:read_file(Path) of
        {ok, Binary} ->
            try erlang:binary_to_term(Binary) of
                #{routes := Routes} = LastRoutesResV1 when is_list(Routes) ->
                    ok = hpr_config:update_routes(LastRoutesResV1);
                _ ->
                    ok = file:write_file(Path, erlang:term_to_binary(#{routes => []})),
                    lager:warning("binary_to_term failed, fixing")
            catch
                _E:_R ->
                    ok = file:write_file(Path, erlang:term_to_binary(#{routes => []})),
                    lager:warning("binary_to_term crash ~p ~p, fixing", [_E, _R])
            end;
        {error, Reason} ->
            lager:warning("failed to read to file ~p", [Reason])
    end.

-spec process_routes_update(client_config_pb:routes_res_v1_pb(), #state{}) -> ok.
process_routes_update(RoutesResV1, State) ->
    ok = hpr_config:update_routes(RoutesResV1),
    case maybe_cache_response(RoutesResV1, State) of
        ok -> ok;
        {error, Reason} -> lager:error("failed to write to file ~p", [Reason])
    end.

-spec maybe_cache_response(RoutesResV1 :: client_config_pb:routes_res_v1_pb(), #state{}) ->
    ok | {error, any()}.
maybe_cache_response(_RoutesResV1, #state{file_backup_path = undefined}) ->
    ok;
maybe_cache_response(RoutesResV1, #state{file_backup_path = Path}) ->
    Binary = erlang:term_to_binary(RoutesResV1),
    file:write_file(Path, Binary).
