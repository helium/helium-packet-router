-module(hpr_sup_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    packet_router_server_under_hpr_sup_test/1
]).

-include_lib("eunit/include/eunit.hrl").

%% Registered name grpcbox gives the services supervisor for the packet router
%% listener, derived from its listen_opts (ip 0.0.0.0, port 8080). See
%% grpcbox_services_sup:services_sup_name/1.
-define(PACKET_ROUTER_SERVICES_SUP, 'grpcbox_services_sup_0.0.0.0_8080').

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

all() ->
    [
        packet_router_server_under_hpr_sup_test
    ].

init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%% The packet router GRPC server must be supervised by hpr_sup (and not
%% auto-started by the grpcbox application), so that the listener only comes up
%% after the rest of HPR has been initialized. This guards against regressing
%% the server back into grpcbox's own supervision tree.
packet_router_server_under_hpr_sup_test(_Config) ->
    Children = supervisor:which_children(hpr_sup),

    %% hpr_sup starts the server under the child spec id `grpcbox_services_sup'.
    Child = lists:keyfind(grpcbox_services_sup, 1, Children),
    ?assertMatch({grpcbox_services_sup, _Pid, supervisor, _Modules}, Child),
    {grpcbox_services_sup, Pid, supervisor, _} = Child,
    ?assert(erlang:is_pid(Pid)),
    ?assert(erlang:is_process_alive(Pid)),

    %% And it must be the packet router listener on 0.0.0.0:8080, i.e. the same
    %% process grpcbox registered for that port, proving hpr_sup owns it.
    ?assertEqual(Pid, erlang:whereis(?PACKET_ROUTER_SERVICES_SUP)),

    ok.
