%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs Inc.
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(hpr_gwmp_udp_sup).

-behaviour(supervisor).

-export([
    start_link/0,
    init/1,
    maybe_start_worker/1,
    lookup_worker/1
]).

-define(UDP_WORKER, hpr_gwmp_worker).
-define(ETS, hpr_gwmp_udp_sup_ets).

-define(WORKER(I), #{
    id => I,
    start => {I, start_link, []},
    restart => temporary,
    shutdown => 1000,
    type => worker,
    modules => [I]
}).

-define(FLAGS, #{
    strategy => simple_one_for_one,
    intensity => 3,
    period => 60
}).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec maybe_start_worker(WorkerKey :: binary()) -> {ok, pid()} | {error, any()}.
maybe_start_worker(WorkerKey) ->
    case ets:lookup(?ETS, WorkerKey) of
        [] ->
            start_worker(WorkerKey);
        [{WorkerKey, Pid}] ->
            case erlang:is_process_alive(Pid) of
                true ->
                    {ok, Pid};
                false ->
                    _ = ets:delete(?ETS, WorkerKey),
                    start_worker(WorkerKey)
            end
    end.

-spec lookup_worker(PubKeyBin :: binary()) -> {ok, pid()} | {error, not_found}.
lookup_worker(WorkerKey) ->
    case ets:lookup(?ETS, WorkerKey) of
        [] ->
            {error, not_found};
        [{WorkerKey, Pid}] ->
            case erlang:is_process_alive(Pid) of
                true -> {ok, Pid};
                false -> {error, not_found}
            end
    end.

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    ?ETS = ets:new(?ETS, [public, named_table, set]),
    {ok, {?FLAGS, [?WORKER(?UDP_WORKER)]}}.

%%====================================================================
%% Internal Functions
%%====================================================================

-spec start_worker(PubKeyBin :: binary()) ->
    {ok, pid()} | {error, any()}.
start_worker(PubKeyBin) ->
    ChildArgs = #{pubkeybin => PubKeyBin},
    case supervisor:start_child(?MODULE, [ChildArgs]) of
        {error, Err} ->
            {error, Err};
        {ok, Pid} = OK ->
            case ets:insert_new(?ETS, {PubKeyBin, Pid}) of
                true ->
                    OK;
                false ->
                    supervisor:terminate_child(?UDP_WORKER, Pid),
                    maybe_start_worker(PubKeyBin)
            end
    end.
