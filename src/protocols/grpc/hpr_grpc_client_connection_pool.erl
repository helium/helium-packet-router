-module(hpr_grpc_client_connection_pool).

-behaviour(gen_server).

-define(CONNECTION_TAB, connection).
-define(RESERVED_CONNECTION_TAB, reserved_connection).

% API
-export([
    reserve/2,
    release/1,
    start_link/1
]).

% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-type reservation_ref() :: reference().
-type monitor_ref() :: reference().
-type lns() :: binary().
-type endpoint() :: {tcp | ssl, string(), non_neg_integer()}.
-type idle_timeout() :: infinity | non_neg_integer().
-type from() :: {pid(), any()}.

-export_type([
    reservation_ref/0,
    idle_timeout/0
]).

-record(state, {
    % idle timeout for connection in milliseconds
    idle_timeout :: idle_timeout()
}).

-record(connection, {
    lns :: lns(),
    connection :: grpc_client:connection(),
    reference_count = 0 :: non_neg_integer(),
    idle_timeout_timer_ref = undefined :: undefined | timer:tref()
}).

-record(reserved_connection, {
    reservation_ref :: '_' | reservation_ref(),
    lns :: '_' | lns(),
    monitor_ref :: monitor_ref()
}).

% ------------------------------------------------------------------------------
% API
% ------------------------------------------------------------------------------

-spec reserve(Owner :: pid(), Lns :: lns()) -> {ok, grpc_client:connection(), reservation_ref()}.
%% @doc Reserve a connection to grpc server identified by Lns. Owner is the
%% pid that owns the reservation.
reserve(Owner, Lns) ->
    DecodedLns = decode_lns(Lns),
    gen_server:call(?MODULE, {reserve, Owner, Lns, DecodedLns}).

-spec release(reservation_ref()) -> ok.
%% @doc Release a reservation.
release(ReservationRef) ->
    gen_server:cast(?MODULE, {release, ReservationRef}).

-spec start_link(idle_timeout()) -> {ok, pid()}.
%% @doc Start this service.
start_link(IdleTimeout) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [IdleTimeout], []).

% ------------------------------------------------------------------------------
% gen_server callbacks
% ------------------------------------------------------------------------------

-spec init([idle_timeout()]) -> {ok, #state{}}.
init([IdleTimeout]) ->
    init_ets(),
    {
        ok,
        #state{
            idle_timeout = IdleTimeout
        }
    }.

