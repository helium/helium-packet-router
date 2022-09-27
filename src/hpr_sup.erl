%%%-------------------------------------------------------------------
%% @doc helium_packet_router top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(hpr_sup).

-behaviour(supervisor).

-include("hpr.hrl").

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

-define(SUP(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => supervisor,
    modules => [I]
}).

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
    lager:info("sup init"),

    BaseDir = application:get_env(?APP, base_dir, "/var/data"),
    ok = filelib:ensure_dir(BaseDir),

    ok = hpr_routing:init(),

    RedirectMap = application:get_env(hpr, redirect_by_region, #{}),

    ChildSpecs = [
        ?WORKER(hpr_metrics, [#{}]),
        ?WORKER(hpr_routing_config_worker, [#{base_dir => BaseDir}]),
        ?WORKER(hpr_gwmp_redirect_worker, [RedirectMap]),
        ?WORKER(hpr_router_connection_manager, []),
        ?WORKER(hpr_router_stream_manager, [
            'helium.packet_router.gateway', send_packet, client_packet_router_pb
        ]),
        ?SUP(hpr_gwmp_udp_sup, [])
    ],
    {ok, {
        #{
            strategy => rest_for_one,
            intensity => 1,
            period => 5
        },
        ChildSpecs
    }}.
