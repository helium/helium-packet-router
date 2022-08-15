%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 12. Aug 2022 1:10 PM
%%%-------------------------------------------------------------------
-module(gwmp_udp_worker_sup_utils).
-author("jonathanruttenberg").

-include("gwmp_udp_worker_sup.hrl").

%% API
-export([maybe_start_worker/6, lookup_worker/2, gwmp_udp_sup_init/3]).

-spec maybe_start_worker(
    WorkerKey :: {PubKeyBin :: binary(), NetID :: non_neg_integer() | binary()},
    Args :: map() | {error, any()},
    atom(),
    atom(),
    atom(),
    atom()
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

-spec lookup_worker(
    {PubKeyBin :: binary(), NetID :: non_neg_integer() | binary()},
    atom()
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

-spec start_worker(
    {binary(), non_neg_integer() | binary()},
    map(),
    atom(),
    atom(),
    atom(),
    atom()
) ->
    {ok, pid()} | {error, worker_not_started, any()}.
start_worker({PubKeyBin, NetID} = WorkerKey, Args, AppName, UDPWorker, ETSTableName, SupModule) ->
    AppArgs = get_app_args(AppName, UDPWorker),
    ChildArgs = maps:merge(#{pubkeybin => PubKeyBin, net_id => NetID}, maps:merge(AppArgs, Args)),
    case supervisor:start_child(SupModule, [ChildArgs]) of
        {error, Err} ->
            {error, worker_not_started, Err};
        {ok, Pid} = OK ->
            case ets:insert_new(ETSTableName, {WorkerKey, Pid}) of
                true ->
                    OK;
                false ->
                    supervisor:terminate_child(UDPWorker, Pid),
                    maybe_start_worker(WorkerKey, Args, AppName, UDPWorker, ETSTableName, SupModule)
            end
    end.

-spec get_app_args(atom(), atom()) -> map().
get_app_args(AppName, UDPWorker) ->
    AppArgs = maps:from_list(application:get_env(AppName, UDPWorker, [])),
    Port =
        case maps:get(port, AppArgs, 1700) of
            PortAsList when is_list(PortAsList) ->
                erlang:list_to_integer(PortAsList);
            P ->
                P
        end,
    maps:put(port, Port, AppArgs).
