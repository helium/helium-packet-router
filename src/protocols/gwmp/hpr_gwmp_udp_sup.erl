%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(hpr_gwmp_udp_sup).

-behaviour(supervisor).

-include("gwmp_udp_worker_sup.hrl").

-export([start_link/0, init/1, maybe_start_worker/2, lookup_worker/1]).

-define(APP, helium_packet_router).
-define(UDP_WORKER, hpr_gwmp_worker).

-define(ETS, hpr_gwmp_udp_sup_ets).

-define(FLAGS, #{
    strategy => simple_one_for_one,
    intensity => 3,
    period => 60
}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

maybe_start_worker(WorkerKey, Args) ->
    maybe_start_worker(WorkerKey, Args, ?APP, ?UDP_WORKER, ?ETS, ?MODULE).

lookup_worker(WorkerKey) ->
    lookup_worker(WorkerKey, ?ETS).

init([]) ->
    gwmp_udp_sup_init(?ETS, ?UDP_WORKER, ?FLAGS).

-spec maybe_start_worker(
PubKeyBin :: binary(),
Args :: map() | {error, any()},
AppName :: atom(),
UDPWorker :: atom(),
ETSTableName :: atom(),
SupModule :: atom()
) -> {ok, pid()} | {error, any()} | {error, worker_not_started, any()}.
maybe_start_worker(_WorkerKey, {error, _} = Err, _, _, _, _) ->
    Err;
maybe_start_worker(WorkerKey, Args, AppName, UDPWorker, ETSTableName, SupModule) ->
    case ets:lookup(ETSTableName, WorkerKey) of
        [] ->
            start_worker(WorkerKey, Args, AppName, UDPWorker, ETSTableName, SupModule);
        [{WorkerKey, Pid}] ->
            case erlang:is_process_alive(Pid) of
                true ->
                    {ok, Pid};
                false ->
                    _ = ets:delete(ETSTableName, WorkerKey),
                    start_worker(WorkerKey, Args, AppName, UDPWorker, ETSTableName, SupModule)
            end
    end.

-spec start_worker(
    PubKeyBin :: binary(),
    Args :: map(),
    AppName :: atom(),
    UDPWorker :: atom(),
    ETSTableName :: atom(),
    SupModule :: atom()
) ->
    {ok, pid()} | {error, worker_not_started, any()}.
start_worker(PubKeyBin, Args, AppName, UDPWorker, ETSTableName, SupModule) ->
    ChildArgs = maps:merge(#{pubkeybin => PubKeyBin}, Args),
    case supervisor:start_child(SupModule, [ChildArgs]) of
        {error, Err} ->
            {error, worker_not_started, Err};
        {ok, Pid} = OK ->
            case ets:insert_new(ETSTableName, {PubKeyBin, Pid}) of
                true ->
                    OK;
                false ->
                    supervisor:terminate_child(UDPWorker, Pid),
                    maybe_start_worker(PubKeyBin, Args, AppName, UDPWorker, ETSTableName, SupModule)
            end
    end.

-spec lookup_worker(
    PubKeyBin :: binary(),
    TabName :: atom()
) -> {ok, pid()} | {error, not_found}.
lookup_worker(WorkerKey, ETSTableName) ->
    case ets:lookup(ETSTableName, WorkerKey) of
        [] ->
            {error, not_found};
        [{WorkerKey, Pid}] ->
            case erlang:is_process_alive(Pid) of
                true -> {ok, Pid};
                false -> {error, not_found}
            end
    end.

gwmp_udp_sup_init(ETSTableName, UDPWorker, Flags) ->
    ets:new(ETSTableName, [public, named_table, set]),
    {ok, {Flags, [?WORKER(UDPWorker)]}}.
