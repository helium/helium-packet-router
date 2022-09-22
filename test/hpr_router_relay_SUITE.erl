-module(hpr_router_relay_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    relay_test/1,
    gateway_exits_test/1
]).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        relay_test,
        gateway_exits_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(_TestCase, Config) ->
    Config.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, _Config) ->
    meck:unload().

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

relay_test(_Config) ->
    GatewayStream = fake_gateway_stream(self()),
    RouterStream = fake_stream(),
    FakeData = <<"fake data">>,

    meck:expect(
        grpc_client,
        rcv,
        [RouterStream],
        meck:seq([{data, FakeData}, eof])
    ),
    meck:expect(
        grpc_client,
        stop_stream,
        [RouterStream],
        fun(Stream) -> Stream ! stop, ok end
    ),

    {ok, RelayPid} = hpr_router_relay:start(GatewayStream, RouterStream),

    ?assertEqual(2, meck:num_calls(grpc_client, rcv, 1)),
    ?assertEqual(1, meck:num_calls(grpc_client, stop_stream, 1)),

    timer:sleep(50),
    Data = receive_next(),
    ?assertEqual({router_reply, FakeData}, Data),
    ?assertNot(erlang:is_process_alive(RelayPid)),
    ?assert(erlang:is_process_alive(GatewayStream)),
    ?assertNot(erlang:is_process_alive(RouterStream)).

gateway_exits_test(_Config) ->
    GatewayStream = fake_stream(),
    RouterStream = fake_stream(),

    meck:expect(
        grpc_client,
        rcv,
        [RouterStream],
        fun(_) -> wait_for_stop() end
    ),
    meck:expect(
        grpc_client,
        stop_stream,
        [RouterStream],
        fun(Stream) -> Stream ! stop, ok end
    ),

    {ok, RelayPid} = hpr_router_relay:start(GatewayStream, RouterStream),
    link(RelayPid),

    RelayPid ! bad_message,

    GatewayStream ! stop,

    timer:sleep(50),
    ?assertEqual(1, meck:num_calls(grpc_client, stop_stream, 1)),
    ?assertNot(erlang:is_process_alive(GatewayStream)),
    ?assertNot(erlang:is_process_alive(RelayPid)),
    ?assertNot(erlang:is_process_alive(RouterStream)).
    

%% ===================================================================
%% Helpers
%% ===================================================================

fake_stream() ->
    spawn(fun() -> wait_for_stop() end).

fake_gateway_stream(Receiver) ->
    spawn(
        fun() ->
            Receiver ! receive_next(),
            wait_for_stop()
        end
    ).

receive_next() ->
    receive
        Msg ->
            Msg
    after 50 ->
        no_data
    end.

wait_for_stop() ->
    receive
        stop ->
            ok
    end.
