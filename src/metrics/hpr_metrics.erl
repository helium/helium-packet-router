-module(hpr_metrics).

-behavior(gen_server).

-include("hpr_metrics.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    observe_packet_up/4
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec observe_packet_up(
    PacketType :: hpr_packet_up:type(),
    Status :: hpr_routing:hpr_routing_response(),
    NumberOfRoutes :: non_neg_integer(),
    Start :: non_neg_integer()
) -> ok.
observe_packet_up({Type, _}, RoutingStatus, NumberOfRoutes, Start) ->
    Status =
        case RoutingStatus of
            ok -> ok;
            {error, _} -> error
        end,
    prometheus_histogram:observe(
        ?METRICS_PACKET_UP_HISTOGRAM,
        [Type, Status, NumberOfRoutes],
        erlang:system_time(millisecond) - Start
    ).
%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(_Args) ->
    erlang:process_flag(trap_exit, true),
    lager:info("init"),
    ElliOpts = [
        {callback, hpr_metrics_handler},
        {callback_args, #{}},
        {port, 3000}
    ],
    {ok, _Pid} = elli:start_link(ElliOpts),
    ok = declare_metrics(),
    _ = schedule_next_tick(),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(?METRICS_TICK, State) ->
    lager:debug("running metrics"),
    _ = erlang:spawn_opt(
        fun() ->
            ok = record_grpc_connections()
        end,
        [
            {fullsweep_after, 0},
            {priority, high}
        ]
    ),
    _ = schedule_next_tick(),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    lager:warning("going down ~s", [_Reason]),
    lists:foreach(
        fun({Metric, Module, _Meta, _Description}) ->
            lager:info("removing metric ~s as ~s", [Metric, Module]),
            Module:deregister(Metric)
        end,
        ?METRICS
    ).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec declare_metrics() -> ok.
declare_metrics() ->
    lists:foreach(
        fun({Metric, Module, Meta, Description}) ->
            lager:info("declaring metric ~s as ~s", [Metric, Module]),
            case Module of
                prometheus_histogram ->
                    _ = Module:declare([
                        {name, Metric},
                        {help, Description},
                        {labels, Meta},
                        {buckets, [
                            10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000, 60000
                        ]}
                    ]);
                _ ->
                    _ = Module:declare([
                        {name, Metric},
                        {help, Description},
                        {labels, Meta}
                    ])
            end
        end,
        ?METRICS
    ).

-spec schedule_next_tick() -> reference().
schedule_next_tick() ->
    erlang:send_after(?METRICS_TICK_INTERVAL, self(), ?METRICS_TICK).

-spec record_grpc_connections() -> ok.
record_grpc_connections() ->
    Opts = application:get_env(grpcbox, listen_opts, #{}),
    PoolName = grpcbox_services_sup:pool_name(Opts),
    try
        Counts = acceptor_pool:count_children(PoolName),
        proplists:get_value(active, Counts)
    of
        Count ->
            _ = prometheus_gauge:set(?METRICS_GRPC_CONNECTION_GAUGE, Count)
    catch
        _:_ ->
            lager:warning("no grpcbox acceptor named ~p", [PoolName]),
            _ = prometheus_gauge:set(?METRICS_GRPC_CONNECTION_GAUGE, 0)
    end,
    ok.
