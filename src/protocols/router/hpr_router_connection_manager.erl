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
    handle_info/2
]).

-type lns() :: binary().
-type endpoint() :: {tcp | ssl, string(), non_neg_integer()}.
-type from() :: {pid(), any()}.

-record(state, {
    connection_table :: ets:tab()
}).

-record(connection, {
    lns :: lns(),
    connection :: grpc_client:connection()
}).

-define(CONNECTION_TAB, hpr_router_connection_manager_tab).

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
    DecodedLns = decode_lns(Lns),
    gen_server:call(?MODULE, {get_connection, Lns, DecodedLns}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

-spec init([]) -> {ok, #state{}}.
init([]) ->
    Tab = init_ets(),
    {
        ok,
        #state{
            connection_table = Tab
        }
    }.

-spec handle_call({get_connection, lns(), endpoint()}, from(), #state{}) ->
    {reply, {ok, grpc_client:connection()} | {error, any()}, #state{}}.
handle_call({get_connection, Lns, Endpoint}, _From, State) ->
    {reply, do_get_connection(Lns, Endpoint, State#state.connection_table), State}.

-spec handle_cast(Msg, #state{}) -> {stop, {unimplemented_cast, Msg}, #state{}}.
handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

-spec handle_info({{'DOWN', lns()}, reference(), process, pid(), any()}, #state{}) ->
    {noreply, #state{}}.
handle_info({{'DOWN', Lns}, _Mon, process, _Pid, _ExitReason}, State) ->
    ets:delete(State#state.connection_table, Lns),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec init_ets() -> ets:tab().
init_ets() ->
    init_ets([]).

-spec init_ets(list()) -> ets:tab().
init_ets(Options) ->
    % [#connection{}]
    ets:new(
        ?CONNECTION_TAB,
        Options ++ [set, {keypos, #connection.lns}]
    ).

-spec do_get_connection(lns(), endpoint(), ets:tab()) ->
    {ok, grpc_client:connection()} | {error, any()}.
% If necessary, create connection.
do_get_connection(Lns, Endpoint, ConnectionTab) ->
    case ets:lookup(ConnectionTab, Lns) of
        [] ->
            GrpcConnection = grpc_client_connect(Endpoint),
            monitor_grpc_client_connection(Lns, GrpcConnection),
            insert_connection(ConnectionTab, Lns, GrpcConnection);
        [ConnectionRecord] ->
            %% TODO: Handle the connection being dead
            {ok, ConnectionRecord#connection.connection}
    end.

-spec grpc_client_connect(endpoint()) ->
    {ok, grpc_client:connection()} | {error, any()}.
grpc_client_connect({Transport, Host, Port}) ->
    grpc_client:connect(Transport, Host, Port, []).

-spec insert_connection
    (ets:tab(), lns(), {ok, grpc_client:connection()}) -> {ok, grpc_client:connection()};
    (ets:tab(), lns(), {error, any()}) -> {error, any()}.
insert_connection(ConnectionTab, Lns, {ok, GrpcClientConnection}) ->
    ets:insert(ConnectionTab, #connection{
        lns = binary:copy(Lns),
        connection = GrpcClientConnection
    }),
    {ok, GrpcClientConnection};
insert_connection(_, _, {error, Error}) ->
    {error, Error}.

-spec decode_lns(lns()) -> endpoint().
decode_lns(Lns) ->
    {Address, Port} = decode_lns_parts(binary:split(Lns, <<$:>>)),
    {tcp, Address, Port}.

-spec decode_lns_parts([binary()]) -> {string(), non_neg_integer()} | none().
decode_lns_parts([Address, Port]) ->
    {erlang:binary_to_list(Address), erlang:binary_to_integer(Port)};
decode_lns_parts(_) ->
    error(invalid_lns).

-spec monitor_grpc_client_connection
    (lns(), {ok, grpc_client:connection()}) -> ok;
    (lns(), {error, any()}) -> ok.
% monitor the http process in the grpc_client connection. Include the Lns in
% 'DOWN' message tag to make it easier to locate the connection in ets.
monitor_grpc_client_connection(Lns, {ok, GrpcConnection}) ->
    #{http_connection := HttpPid} = GrpcConnection,
    erlang:monitor(process, HttpPid, [{tag, {'DOWN', Lns}}]),
    ok;
monitor_grpc_client_connection(_, {error, _}) ->
    ok.

% ------------------------------------------------------------------------------
% Unit tests
% ------------------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {setup, fun setup/0,
        {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
            ?_test(test_get_connection()),
            ?_test(test_dead_http_connection())
        ]}}.

setup() ->
    init_ets([named_table, public]).

foreach_setup() ->
    reset_ets(),
    ok.

foreach_cleanup(ok) ->
    meck:unload(),
    ok.

test_get_connection() ->
    meck:new(grpc_client),
    Lns = <<"lns">>,
    Transport = tcp,
    Host = <<"1,2,3,4">>,
    Port = 1234,
    Endpoint = {Transport, Host, Port},
    FakeGrpcConnection = fake_grpc_connection(),

    meck:expect(
        grpc_client,
        connect,
        [Transport, Host, Port, []],
        {ok, FakeGrpcConnection}
    ),

    % first get makes connection
    {ok, GrpcConnection0} =
        do_get_connection(Lns, Endpoint, ?CONNECTION_TAB),
    ?assertEqual(1, meck:num_calls(grpc_client, connect, 4)),
    ?assertEqual(FakeGrpcConnection, GrpcConnection0),

    % second reservation doesn't reconnect and returns the same connection
    {ok, GrpcConnection1} =
        do_get_connection(Lns, Endpoint, ?CONNECTION_TAB),
    ?assertEqual(FakeGrpcConnection, GrpcConnection1),
    ?assertEqual(1, meck:num_calls(grpc_client, connect, 4)).

test_dead_http_connection() ->
    meck:new(grpc_client),
    Lns = <<"lns">>,
    Transport = tcp,
    Host = <<"1,2,3,4">>,
    Port = 1234,
    Endpoint = {Transport, Host, Port},
    FakeHttpConnectionPid = fake_http_connection_pid(),
    FakeGrpcConnection = fake_grpc_connection(FakeHttpConnectionPid),

    meck:expect(
        grpc_client,
        connect,
        [Transport, Host, Port, []],
        {ok, FakeGrpcConnection}
    ),

    {ok, _} =
        do_get_connection(Lns, Endpoint, ?CONNECTION_TAB),
    ?assertEqual(1, meck:num_calls(grpc_client, connect, 4)),

    % kill connection
    FakeHttpConnectionPid ! stop,
    Msg =
        receive
            M -> M
        after 50 -> timeout
        end,
    ?assertMatch({{'DOWN', Lns}, _Mon, process, _Pid, _ExitReason}, Msg).

% ------------------------------------------------------------------------------
% Unit test utils
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

reset_ets() ->
    ets:delete_all_objects(?CONNECTION_TAB).

-endif.
