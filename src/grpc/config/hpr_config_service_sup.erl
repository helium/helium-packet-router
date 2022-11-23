-module(hpr_config_service_sup).

-behaviour(supervisor).

-include("hpr.hrl").

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

-define(WORKER(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [I]
}).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    ok = hpr_config:init(),

    ConfigServiceConfig = application:get_env(?APP, config_service, #{}),
    ChildSpecs = [
        ?WORKER(hpr_config_conn_worker, [ConfigServiceConfig]),
        ?WORKER(hpr_route_worker, [maps:get(route, ConfigServiceConfig, #{})])
    ],
    {ok, {
        #{
            strategy => rest_for_one,
            intensity => 1,
            period => 5
        },
        ChildSpecs
    }}.
