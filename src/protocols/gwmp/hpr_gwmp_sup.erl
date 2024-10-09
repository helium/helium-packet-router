%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs Inc.
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(hpr_gwmp_sup).

-behaviour(supervisor).

-export([
    start_link/0,
    init/1,
    maybe_start_worker/1
]).

-define(UDP_WORKER, hpr_gwmp_worker).

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
    intensity => 100,
    period => 1
}).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec maybe_start_worker(Args :: map()) -> {ok, pid() | undefined} | {error, any()}.
maybe_start_worker(#{key := Key} = Args) ->
    case gproc:lookup_local_name(Key) of
        Pid when is_pid(Pid) ->
            {ok, Pid};
        undefined ->
            supervisor:start_child(?MODULE, [Args])
    end.

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    {ok, {?FLAGS, [?WORKER(?UDP_WORKER)]}}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
