-module(hpr_grpc_client_connection_pool_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    reserve/1,
    owner_exits/1
]).

-include_lib("common_test/include/ct.hrl").
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
        reserve,
        owner_exits
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    meck:new(grpc_client),
    % shorter idle timeout for faster testing
    application:set_env(
        hpr,
        grcp_router_client_idle_timeout,
        50,
        [{persistent, true}]
    ),
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    meck:unload(grpc_client),
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

reserve(_Config) ->
    Owner = self(),

    meck:expect(
        grpc_client,
        connect,
        [transport(), host(), port(), []],
        {ok, fake_grpc_connection()}
    ),
    meck:expect(grpc_client, stop_connection, [fake_grpc_connection()], ok),

    {ok, GrpcClientConnection, ReservationRef} =
        hpr_grpc_client_connection_pool:reserve(Owner, lns()),

    ?assertEqual(fake_grpc_connection(), GrpcClientConnection),
    ?assertEqual(1, meck:num_calls(grpc_client, connect, 4)),

    ok = hpr_grpc_client_connection_pool:release(ReservationRef),
    ?assertEqual(0, meck:num_calls(grpc_client, stop_connection, 1)),

    % wait for idle timeout
    timer:sleep(100),

    ?assertEqual(1, meck:num_calls(grpc_client, stop_connection, 1)),
    ok.

owner_exits(_Config) ->
    Owner = spawn(owner_fun(fun() -> ok end)),

    meck:expect(
        grpc_client,
        connect,
        [transport(), host(), port(), []],
        {ok, fake_grpc_connection()}
    ),
    meck:expect(grpc_client, stop_connection, [fake_grpc_connection()], ok),

    {ok, _GrpcClientConnection, _ReservationRef} =
        hpr_grpc_client_connection_pool:reserve(Owner, lns()),

    stop_owner(Owner),

    % wait for idle timeout
    timer:sleep(100),

    ?assertEqual(1, meck:num_calls(grpc_client, stop_connection, 1)),
    ok.

%%--------------------------------------------------------------------
%% Private Functions
%%--------------------------------------------------------------------

transport() -> tcp.
host() -> "example-lns.com".
port() -> 4321.
lns() ->
    <<(list_to_binary(host()))/binary, $:, (integer_to_binary(port()))/binary>>.
fake_grpc_connection() -> #{fake => connection}.

owner_fun(BodyFun) ->
    fun() ->
        receive
            stop ->
                BodyFun()
        end
    end.

stop_owner(Pid) ->
    Pid ! stop.
