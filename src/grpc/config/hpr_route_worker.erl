-module(hpr_route_worker).

-behaviour(gen_server).

-include("hpr.hrl").

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

-ifdef(TEST).
-define(BACKOFF_MIN, timer:seconds(1)).
-else.
-define(BACKOFF_MIN, timer:seconds(10)).
-endif.
-define(BACKOFF_MAX, timer:minutes(5)).

-record(state, {
    host :: string(),
    port :: integer(),
    connection :: grpc_client:connection() | undefined,
    stream :: grpc_client:stream() | undefined,
    file_backup_path :: path(),
    conn_backoff :: backoff:backoff()
}).

-type route_worker_opts() :: #{
    host := string(),
    port := integer() | string(),
    file_backup_path => string()
}.
-type path() :: string() | undefined.

-define(SERVER, ?MODULE).
-define(CONNECT, connect).
-define(INIT_STREAM, init_stream).
-define(RCV_CFG_UPDATE, receive_config_update).
-define(RCV_TIMEOUT, timer:seconds(5)).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(route_worker_opts()) -> any().
start_link(#{host := Host, port := Port} = Args) when is_list(Host) andalso is_number(Port) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []);
start_link(#{host := Host, port := PortStr} = Args) when is_list(Host) andalso is_list(PortStr) ->
    gen_server:start_link(
        {local, ?SERVER}, ?SERVER, Args#{port := erlang:list_to_integer(PortStr)}, []
    );
start_link(_) ->
    ignore.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(#{host := Host, port := Port} = Args) ->
    Path = maps:get(file_backup_path, Args, undefined),
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    State = #state{
        host = Host,
        port = Port,
        connection = undefined,
        stream = undefined,
        file_backup_path = Path,
        conn_backoff = Backoff
    },
    lager:info("starting config worker ~s:~w file=~s", [Host, Port, Path]),
    ok = maybe_init_from_file(Path),
    {ok, State, {continue, ?CONNECT}}.

handle_continue(?CONNECT, #state{host = Host, port = Port, conn_backoff = Backoff0} = State) ->
    lager:info("connecting"),
    case grpc_client:connect(tcp, Host, Port) of
        {ok, Connection} ->
            lager:info("connected"),
            {_, Backoff1} = backoff:succeed(Backoff0),
            {noreply, State#state{connection = Connection, conn_backoff = Backoff1},
                {continue, ?INIT_STREAM}};
        {error, _E} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            lager:error("failed to connect ~pm sleeping ~wms", [_E, Delay]),
            timer:sleep(Delay),
            {noreply, State#state{conn_backoff = Backoff1}, {continue, ?CONNECT}}
    end;
handle_continue(
    ?INIT_STREAM,
    #state{
        connection = Connection
    } = State
) ->
    {ok, Stream} = grpc_client:new_stream(
        Connection, 'helium.config.route', stream, client_config_pb
    ),
    %% Sending Route Stream Request
    {PubKey, SigFun} = persistent_term:get(?HPR_KEY),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    RouteStreamReq = hpr_route_stream_req:new(PubKeyBin),
    SignedRouteStreamReq = hpr_route_stream_req:sign(RouteStreamReq, SigFun),
    ok = grpc_client:send_last(Stream, hpr_route_stream_req:to_map(SignedRouteStreamReq)),
    lager:info("stream initialized"),
    {noreply, State#state{stream = Stream}, {continue, ?RCV_CFG_UPDATE}};
handle_continue(
    ?RCV_CFG_UPDATE,
    #state{
        connection = Connection, stream = Stream, file_backup_path = Path, conn_backoff = Backoff0
    } = State
) ->
    case grpc_client:rcv(Stream, ?RCV_TIMEOUT) of
        {headers, _Headers} ->
            {noreply, State, {continue, ?RCV_CFG_UPDATE}};
        {data, RouteStreamRes} ->
            lager:info("got router update"),
            ok = process_route_stream_res(hpr_route_stream_res:from_map(RouteStreamRes), Path),
            {noreply, State, {continue, ?RCV_CFG_UPDATE}};
        eof ->
            lager:warning("got eof"),
            _ = catch grpc_client:stop_connection(Connection),
            {noreply, State, {continue, ?CONNECT}};
        {error, timeout} ->
            lager:debug("rcv timeout"),
            {_, Backoff1} = backoff:succeed(Backoff0),
            {noreply, State#state{conn_backoff = Backoff1}, {continue, ?RCV_CFG_UPDATE}};
        {error, E} ->
            lager:error("failed to rcv ~p", [E]),
            {stop, {error, E}}
    end.

handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

handle_info(_Msg, State) ->
    lager:warning("unimplemented_info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, #state{connection = Connection}) ->
    lager:error("terminate ~p", [_Reason]),
    _ = catch grpc_client:stop_connection(Connection),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec process_route_stream_res(
    RouteStreamRes :: hpr_route_stream_res:route_stream_res(), Path :: path()
) -> ok.
process_route_stream_res(RouteStreamRes, State) ->
    Route = hpr_route_stream_res:route(RouteStreamRes),
    case hpr_route_stream_res:action(RouteStreamRes) of
        delete ->
            hpr_config:delete_route(Route);
        _ ->
            hpr_config:insert_route(Route)
    end,
    case maybe_cache_response(RouteStreamRes, State) of
        {error, Reason} -> lager:error("failed to write to file ~p", [Reason]);
        ok -> ok
    end.

-spec maybe_cache_response(RouteStreamRes :: hpr_route_stream_res:route_stream_res(), path()) ->
    ok | {error, any()}.
maybe_cache_response(_RouteStreamRes, undefined) ->
    ok;
maybe_cache_response(RouteStreamRes, Path) ->
    case open_backup_file(Path) of
        {error, _Reason} ->
            lager:error("failed to open backup file (~s) ~p", [Path, _Reason]);
        {ok, Map0} ->
            Route = hpr_route_stream_res:route(RouteStreamRes),
            ID = hpr_route:id(Route),
            Map1 =
                case hpr_route_stream_res:action(RouteStreamRes) of
                    delete ->
                        maps:remove(ID, Map0);
                    _ ->
                        Map0#{ID => Route}
                end,
            Binary = erlang:term_to_binary(Map1),
            file:write_file(Path, Binary)
    end.

-spec maybe_init_from_file(path()) -> ok.
maybe_init_from_file(undefined) ->
    ok;
maybe_init_from_file(Path) ->
    ok = filelib:ensure_dir(Path),
    case open_backup_file(Path) of
        {error, enoent} ->
            lager:warning("file does not exist creating"),
            ok = file:write_file(Path, erlang:term_to_binary(#{}));
        {error, _Reason} ->
            lager:error("failed to open backup file (~s) ~p", [Path, _Reason]);
        {ok, Map} ->
            maps:foreach(
                fun(_ID, Route) ->
                    hpr_config:insert_route(Route)
                end,
                Map
            )
    end.

-spec open_backup_file(Path :: string()) -> {ok, map()} | {error, any()}.
open_backup_file(Path) ->
    case file:read_file(Path) of
        {error, _Reason} = Error ->
            Error;
        {ok, Binary} ->
            try erlang:binary_to_term(Binary) of
                Map when is_map(Map) ->
                    {ok, Map};
                _ ->
                    ok = file:write_file(Path, erlang:term_to_binary(#{})),
                    lager:warning("binary_to_term failed, fixing"),
                    {ok, #{}}
            catch
                _E:_R ->
                    ok = file:write_file(Path, erlang:term_to_binary(#{})),
                    lager:warning("binary_to_term crash ~p ~p, fixing", [_E, _R]),
                    {ok, #{}}
            end
    end.