-spec handle_call({reserve, pid(), lns(), endpoint()}, from(), #state{}) ->
    {reply, {ok, grpc_client:connection()} | {error, any()}, #state{}}.
handle_call({reserve, Owner, Lns, Endpoint}, _From, State) ->
    {reply, reserve_connection(Owner, Lns, Endpoint), State}.

-spec handle_cast({release, reservation_ref()}, #state{}) ->
    {noreply, #state{}}.
handle_cast({release, ReservationRef}, State) ->
    release_connection(ReservationRef, State#state.idle_timeout),
    {noreply, State}.

-spec handle_info
    ({timeout, lns()}, #state{}) -> {noreply, #state{}};
    ({{'DOWN', reference()}, process, pid(), any()}, #state{}) ->
        {noreply, #state{}}.
% Connection idle timeout.
handle_info({timeout, Lns}, State) ->
    ok = handle_timeout(Lns),
    {noreply, State};
% Owner pid exits while holding reservation.
handle_info({{'DOWN', ReservaionRef}, _MonitorRef, process, _Owner, _Info}, State) ->
    ok = release_connection(ReservaionRef, State#state.idle_timeout),
    {noreply, State}.

% ------------------------------------------------------------------------------
% Private functions
% ------------------------------------------------------------------------------

-spec init_ets() -> ok.
init_ets() ->
    init_ets([]).

-spec init_ets(list()) -> ok.
init_ets(Options) ->
    % [#connection{}]
    ets:new(
        ?CONNECTION_TAB,
        Options ++ [named_table, set, {keypos, #connection.lns}]
    ),
    % [#reserved_connection{}]
    ets:new(
        ?RESERVED_CONNECTION_TAB,
        Options ++
            [named_table, set, {keypos, #reserved_connection.reservation_ref}]
    ),
    ok.

-spec reserve_connection(pid(), lns(), endpoint()) ->
    {ok, grpc_client:connection(), reservation_ref()} | {error, any()}.
% If necessary, create connection, and update bookkeeping.
reserve_connection(Owner, Lns, Endpoint) ->
    MaybeConnection =
        case ets:lookup(?CONNECTION_TAB, Lns) of
            [] ->
                insert_connection(Lns, grpc_client_connect(Endpoint));
            [ConnectionRecord] ->
                cancel_idle_timer(ConnectionRecord),
                {ok, ConnectionRecord#connection.connection}
        end,
    finish_reservation(Owner, Lns, MaybeConnection).

-spec finish_reservation
    (pid(), lns(), {ok, grpc_client:connection()}) ->
        {ok, grpc_client:connection(), reservation_ref()};
    (pid(), lns(), {error, any()}) -> {error, any()}.

finish_reservation(Owner, Lns, {ok, Connection}) ->
    ReservationRef = make_ref(),
    MonitorRef = monitor_owner(Owner, ReservationRef),
    ok = insert_reserved_connection(Lns, ReservationRef, MonitorRef),
    connection_reference_count(Lns, 1),
    {ok, Connection, ReservationRef};
finish_reservation(_, _, {error, Error}) ->
    {error, Error}.

-spec release_connection(reservation_ref(), idle_timeout()) -> ok.
release_connection(ReservationRef, IdleTimeout) ->
    case ets:take(?RESERVED_CONNECTION_TAB, ReservationRef) of
        [] ->
            % released more than once
            ok;
        [ReservedConnectionRecord] ->
            % start idle timer if connection reference count is 0
            ok = demonitor_owner(
                ReservedConnectionRecord#reserved_connection.monitor_ref
            ),
            maybe_start_idle_timer(
                ReservedConnectionRecord#reserved_connection.lns,
                IdleTimeout,
                connection_reference_count(
                    ReservedConnectionRecord#reserved_connection.lns, -1
                )
            ),
            ok
    end.

-spec handle_timeout(lns()) -> ok.
handle_timeout(Lns) ->
    case ets:lookup(?CONNECTION_TAB, Lns) of
        [] ->
            ok;
        [ConnectionRecord] ->
            % possible race condition - timeout just as connection is reserved
            if
                ConnectionRecord#connection.reference_count == 0 ->
                    ets:delete(?CONNECTION_TAB, Lns),
                    ok = grpc_client:stop_connection(
                        ConnectionRecord#connection.connection
                    );
                true ->
                    ok
            end
    end.

-spec maybe_start_idle_timer(
    Lns :: lns(),
    IdleTimeout :: idle_timeout(),
    ReferenceCount :: non_neg_integer()
) -> ok.
% Start an idle timer if the connection reference count is 0
maybe_start_idle_timer(Lns, IdleTimeout, 0) ->
    set_idle_timer(Lns, IdleTimeout);
maybe_start_idle_timer(_Lns, _, _) ->
    ok.

% returns new value
-spec connection_reference_count(lns(), integer()) -> integer().
connection_reference_count(Lns, Increment) ->
    ets:update_counter(
        ?CONNECTION_TAB,
        Lns,
        {#connection.reference_count, Increment}
    ).

-spec grpc_client_connect(endpoint()) ->
    {ok, grpc_client:connection()} | {error, any()}.
grpc_client_connect({Transport, Host, Port}) ->
    grpc_client:connect(Transport, Host, Port, []).

-spec insert_connection
    (lns(), {ok, grpc_client:connection()}) -> {ok, grpc_client:connection()};
    (lns(), {error, any()}) -> {error, any()}.
insert_connection(Lns, {ok, GrpcClientConnection}) ->
    ets:insert(?CONNECTION_TAB, #connection{
        lns = binary:copy(Lns),
        connection = GrpcClientConnection
    }),
    {ok, GrpcClientConnection};
insert_connection(_, {error, Error}) ->
    {error, Error}.

-spec cancel_idle_timer(#connection{}) -> ok.
cancel_idle_timer(#connection{idle_timeout_timer_ref = undefined}) ->
    ok;
cancel_idle_timer(ConnectionRecord) ->
    {ok, cancel} =
        timer:cancel(ConnectionRecord#connection.idle_timeout_timer_ref),
    ets:update_element(?CONNECTION_TAB, ConnectionRecord#connection.lns, {
        #connection.idle_timeout_timer_ref, undefined
    }),
    ok.

-spec insert_reserved_connection(lns(), reservation_ref(), monitor_ref()) -> ok.
insert_reserved_connection(Lns, ReservationRef, MonitorRef) ->
    ets:insert(
        ?RESERVED_CONNECTION_TAB,
        #reserved_connection{
            reservation_ref = ReservationRef,
            lns = binary:copy(Lns),
            monitor_ref = MonitorRef
        }
    ),
    ok.

-spec set_idle_timer(lns(), idle_timeout()) -> ok.
set_idle_timer(_Lns, infinity) ->
    ok;
set_idle_timer(Lns, IdleTimeout) ->
    {ok, TimerRef} = timer:send_after(IdleTimeout, {timeout, Lns}),
    ets:update_element(
        ?CONNECTION_TAB,
        Lns,
        {#connection.idle_timeout_timer_ref, TimerRef}
    ),
    ok.

-spec monitor_owner(pid(), reservation_ref()) -> monitor_ref().
monitor_owner(Owner, ReservationRef) ->
    erlang:monitor(process, Owner, [{tag, {'DOWN', ReservationRef}}]).

-spec demonitor_owner(monitor_ref()) -> ok.
demonitor_owner(MonitorRef) ->
    erlang:demonitor(MonitorRef),
    ok.

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
            ?_test(test_reservation()),
            ?_test(test_owner_normal_exit()),
            ?_test(test_owner_crash())
        ]}}.

setup() ->
    init_ets([public]),
    ok.

foreach_setup() ->
    meck:new(grpc_client),
    ok.

foreach_cleanup(ok) ->
    meck:unload(grpc_client),
    ok.

test_reservation() ->
    Owner = self(),
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
    meck:expect(
        grpc_client,
        stop_connection,
        [FakeGrcpConnection],
        ok
    ),

    % reservation makes connection
    {ok, GrpcConnection0, ReservationRef0} =
        reserve_connection(Owner, Lns, Endpoint),
    ?assertEqual(FakeGrcpConnection, GrpcConnection0),

    % second reservation doesn't reconnect and returns a unique
    % reservation id
    {ok, GrpcConnection1, ReservationRef1} =
        reserve_connection(Owner, Lns, Endpoint),
    ?assertEqual(FakeGrcpConnection, GrpcConnection1),
    ?assertNotEqual(ReservationRef0, ReservationRef1),
    ?assertEqual(1, meck:num_calls(grpc_client, connect, 4)),

    % first release doesn't stop connection
    ok = release_connection(ReservationRef1, 50),
    ?assertEqual(0, meck:num_calls(grpc_client, stop_connection, 1)),

    % second release of same reservation is not an error and doesn't
    % stop the connection
    ok = release_connection(ReservationRef1, 50),
    ?assertEqual(0, meck:num_calls(grpc_client, stop_connection, 1)),

    % releasing last reservation doesn't immediately stop connection
    ok = release_connection(ReservationRef0, 50),
    ?assertEqual(0, meck:num_calls(grpc_client, stop_connection, 1)),

    % new reservation doesn't cause connection
    {ok, GrpcConnection2, ReservationRef2} =
        reserve_connection(Owner, Lns, Endpoint),
    ?assertEqual(FakeGrcpConnection, GrpcConnection2),
    ?assertNotEqual(ReservationRef0, ReservationRef2),
    ?assertEqual(1, meck:num_calls(grpc_client, connect, 4)),
    ?assertEqual(0, meck:num_calls(grpc_client, stop_connection, 1)),

    % make sure there were no stray messages
    ?assertEqual([], purge_mailbox()),

    % releasing connection causes idle timeout that releases the connection
    ok = release_connection(ReservationRef2, 50),
    receive
        {timeout, Lns1} ->
            ?assertEqual(Lns, Lns1)
    after 100 ->
        ?assert(false == timeout)
    end,
    ok = handle_timeout(Lns),
    ?assertEqual(1, meck:num_calls(grpc_client, stop_connection, 1)).

test_owner_normal_exit() ->
    Owner = spawn(fake_owner_(fun() -> ok end)),
    test_owner_exit(Owner).

test_owner_crash() ->
    Owner = spawn(fake_owner_(fun() -> exit(abnormal) end)),
    test_owner_exit(Owner).

% ------------------------------------------------------------------------------
% Unit test utils
% ------------------------------------------------------------------------------

test_owner_exit(Owner) ->
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
    meck:expect(
        grpc_client,
        stop_connection,
        [FakeGrcpConnection],
        ok
    ),

    % connection released automatically when owner exits
    {ok, _GrpcConnection, _ReservationRef} =
        reserve_connection(Owner, Lns, Endpoint),
    ?assertEqual(1, meck:num_calls(grpc_client, connect, 4)),
    Owner ! stop,
    receive
        {{'DOWN', ReservationRef}, _, process, Owner1, _} ->
            ?assertEqual(Owner, Owner1),
            ok = release_connection(ReservationRef, 50)
    after 100 ->
        ?assert(false == owner_down)
    end,
    receive
        {timeout, Lns1} ->
            ?assertEqual(Lns, Lns1)
    after 100 ->
        ?assert(false == timeout)
    end,
    ok = handle_timeout(Lns),
    ?assertEqual(1, meck:num_calls(grpc_client, stop_connection, 1)).

% fun for fake owner process
fake_owner_(StopFun) ->
    fun() ->
        receive
            stop ->
                StopFun()
        end
    end.

% return messages in mailbox
purge_mailbox() ->
    receive
        Message ->
            [Message | purge_mailbox()]
    after 0 ->
        []
    end.

-endif.
