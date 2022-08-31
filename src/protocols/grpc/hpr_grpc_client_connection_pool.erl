-module(hpr_grpc_client_connection_pool).

-behaviour(gen_server).

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

-spec reserve(Owner :: pid(), Lsn :: lns()) -> {ok, grpc_client:connection(), reservation_ref()}.
%% @doc Reserve a connection to grpc server identified by Lsn. Owner is the
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
    % [#connection{}]
    ets:new(connection, [named_table, set, {keypos, #connection.lns}]),
    % [#reserved_connection{}]
    ets:new(
        reserved_connection,
        [named_table, set, {keypos, #reserved_connection.reservation_ref}]
    ),
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
handle_info({timeout, Lsn}, State) ->
    ok = handle_timeout(Lsn),
    {noreply, State};
% Owner pid exits while holding reservation.
handle_info({{'DOWN', MonitorRef}, process, _Owner, _Info}, State) ->
    ok = handle_owner_exit(MonitorRef, State#state.idle_timeout),
    {noreply, State}.

% ------------------------------------------------------------------------------
% Private functions
% ------------------------------------------------------------------------------

-spec reserve_connection(pid(), lns(), endpoint()) ->
    {ok, grpc_client:connection(), reservation_ref()} | {error, any()}.
% If necessary, create connection, and update bookkeeping.
reserve_connection(Owner, Lns, Endpoint) ->
    MaybeConnection =
        case ets:lookup(conneciton, Lns) of
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

-spec release_connection(reference(), idle_timeout()) -> ok.
release_connection(ReservationRef, IdleTimeout) ->
    case ets:take(reserved_connection, ReservationRef) of
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
handle_timeout(Lsn) ->
    case ets:lookup(connection, Lsn) of
        [] ->
            ok;
        [ConnectionRecord] ->
            % possible race condition - timeout just as connection is reserved
            if
                ConnectionRecord#connection.reference_count == 0 ->
                    ets:delete(connection, Lsn),
                    ok = grpc_client:stop_connection(
                        ConnectionRecord#connection.connection
                    );
                true ->
                    ok
            end
    end.

-spec handle_owner_exit(monitor_ref(), idle_timeout()) -> ok.
handle_owner_exit(MonitorRef, IdleTimeout) ->
    % lookup reservation reference using monitor reference
    case
        ets:match_object(reserved_connection, #reserved_connection{
            monitor_ref = MonitorRef, _ = '_'
        })
    of
        [] ->
            ok;
        [ReservedConnectionRecord] ->
            ok = release_connection(
                ReservedConnectionRecord#reserved_connection.reservation_ref,
                IdleTimeout
            )
    end.

-spec maybe_start_idle_timer(
    Lsn :: lns(),
    IdleTimeout :: idle_timeout(),
    ReferenceCount :: non_neg_integer()
) -> ok.
% Start an idle timer if the connection reference count is 0
maybe_start_idle_timer(Lsn, IdleTimeout, 0) ->
    set_idle_timer(Lsn, IdleTimeout);
maybe_start_idle_timer(_Lsn, _, _) ->
    ok.

% returns new value
-spec connection_reference_count(lns(), integer()) -> integer().
connection_reference_count(Lns, Increment) ->
    ets:update_counter(
        connection,
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
    ets:insert(connection, #connection{
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
    timer:cancel(ConnectionRecord#connection.idle_timeout_timer_ref),
    ets:update_element(connection, ConnectionRecord#connection.lns, {
        #connection.idle_timeout_timer_ref, undefined
    }),
    ok.

-spec insert_reserved_connection(lns(), reservation_ref(), monitor_ref()) -> ok.
insert_reserved_connection(Lns, ReservationRef, MonitorRef) ->
    ets:insert(
        reserved_connection,
        #reserved_connection{
            reservation_ref = ReservationRef,
            lns = binary:copy(Lns),
            monitor_ref = MonitorRef
        }
    ),
    ok.

-spec set_idle_timer(lns(), idle_timeout()) -> ok.
set_idle_timer(_Lsn, infinity) ->
    ok;
set_idle_timer(Lsn, IdleTimeout) ->
    TimerRef = timer:send_after(IdleTimeout, {timeout, Lsn}),
    ets:update_element(
        connection,
        Lsn,
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
