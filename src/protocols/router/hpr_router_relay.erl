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
    % link to GatewayStream and RouterStream to stop the communication
    % stack if one of the components fails.
    % XXX use monitor to handle 'normal' exits?
    erlang:process_flag(trap_exit, true),
    erlang:link(GatewayStream),
    erlang:link(RouterStream),
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
    handle_rcv_response(grpc_client:rcv(State#state.router_stream), State).

-spec handle_call(Msg, {pid(), any()}, #state{}) -> {stop, {unimplemented_call, Msg}, #state{}}.
handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

-spec handle_cast(Msg, #state{}) -> {stop, {unimplemented_cast, Msg}, #state{}}.
handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

-spec handle_info({'EXIT', pid(), Reason}, #state{}) ->
    {stop, {stream_exit, pid(), Reason}, #state{}}.
handle_info({'EXIT', FromPid, Reason}, State) ->
    {stop, {stream_exit, FromPid, Reason}, State}.

% ------------------------------------------------------------------------------
% Private functions
% ------------------------------------------------------------------------------

-spec handle_rcv_response(grpc_client:rcv_response(), #state{}) ->
    {noreply, #state{}, {continue, relay}}
    | {stop, {error, any()}, #state{}}.
handle_rcv_response({data, Reply}, State) ->
    State#state.gateway_stream ! {router_reply, Reply},
    {noreply, State, {continue, relay}};
handle_rcv_response({headers, _}, State) ->
    {noreply, State, {continue, relay}};
handle_rcv_response(eof, State) ->
    {stop, {error, eof}, State};
handle_rcv_response({error, _} = Error, State) ->
    {stop, Error, State};
handle_rcv_response(stop, State) ->
    % only used for testing: see hpr_protocol_router_SUITE
    {stop, normal, State}.

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
    meck:new(grpc_client),
    ok.

foreach_cleanup(ok) ->
    meck:unload(grpc_client).

test_relay_data() ->
    State = state(),
    meck:expect(grpc_client, rcv, [State#state.router_stream], {data, fake_data()}),
    Reply = handle_continue(relay, State),
    ?assertEqual({noreply, State, {continue, relay}}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    RelayMessage = receive_relay(),
    ?assertEqual(fake_data(), RelayMessage).

test_relay_headers() ->
    State = state(),
    meck:expect(grpc_client, rcv, [State#state.router_stream], {headers, #{fake => headers}}),
    Reply = handle_continue(relay, State),
    ?assertEqual({noreply, State, {continue, relay}}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    ?assertEqual(empty, check_messages()).

test_relay_eof() ->
    State = state(),
    meck:expect(grpc_client, rcv, [State#state.router_stream], eof),
    Reply = handle_continue(relay, State),
    ?assertEqual({stop, {error, eof}, State}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    ?assertEqual(empty, check_messages()).

test_relay_error() ->
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
