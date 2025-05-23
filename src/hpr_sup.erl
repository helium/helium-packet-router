%%%-------------------------------------------------------------------
%% @doc helium_packet_router top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(hpr_sup).

-behaviour(supervisor).

-include("hpr.hrl").

-export([start_link/0]).

-export([init/1]).

-export([maybe_start_channel/2]).

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

    ok = timing("packet routing cache", fun() -> hpr_routing_cache:init_ets() end),
    ok = timing("device stats", fun() -> hpr_device_stats:init() end),
    ok = timing("routing throttles", fun() -> hpr_routing:init() end),
    ok = timing("multi buy", fun() -> hpr_multi_buy:init() end),
    ok = timing("packet_router streams", fun() -> hpr_protocol_router:init() end),
    ok = timing("config service", fun() -> hpr_route_ets:init() end),
    ok = timing("gw location", fun() -> hpr_gateway_location:init() end),

    PacketReporterConfig = application:get_env(?APP, packet_reporter, #{}),
    ConfigServiceConfig = application:get_env(?APP, ?IOT_CONFIG_SERVICE, #{}),
    LocationServiceConfig = application:get_env(?APP, iot_location_service, #{}),
    DownlinkServiceConfig = application:get_env(?APP, downlink_service, #{}),
    MultiBuyServiceConfig = application:get_env(?APP, multi_buy_service, #{}),

    %% Starting config service client channel here because of the way we get
    %% .env vars into the app.
    _ = maybe_start_channel(ConfigServiceConfig, ?IOT_CONFIG_CHANNEL),
    _ = maybe_start_channel(LocationServiceConfig, ?LOCATION_CHANNEL),
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

-spec timing(Label :: string(), Fn :: fun()) -> ok.
timing(Label, Fn) ->
    Start = erlang:system_time(millisecond),
    Result = Fn(),
    End = erlang:system_time(millisecond),
    lager:info("~s took ~w ms", [Label, End - Start]),
    Result.
