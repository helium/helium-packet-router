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
    DataDir = hpr_utils:base_data_dir(),

    KeyFileName = filename:join(DataDir, "hpr.key"),
    lager:info("KeyFileName ~s", [KeyFileName]),

    ok = filelib:ensure_dir(KeyFileName),
    ok = hpr_utils:load_key(KeyFileName),

    ok = hpr_routing_cache:init_ets(),
    ok = hpr_routing:init(),
    ok = hpr_multi_buy:init(),
    ok = hpr_protocol_router:init(),
    ok = hpr_route_ets:init(),
    ok = hpr_gateway_location:init(),

    PacketReporterConfig = application:get_env(?APP, packet_reporter, #{}),
    ConfigServiceConfig = application:get_env(?APP, iot_config_service, #{}),
    DownlinkServiceConfig = application:get_env(?APP, downlink_service, #{}),
    MultiBuyServiceConfig = application:get_env(?APP, multi_buy_service, #{}),

    %% Starting config service client channel here because of the way we get
    %% .env vars into the app.
    _ = maybe_start_channel(ConfigServiceConfig, ?IOT_CONFIG_CHANNEL),
    _ = maybe_start_channel(DownlinkServiceConfig, ?DOWNLINK_CHANNEL),
    _ = maybe_start_channel(MultiBuyServiceConfig, ?MULTI_BUY_CHANNEL),

    ElliConfigMetrics = [
        {callback, hpr_metrics_handler},
        {port, 3000}
    ],

    ChildSpecs = [
        ?WORKER(hpr_routing_cache, [#{}]),
        ?WORKER(hpr_metrics, [#{}]),
        ?ELLI_WORKER(hpr_metrics_handler, [ElliConfigMetrics]),

        ?WORKER(hpr_packet_reporter, [PacketReporterConfig]),

        ?WORKER(hpr_route_stream_worker, [#{}]),

        ?WORKER(hpr_protocol_router, [#{}]),

        ?SUP(hpr_gwmp_sup, []),

        ?SUP(hpr_http_roaming_sup, []),
        ?WORKER(hpr_http_roaming_downlink_stream_worker, [#{}])
    ],
    {ok, {
        #{
            strategy => one_for_one,
            intensity => 1,
            period => 5
        },
        ChildSpecs
    }}.

maybe_start_channel(Config, ChannelName) ->
    case Config of
        #{transport := []} ->
            lager:error("no transport provided for ~s, defaulting to http", [ChannelName]),
            maybe_start_channel(Config#{transport => http}, ChannelName);
        #{transport := Transport} when erlang:is_list(Transport) ->
            maybe_start_channel(
                Config#{transport => erlang:list_to_existing_atom(Transport)}, ChannelName
            );
        #{port := []} ->
            lager:error("no port provided for ~s", [ChannelName]);
        #{port := Port} when erlang:is_list(Port) ->
            maybe_start_channel(Config#{port => erlang:list_to_integer(Port)}, ChannelName);
        #{host := Host, port := Port, transport := http} ->
            _ = grpcbox_client:connect(ChannelName, [{http, Host, Port, []}], #{}),
            lager:info("~s started at ~s:~w", [ChannelName, Host, Port]);
        #{host := Host, port := Port, transport := https} ->
            _ = application:ensure_all_started(ssl),
            _ = grpcbox_client:connect(ChannelName, [{https, Host, Port, []}], #{}),
            lager:info("~s started at ~s:~w", [ChannelName, Host, Port]);
        _ ->
            lager:error("no host/port/transport to start ~s", [ChannelName])
    end.
