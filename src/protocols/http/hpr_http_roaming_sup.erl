%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs
%%% @doc
%%%
%%% @end
%%% Created : 22. Sep 2022 1:11 PM
%%%-------------------------------------------------------------------
-module(hpr_http_roaming_sup).
-author("jonathanruttenberg").

-behaviour(supervisor).

-include("hpr_http_roaming.hrl").

-type http_protocol() :: #http_protocol{}.

%% API
-export([
    start_link/0,
    maybe_start_worker/1
]).

%% Supervisor callbacks
-export([init/1]).

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

-export_type([http_protocol/0]).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec maybe_start_worker(
    Args :: map()
) -> {ok, pid()} | {error, any()}.
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
    {ok, {?FLAGS, [?WORKER(hpr_http_roaming_worker)]}}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
