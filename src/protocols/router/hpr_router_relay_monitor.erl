-module(hpr_router_relay_monitor).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start/3
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

-type process_name() :: relay | gateway_stream | router_stream.
-type relay() :: pid().
-type process_type() ::
    relay()
    | hpr_router_stream_manager:gateway_stream()
    | grpc_client:client_stream().
-type monitor_exit(Reason) ::
    normal
    | shutdown
    | {shutdown, any()}
    | {unexpected_exit, process_name(), process_type(), Reason}.

-record(state, {
    relay :: relay(),
    gateway_stream :: hpr_router_stream_manager:gateway_stream(),
    router_stream :: grpc_client:client_stream()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start(
    relay(),
    hpr_router_stream_manager:gateway_stream(),
    grpc_client:client_stream()
) -> {ok, pid()}.
%% @doc Start this service.
start(RelayPid, GatewayStream, RouterStream) ->
    gen_server:start(?MODULE, [RelayPid, GatewayStream, RouterStream], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

-spec init(list()) -> {ok, #state{}}.
init([Relay, GatewayStream, RouterStream]) ->
    % monitor Relay, GatewayStream and RouterStream to cleanup the communication
    % stack if one of the processes exits.
    % - If RouterStream exits:
    %       - stop relay
    %       - leave the GatewayStream intact. The GatewayStream is
    %         multiplexed to many RouterStreams.
    % - If GatewayStream exits:
    %       - stop relay
    %       - clean up the RouterStream because it no longer has a stream to
    %         reply to.
    % - If Relay exits:
    %       - clean up the RouterStream because it no longer has a way to
    %         communciate with the GatewayStream.
    monitor_process(gateway_stream, GatewayStream),
    monitor_process(router_stream, RouterStream),
    monitor_process(relay, Relay),
    {
        ok,
        #state{
            relay = Relay,
            gateway_stream = GatewayStream,
            router_stream = RouterStream
        }
    }.

-spec handle_call(
    Msg, {pid(), any()}, #state{}
) ->
    {stop, {unimplemented_call, Msg}, #state{}}.
handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

-spec handle_cast(Msg, #state{}) -> {stop, {unimplemented_cast, Msg}, #state{}}.
handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

-spec handle_info(
    {{'DOWN', process_name()}, reference(), process, process_type(), Reason},
    #state{}
) ->
    {stop, monitor_exit(Reason), #state{}}.
handle_info(
    {{'DOWN', router_stream}, _, process, RouterStream, Reason}, State
) ->
    stop_relay(State#state.relay),
    {stop, process_exit_status(router_stream, RouterStream, Reason), State};
handle_info(
    {{'DOWN', gateway_stream}, _, process, GatewayStream, Reason}, State
) ->
    grpc_client:stop_stream(State#state.router_stream),
    stop_relay(State#state.relay),
    {stop, process_exit_status(gateway_stream, GatewayStream, Reason), State};
handle_info({{'DOWN', relay}, _, process, RouterStream, Reason}, State) ->
    grpc_client:stop_stream(State#state.router_stream),
    {stop, process_exit_status(router_stream, RouterStream, Reason), State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec process_exit_status(
    process_name(), process_type(), Reason
) ->
    monitor_exit(Reason).
process_exit_status(_, _, normal = Status) ->
    Status;
process_exit_status(_, _, shutdown = Status) ->
    Status;
process_exit_status(_, _, {shutdown, _} = Status) ->
    Status;
process_exit_status(ProcessName, ProcessType, Reason) ->
    {unexpected_exit, ProcessName, ProcessType, Reason}.

-spec monitor_process(process_name(), process_type()) -> ok.
monitor_process(ProcessName, Process) ->
    erlang:monitor(process, Process, [{tag, {'DOWN', ProcessName}}]),
    ok.

-spec stop_relay(relay()) -> ok.
stop_relay(Relay) ->
    % brutal kill relay it is blocked waiting for data from the router.
    exit(Relay, kill),
    ok.

%% ------------------------------------------------------------------
% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        ?_test(test_relay_exit()),
        ?_test(test_gateway_exit()),
        ?_test(test_router_exit())
    ]}.

foreach_setup() ->
    ok.

foreach_cleanup(ok) ->
    meck:unload().

test_relay_exit() ->
    meck:new(grpc_client),
    Relay = fake_process(),
    GatewayStream = fake_process(),
    RouterStream = fake_process(),
    meck:expect(grpc_client, stop_stream, fun(Pid) -> kill_process(Pid) end),

    {ok, Monitor} = start(Relay, GatewayStream, RouterStream),

    kill_process(Relay),
    timer:sleep(10),

    ?assertNot(erlang:is_process_alive(Relay)),
    ?assert(erlang:is_process_alive(GatewayStream)),
    ?assertNot(erlang:is_process_alive(RouterStream)),
    ?assertNot(erlang:is_process_alive(Monitor)).

test_gateway_exit() ->
    meck:new(grpc_client),
    Relay = fake_process(),
    GatewayStream = fake_process(),
    RouterStream = fake_process(),
    meck:expect(grpc_client, stop_stream, fun(Pid) -> kill_process(Pid) end),

    {ok, Monitor} = start(Relay, GatewayStream, RouterStream),

    kill_process(GatewayStream),
    timer:sleep(10),

    ?assertNot(erlang:is_process_alive(Relay)),
    ?assertNot(erlang:is_process_alive(GatewayStream)),
    ?assertNot(erlang:is_process_alive(RouterStream)),
    ?assertNot(erlang:is_process_alive(Monitor)).

test_router_exit() ->
    Relay = fake_process(),
    GatewayStream = fake_process(),
    RouterStream = fake_process(),

    {ok, Monitor} = start(Relay, GatewayStream, RouterStream),

    kill_process(RouterStream),
    timer:sleep(10),

    ?assertNot(erlang:is_process_alive(Relay)),
    ?assert(erlang:is_process_alive(GatewayStream)),
    ?assertNot(erlang:is_process_alive(RouterStream)),
    ?assertNot(erlang:is_process_alive(Monitor)).

%% ------------------------------------------------------------------
% EUnit private functions
%% ------------------------------------------------------------------

fake_process() ->
    spawn(
        fun() ->
            receive
                {stop, Reason} ->
                    exit(Reason)
            end
        end
    ).

kill_process(Pid) ->
    Pid ! {stop, normal}.

-endif.
