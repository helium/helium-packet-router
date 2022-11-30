-module(hpr_cs_conn_worker).

-behaviour(gen_server).

-include("hpr.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    get_connection/0
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
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
    conn_backoff :: backoff:backoff()
}).

-type config_conn_worker_opts() :: #{
    host := string(),
    port := integer() | string()
}.

-define(SERVER, ?MODULE).
-define(CONNECT, connect).
-define(INIT_STREAM, init_stream).
-define(RCV_CFG_UPDATE, receive_config_update).
-define(RCV_TIMEOUT, timer:seconds(5)).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(config_conn_worker_opts()) -> any().
start_link(#{host := Host, port := Port} = Args) when is_list(Host) andalso is_number(Port) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []);
start_link(#{host := Host, port := PortStr} = Args) when is_list(Host) andalso is_list(PortStr) ->
    gen_server:start_link(
        {local, ?SERVER}, ?SERVER, Args#{port := erlang:list_to_integer(PortStr)}, []
    ).

-spec get_connection() -> grpc_client:connection() | undefined.
get_connection() ->
    gen_server:call(?MODULE, get_connection).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(#{host := Host, port := Port}) ->
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    State = #state{
        host = Host,
        port = Port,
        connection = undefined,
        conn_backoff = Backoff
    },
    lager:info("starting config connection worker ~s:~w", [Host, Port]),
    self() ! ?CONNECT,
    {ok, State}.

handle_call(get_connection, _From, #state{connection = Connection} = State) ->
    {reply, Connection, State};
handle_call(_Msg, _From, State) ->
    lager:warning("unimplemented_call ~p", [_Msg]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

handle_info(?CONNECT, #state{host = Host, port = Port, conn_backoff = Backoff0} = State) ->
    lager:info("connecting"),
    case grpc_client:connect(tcp, Host, Port) of
        {ok, Connection} ->
            lager:info("connected to ~s:~w", [Host, Port]),
            {_, Backoff1} = backoff:succeed(Backoff0),
            #{http_connection := Pid} = Connection,
            _Ref = erlang:monitor(process, Pid, [{tag, {'DOWN', ?MODULE}}]),
            {noreply, State#state{connection = Connection, conn_backoff = Backoff1}};
        {error, _E} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            lager:error("failed to connect ~pm sleeping ~wms", [_E, Delay]),
            _ = erlang:send_after(Delay, self(), ?CONNECT),
            {noreply, State#state{conn_backoff = Backoff1}}
    end;
handle_info({{'DOWN', ?MODULE}, _Mon, process, _Pid, _ExitReason}, State) ->
    lager:info("connection ~p went down ~p", [_Pid, _ExitReason]),
    self() ! ?CONNECT,
    {noreply, State#state{connection = undefined}};
handle_info(_Msg, State) ->
    lager:warning("unimplemented_info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, #state{connection = Connection}) ->
    lager:error("terminate ~p", [_Reason]),
    _ = catch grpc_client:stop_connection(Connection),
    ok.
