-module(hpr_protocol_router_pool_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    basic_test/1
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
        basic_test
    ].

-define(SERVER_PORT, 8080).
%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    meck:unload(),
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

basic_test(_Config) ->
    %% Startup Router server
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_test_packet_router_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),

    %% Interceptor
    Self = self(),
    application:set_env(
        hpr,
        test_packet_router_service_route,
        fun(Env, StreamState) ->
            {packet, Packet} = hpr_envelope_up:data(Env),
            Self ! {packet_up, Packet},
            {ok, StreamState}
        end
    ),

    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 0,
        oui => 4020,
        server => #{
            host => "127.0.0.1",
            port => 8082,
            protocol => {packet_router, #{}}
        },
        max_copies => 2
    }),

    {ok, Sup} = hpr_router_sup:start_link(),
    {ok, _PoolSup} = hpr_router_sup:maybe_start_pool_sup(Route),
    timer:sleep(1000),

    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),
    DevAddr = 16#00000001,
    PacketUp = test_utils:uplink_packet_up(#{
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey,
        devaddr => DevAddr,
        gateway => Gateway,
        sig_fun => SigFun
    }),

    Now = erlang:system_time(millisecond),
    Max = 1000,
    lists:foreach(
        fun(_) ->
            erlang:spawn(fun() ->
                timer:sleep(rand:uniform(10)),
                poolboy:transaction(erlang:list_to_atom(RouteID), fun(Worker) ->
                    hpr_router_pool_worker:send(Worker, PacketUp)
                end)
            end)
        end,
        lists:seq(1, Max)
    ),

    ?assertEqual(Max, rcv_loop(0)),

    Then = erlang:system_time(millisecond),

    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Then - Now - 1000]),

    erlang:exit(Sup, shutdown),
    ok = gen_server:stop(ServerPid),
    ok.

%% ===================================================================
%% Helpers
%% ===================================================================

rcv_loop(Acc) ->
    receive
        {packet_up, _} ->
            rcv_loop(Acc + 1)
    after 1000 ->
        Acc
    end.
