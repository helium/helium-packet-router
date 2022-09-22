-module(hpr_router_relay).

-behaviour(gen_server).

% API
-export([
    start/2
]).

% gen_server callbacks
-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-type stream_name() :: gateway_stream | router_stream.
-type stream() :: hpr_router_stream_manager:gateway_stream() | grpc_client:client_stream().

-record(state, {
    gateway_stream :: hpr_router_stream_manager:gateway_stream(),
    router_stream :: grpc_client:client_stream()
}).

% ------------------------------------------------------------------------------
% API
% ------------------------------------------------------------------------------

-spec start(hpr_router_stream_manager:gateway_stream(), grpc_client:client_stream()) -> {ok, pid()}.
%% @doc Start this service.
start(GatewayStream, RouterStream) ->
    gen_server:start(?MODULE, [GatewayStream, RouterStream], []).

% ------------------------------------------------------------------------------
% gen_server callbacks
% ------------------------------------------------------------------------------

-spec init(list()) -> {ok, #state{}, {continue, relay}}.
init([GatewayStream, RouterStream]) ->
    % monitor GatewayStream and RouterStream to cleanup the communication
    % stack if one end or the other exits.
    % - If RouterStream exits, clean up the relay but leave the GatewayStream
    %   intact. The GatewayStream is multiplexed to many RouterStreams.
    % - If GatewayStream exits, clean up the RouterStream because it no longer
    %   has a stream to reply to.
    monitor_stream(gateway_stream, GatewayStream),
    monitor_stream(router_stream, RouterStream),
    {
        ok,
        #state{
            gateway_stream = GatewayStream,
            router_stream = RouterStream
        },
        {continue, relay}
    }.

-spec handle_continue(relay, #state{}) -> {noreply, #state{}, {continue, relay}}.
handle_continue(relay, State) ->
io:format("rcv~n"),
    handle_rcv_response(grpc_client:rcv(State#state.router_stream), State).

-spec handle_call(Msg, {pid(), any()}, #state{}) -> {stop, {unimplemented_call, Msg}, #state{}}.
handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

-spec handle_cast(Msg, #state{}) -> {stop, {unimplemented_cast, Msg}, #state{}}.
handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

-spec handle_info({{'DOWN', stream_name()}, reference(), process, pid(), Reason}, #state{}) ->
    {stop, {stream_exit, pid(), Reason}, #state{}}.
handle_info({{'DOWN', gateway_stream}, _, process, GatewayStream, Reason}, State) ->
    grpc_client:stop_stream(State#state.router_stream),
    {stop, stream_exit_status(gateway_stream, GatewayStream, Reason), State};
handle_info({{'DOWN', router_stream}, _, process, RouterStream, Reason}, State) ->
    {stop, stream_exit_status(router_stream, RouterStream, Reason), State}.

% ------------------------------------------------------------------------------
% Private functions
% ------------------------------------------------------------------------------

-spec stream_exit_status(stream_name(), stream(), any()) ->
    normal | {stream_exit, stream_name(), stream(), any()}.
stream_exit_status(_, _, normal) ->
    normal;
stream_exit_status(StreamName, Stream, Reason) ->
    {stream_exit, StreamName, Stream, Reason}.

-spec monitor_stream(stream_name(), stream()) -> ok.
monitor_stream(StreamName, Stream) ->
    erlang:monitor(process, Stream, [{tag, {'DOWN', StreamName}}]),
    ok.

-spec handle_rcv_response(grpc_client:rcv_response(), #state{}) ->
    {noreply, #state{}, {continue, relay}}
    | {stop, {error, any()}, #state{}}.
handle_rcv_response({data, Reply}, State) ->
    State#state.gateway_stream ! {router_reply, Reply},
    {noreply, State, {continue, relay}};
handle_rcv_response({headers, _}, State) ->
    {noreply, State, {continue, relay}};
handle_rcv_response(eof, State) ->
    grpc_client:stop_stream(State#state.router_stream),
    {stop, normal, State};
handle_rcv_response({error, _} = Error, State) ->
    {stop, Error, State}.

% ------------------------------------------------------------------------------
% Unit tests
% ------------------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        ?_test(test_relay_data()),
        ?_test(test_relay_headers()),
        ?_test(test_relay_eof()),
        ?_test(test_relay_error())
    ]}.

foreach_setup() ->
    ok.

foreach_cleanup(ok) ->
    meck:unload().

test_relay_data() ->
    meck:new(grpc_client),
    State = state(),
    meck:expect(grpc_client, rcv, [State#state.router_stream], {data, fake_data()}),
    Reply = handle_continue(relay, State),
    ?assertEqual({noreply, State, {continue, relay}}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    RelayMessage = receive_relay(),
    ?assertEqual(fake_data(), RelayMessage).

test_relay_headers() ->
    meck:new(grpc_client),
    State = state(),
    meck:expect(grpc_client, rcv, [State#state.router_stream], {headers, #{fake => headers}}),
    Reply = handle_continue(relay, State),
    ?assertEqual({noreply, State, {continue, relay}}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    ?assertEqual(empty, check_messages()).

test_relay_eof() ->
    meck:new(grpc_client),
    State = state(),
    meck:expect(grpc_client, rcv, [State#state.router_stream], eof),
    Reply = handle_continue(relay, State),
    ?assertEqual({stop, normal, State}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    ?assertEqual(empty, check_messages()).

test_relay_error() ->
    meck:new(grpc_client),
    State = state(),
    Error = {error, fake_error},
    meck:expect(grpc_client, rcv, [State#state.router_stream], Error),
    Reply = handle_continue(relay, State),
    ?assertEqual({stop, Error, State}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    ?assertEqual(empty, check_messages()).

% ------------------------------------------------------------------------------
% Unit test utils
% ------------------------------------------------------------------------------

fake_data() ->
    #{fake => data}.

fake_stream() ->
    Self = self(),
    spawn(
        fun Loop() ->
            monitor(process, Self),
            receive
                {'DOWN', _, process, Self, _} ->
                    ok;
                {router_reply, _} = Reply ->
                    Self ! Reply,
                    Loop();
                Msg ->
                    % sanity check on pattern matches
                    exit({unexpected_message, Msg})
            end
        end
    ).

receive_relay() ->
    receive
        {router_reply, Message} ->
            Message
    after 50 ->
        timeout
    end.

check_messages() ->
    receive
        Msg -> Msg
    after 0 ->
        empty
    end.

state() ->
    #state{
        gateway_stream = fake_stream(),
        router_stream = fake_stream()
    }.

-endif.
