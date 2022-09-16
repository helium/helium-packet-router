-module(hpr_router_connection_manager).

-behaviour(gen_server).

-define(CONNECTION_TAB, connection).

% API
-export([
    start_link/0,
    get_connection/1
]).

% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2
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

% ------------------------------------------------------------------------------
% API
% ------------------------------------------------------------------------------

-spec start_link() -> {ok, pid()}.
%% @doc Start this service.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_connection(Lns :: lns()) -> {ok, grpc_client:connection()} | {error, any()}.
%% @doc Return an existing connection to the Router at Lns, or create a
%% new connection if one doesn't exist.
get_connection(Lns) ->
    DecodedLns = decode_lns(Lns),
    gen_server:call(?MODULE, {get_connection, Lns, DecodedLns}).

% ------------------------------------------------------------------------------
% gen_server callbacks
% ------------------------------------------------------------------------------

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

% ------------------------------------------------------------------------------
% Private functions
% ------------------------------------------------------------------------------

-spec init_ets() -> ets:tab().
init_ets() ->
    init_ets([]).

-spec init_ets(list()) -> ets:tab().
init_ets(Options) ->
    % [#connection{}]
    ets:new(
        connection,
        Options ++ [set, {keypos, #connection.lns}]
    ).

-spec do_get_connection(lns(), endpoint(), ets:tab()) ->
    {ok, grpc_client:connection()} | {error, any()}.
% If necessary, create connection.
do_get_connection(Lns, Endpoint, ConnectionTab) ->
    case ets:lookup(ConnectionTab, Lns) of
        [] ->
            insert_connection(ConnectionTab, Lns, grpc_client_connect(Endpoint));
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

% ------------------------------------------------------------------------------
% Unit tests
% ------------------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {setup, fun setup/0,
        {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
            ?_test(test_get_connection())
        ]}}.

setup() ->
    init_ets([named_table, public]).

foreach_setup() ->
    meck:new(grpc_client),
    ok.

foreach_cleanup(ok) ->
    meck:unload(grpc_client),
    ok.

test_get_connection() ->
    Lns = <<"lns">>,
    Transport = tcp,
    Host = <<"1,2,3,4">>,
    Port = 1234,
    Endpoint = {Transport, Host, Port},
    FakeGrcpConnection = #{fake => connection},

    meck:expect(
        grpc_client,
        connect,
        [Transport, Host, Port, []],
        {ok, FakeGrcpConnection}
    ),

    % first get  makes connection
    {ok, GrpcConnection0} =
        do_get_connection(Lns, Endpoint, connection),
    ?assertEqual(1, meck:num_calls(grpc_client, connect, 4)),
    ?assertEqual(FakeGrcpConnection, GrpcConnection0),

    % second reservation doesn't reconnect and returns the same connection
    {ok, GrpcConnection1} =
        do_get_connection(Lns, Endpoint, connection),
    ?assertEqual(FakeGrcpConnection, GrpcConnection1),
    ?assertEqual(1, meck:num_calls(grpc_client, connect, 4)).

% ------------------------------------------------------------------------------
% Unit test utils
% ------------------------------------------------------------------------------

-endif.
