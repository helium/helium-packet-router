-module(hpr_router_connection_manager).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/0,
    get_connection/1
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

-type lns() :: binary().
-type endpoint() :: {tcp | ssl, string(), non_neg_integer()}.
-type from() :: {pid(), any()}.

-record(state, {
    conns = #{} :: #{lns() => grpc_client:connection()}
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Return an existing connection to the Router at Lns, or create a
%% new connection if one doesn't exist.
-spec get_connection(Lns :: lns()) -> {ok, grpc_client:connection()} | {error, any()}.
get_connection(Lns) ->
    gen_server:call(?MODULE, {get_connection, Lns}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

-spec init([]) -> {ok, #state{}}.
init([]) ->
    {ok, #state{}}.

-spec handle_call(Msg :: any(), from(), #state{}) ->
    {reply, {ok, grpc_client:connection()} | {error, any()}, #state{}}
    | {stop, {unimplemented_call, any()}, #state{}}.
handle_call({get_connection, Lns}, _From, #state{conns = Conns} = State) ->
    case maps:get(Lns, Conns, undefined) of
        undefined ->
            {Transport, Host, Port} = decode_lns(Lns),
            case grpc_client:connect(Transport, Host, Port, []) of
                {error, _} = Error ->
                    {reply, Error, State};
                {ok, Conn} = OK ->
                    #{http_connection := Pid} = Conn,
                    _Ref = erlang:monitor(process, Pid, [{tag, {'DOWN', Lns}}]),
                    lager:info("connected to ~s via ~p", [Lns, Pid]),
                    {reply, OK, State#state{conns = Conns#{Lns => Conn}}}
            end;
        Conn ->
            lager:info("connection for ~s found", [Lns]),
            {reply, {ok, Conn}, State}
    end;
handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

-spec handle_cast(Msg :: any(), #state{}) ->
    {noreply, #state{}} | {stop, {unimplemented_cast, any()}, #state{}}.
handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

-spec handle_info({{'DOWN', lns()}, reference(), process, pid(), any()}, #state{}) ->
    {noreply, #state{}}.
handle_info({{'DOWN', Lns}, _Mon, process, _Pid, _ExitReason}, #state{conns = Conns} = State) ->
    lager:info("connection ~p to ~s went down ~p", [_Pid, Lns, _ExitReason]),
    {noreply, State#state{conns = maps:remove(Lns, Conns)}};
handle_info({'EXIT', _Pid, _Reason}, State) ->
    lager:info("connection ~p exited ~p", [_Pid, _Reason]),
    {noreply, State}.

terminate(_Reason, #state{}) ->
    lager:error("terminate ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec decode_lns(lns()) -> endpoint().
decode_lns(Lns) ->
    {Address, Port} = decode_lns_parts(binary:split(Lns, <<$:>>)),
    {tcp, Address, Port}.

-spec decode_lns_parts([binary()]) -> {string(), non_neg_integer()} | none().
decode_lns_parts([Address, Port]) ->
    {erlang:binary_to_list(Address), erlang:binary_to_integer(Port)};
decode_lns_parts(_) ->
    error(invalid_lns).

%% ------------------------------------------------------------------
% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {setup, fun setup/0,
        {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
            ?_test(test_get_connection()),
            ?_test(test_dead_http_connection())
        ]}}.

setup() ->
    ok.

foreach_setup() ->
    ?MODULE:start_link(),
    ok.

foreach_cleanup(ok) ->
    ok = gen_server:stop(?MODULE),
    meck:unload(),
    ok.

test_get_connection() ->
    meck:new(grpc_client),

    Lns = <<"localhost:8080">>,
    Transport = tcp,
    Host = "localhost",
    Port = 8080,
    FakeGrpcConnection = fake_grpc_connection(),

    meck:expect(
        grpc_client,
        connect,
        [Transport, Host, Port, []],
        {ok, FakeGrpcConnection}
    ),

    % first get makes connection
    {ok, GrpcConnection0} = get_connection(Lns),
    ?assertEqual(1, meck:num_calls(grpc_client, connect, 4)),
    ?assertEqual(FakeGrpcConnection, GrpcConnection0),

    % second reservation doesn't reconnect and returns the same connection
    {ok, GrpcConnection1} = get_connection(Lns),
    ?assertEqual(FakeGrpcConnection, GrpcConnection1),
    ?assertEqual(1, meck:num_calls(grpc_client, connect, 4)).

test_dead_http_connection() ->
    meck:new(grpc_client),
    Lns = <<"localhost:8080">>,
    Transport = tcp,
    Host = "localhost",
    Port = 8080,
    FakeHttpConnectionPid0 = fake_http_connection_pid(),
    FakeGrpcConnection0 = fake_grpc_connection(FakeHttpConnectionPid0),

    meck:expect(
        grpc_client,
        connect,
        [Transport, Host, Port, []],
        {ok, FakeGrpcConnection0}
    ),

    {ok, GrpcConnection0} = get_connection(Lns),
    ?assertEqual(1, meck:num_calls(grpc_client, connect, 4)),

    % kill connection
    FakeHttpConnectionPid0 ! stop,

    ok = test_utils:wait_until(
        fun() ->
            State = sys:get_state(?MODULE),
            0 =:= maps:size(State#state.conns)
        end
    ),

    FakeHttpConnectionPid1 = fake_http_connection_pid(),
    FakeGrpcConnection1 = fake_grpc_connection(FakeHttpConnectionPid1),
    meck:expect(
        grpc_client,
        connect,
        [Transport, Host, Port, []],
        {ok, FakeGrpcConnection1}
    ),

    % second reservation doesn't reconnect and returns the same connection
    {ok, GrpcConnection1} = get_connection(Lns),
    ?assertNotEqual(GrpcConnection0, GrpcConnection1),
    ?assertEqual(2, meck:num_calls(grpc_client, connect, 4)).

% ------------------------------------------------------------------------------
% EUnit test utils
% ------------------------------------------------------------------------------

fake_grpc_connection() ->
    fake_grpc_connection(self()).

fake_grpc_connection(Pid) ->
    #{http_connection => Pid}.

fake_http_connection_pid() ->
    spawn(
        fun() ->
            receive
                stop ->
                    ok
            end
        end
    ).

-endif.
