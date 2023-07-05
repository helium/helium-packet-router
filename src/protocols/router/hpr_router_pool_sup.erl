-module(hpr_router_pool_sup).

-behaviour(supervisor).

-export([
    start_link/1
]).

-export([
    init/1
]).

-define(FLAGS, #{
    strategy => one_for_one,
    intensity => 10,
    period => 10
}).

%%====================================================================
%% API functions
%%====================================================================

start_link(Route) ->
    supervisor:start_link(?MODULE, Route).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init(Route) ->
    RouteID = hpr_route:id(Route),
    Server = hpr_route:server(Route),
    Host = hpr_route:host(Server),
    Port = hpr_route:port(Server),
    PoolName = erlang:list_to_atom(RouteID),
    PoolArgs = [
        {name, {local, PoolName}},
        {worker_module, hpr_router_pool_worker},
        {size, 25},
        {max_overflow, 0}
    ],
    Spec = poolboy:child_spec(PoolName, PoolArgs, Route),
    case
        grpcbox_client:connect(RouteID, [{http, Host, Port, []}], #{
            sync_start => true
        })
    of
        {ok, _Conn, _} ->
            lager:info("channel started ~p:~p", [Host, Port]),
            {ok, {?FLAGS, [Spec]}};
        {ok, _Conn} ->
            lager:info("channel started ~p:~p", [Host, Port]),
            {ok, {?FLAGS, [Spec]}};
        {error, _} ->
            lager:error("failed to start channel for ~p:~p", [Host, Port]),
            ignore
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
