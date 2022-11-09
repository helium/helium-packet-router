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

-define(ELLI_WORKER(I, Args), #{
    id => I,
    start => {elli, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [elli]
}).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    KeyFileName = application:get_env(hpr, key, "/var/data/hpr.key"),
    ok = filelib:ensure_dir(KeyFileName),
    Key =
        case libp2p_crypto:load_keys(KeyFileName) of
            {ok, #{secret := PrivKey, public := PubKey}} ->
                {PubKey, libp2p_crypto:mk_sig_fun(PrivKey)};
            {error, enoent} ->
                KeyMap =
                    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(
                        ecc_compact
                    ),
                ok = libp2p_crypto:save_keys(KeyMap, KeyFileName),
                {PubKey, libp2p_crypto:mk_sig_fun(PrivKey)}
        end,
    ok = persistent_term:put(?HPR_KEY, Key),

    ok = hpr_routing:init(),
    ok = hpr_config:init(),
    ok = hpr_max_copies:init(),
    ok = hpr_http_roaming_utils:init_ets(),

    ElliConfigMetrics = [
        {callback, hpr_metrics_handler},
        {port, 3000}
    ],

    HttpRoamingDownlink = application:get_env(?APP, http_roaming_downlink_port, 8085),
    ElliConfigRoamingDownlink = [
        {callback, hpr_http_roaming_downlink_handler},
        {port, HttpRoamingDownlink}
    ],

    ConfigWorkerConfig = application:get_env(?APP, config_worker, #{}),
    PacketReporterConfig = application:get_env(?APP, packet_reporter, #{}),

    ChildSpecs = [
        ?WORKER(hpr_metrics, [#{}]),
        ?ELLI_WORKER(hpr_metrics_handler, [ElliConfigMetrics]),
        ?ELLI_WORKER(hpr_http_roaming_downlink_handler, [ElliConfigRoamingDownlink]),
        ?WORKER(hpr_config_worker, [ConfigWorkerConfig]),
        ?WORKER(hpr_packet_reporter, [PacketReporterConfig]),
        ?SUP(hpr_gwmp_sup, []),
        ?SUP(hpr_http_roaming_sup, []),
        ?WORKER(hpr_router_connection_manager, []),
        ?WORKER(hpr_router_stream_manager, [
            'helium.packet_router.packet', route, client_packet_router_pb
        ])
    ],
    {ok, {
        #{
            strategy => one_for_one,
            intensity => 1,
            period => 5
        },
        ChildSpecs
    }}.
