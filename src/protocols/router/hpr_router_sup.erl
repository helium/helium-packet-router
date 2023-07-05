-module(hpr_router_sup).

-behaviour(supervisor).

-export([
    start_link/0,
    maybe_start_pool_sup/1,
    lookup_pool_sup/1
]).

-export([
    init/1
]).

-define(FLAGS, #{
    strategy => simple_one_for_one,
    intensity => 3,
    period => 60
}).

-define(POOL_SUP, hpr_router_pool_sup).

-define(SUP, #{
    id => ?POOL_SUP,
    start => {?POOL_SUP, start_link, []},
    restart => temporary,
    shutdown => 1000,
    type => worker,
    modules => [?POOL_SUP]
}).

-define(ETS, hpr_router_sup_ets).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec maybe_start_pool_sup(Route :: hpr_route:route()) -> {ok, pid()} | {error, any()}.
maybe_start_pool_sup(Route) ->
    RouteID = hpr_route:id(Route),
    case ets:lookup(?ETS, RouteID) of
        [] ->
            start_pool_sup(Route);
        [{RouteID, Pid}] ->
            case erlang:is_process_alive(Pid) of
                true ->
                    {ok, Pid};
                false ->
                    _ = ets:delete(?ETS, RouteID),
                    start_pool_sup(Route)
            end
    end.

-spec lookup_pool_sup(Route :: hpr_route:route()) -> {ok, pid()} | {error, not_found}.
lookup_pool_sup(Route) ->
    RouteID = hpr_route:id(Route),
    case ets:lookup(?ETS, RouteID) of
        [] ->
            {error, not_found};
        [{RouteID, Pid}] ->
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
    {ok, {?FLAGS, [?SUP]}}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec start_pool_sup(Route :: hpr_route:route()) ->
    {ok, pid()} | {error, any()}.
start_pool_sup(Route) ->
    case supervisor:start_child(?MODULE, [Route]) of
        {error, Err} ->
            {error, Err};
        {ok, Pid} = OK ->
            RouteID = hpr_route:id(Route),
            case ets:insert_new(?ETS, {RouteID, Pid}) of
                true ->
                    OK;
                false ->
                    supervisor:terminate_child(?POOL_SUP, Pid),
                    maybe_start_pool_sup(Route)
            end
    end.
