%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(hpr_gwmp_udp_sup).

-behaviour(supervisor).

-export([start_link/0, init/1, maybe_start_worker/2, lookup_worker/1]).

-define(APP, helium_packet_router).
-define(UDP_WORKER, hpr_gwmp_client).

-define(ETS, hpr_gwmp_udp_sup_ets).

-define(FLAGS, #{
    strategy => simple_one_for_one,
    intensity => 3,
    period => 60
}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

maybe_start_worker(WorkerKey, Args) ->
    gwmp_udp_worker_sup_utils:maybe_start_worker(WorkerKey, Args, ?APP, ?UDP_WORKER, ?ETS, ?MODULE).

lookup_worker(WorkerKey) ->
    gwmp_udp_worker_sup_utils:lookup_worker(WorkerKey, ?ETS).

init([]) ->
    gwmp_udp_worker_sup_utils:gwmp_udp_sup_init(?ETS, ?UDP_WORKER, ?FLAGS).
