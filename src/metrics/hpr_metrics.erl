-module(hpr_metrics).

-behavior(gen_server).

-include("hpr_metrics.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    observe_packet_up/4,
    packet_up_per_oui/2,
    packet_down/1,
    observe_packet_report/2
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
    RoutingStatus :: hpr_routing:hpr_routing_response(),
    NumberOfRoutes :: non_neg_integer(),
    Start :: non_neg_integer()
) -> ok.
observe_packet_up({Type, _}, RoutingStatus, NumberOfRoutes, Start) ->
    Status =
        case RoutingStatus of
            ok -> ok;
            {error, Reason} -> Reason
        end,
    prometheus_histogram:observe(
        ?METRICS_PACKET_UP_HISTOGRAM,
        [Type, Status, NumberOfRoutes],
        erlang:system_time(millisecond) - Start
    ).

-spec packet_up_per_oui(
    Type :: join_req | uplink | undefined,
    OUI :: non_neg_integer()
) -> ok.
packet_up_per_oui(Type, OUI) ->
    _ = prometheus_counter:inc(?METRICS_PACKET_UP_PER_OUI_COUNTER, [Type, OUI]),
    ok.

-spec packet_down(
    Status :: ok | not_found
) -> ok.
packet_down(Status) ->
    _ = prometheus_counter:inc(?METRICS_PACKET_DOWN_COUNTER, [Status]),
    ok.

-spec observe_packet_report(
    Status :: ok | error,
    Start :: non_neg_integer()
) -> ok.
observe_packet_report(Status, Start) ->
    prometheus_histogram:observe(
        ?METRICS_PACKET_REPORT_HISTOGRAM,
        [Status],
        erlang:system_time(millisecond) - Start
    ).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(_Args) ->
    ok = declare_metrics(),
    _ = schedule_next_tick(),
    lager:info("init"),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(?METRICS_TICK, State) ->
    lager:debug("running metrics"),
    _ = erlang:spawn(
        fun() ->
            ok = record_grpc_connections(),
            ok = record_routes(),
            ok = record_eui_pairs(),
            ok = record_skfs(),
            ok = record_ets(),
            ok = record_queues()
        end
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

-spec record_routes() -> ok.
record_routes() ->
    case ets:info(hpr_routes_ets, size) of
        undefined ->
            _ = prometheus_gauge:set(?METRICS_ROUTES_GAUGE, [], 0);
        N ->
            _ = prometheus_gauge:set(?METRICS_ROUTES_GAUGE, [], N)
    end,
    ok.

-spec record_eui_pairs() -> ok.
record_eui_pairs() ->
    case ets:info(hpr_route_eui_pairs_ets, size) of
        undefined ->
            _ = prometheus_gauge:set(?METRICS_EUI_PAIRS_GAUGE, [], 0);
        N ->
            _ = prometheus_gauge:set(?METRICS_EUI_PAIRS_GAUGE, [], N)
    end,
    ok.

-spec record_skfs() -> ok.
record_skfs() ->
    case ets:info(hpr_route_skfs_ets, size) of
        undefined ->
            _ = prometheus_gauge:set(?METRICS_SKFS_GAUGE, [], 0);
        N ->
            _ = prometheus_gauge:set(?METRICS_SKFS_GAUGE, [], N)
    end,
    ok.

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

-spec record_ets() -> ok.
record_ets() ->
    lists:foreach(
        fun(ETS) ->
            Name = ets:info(ETS, name),
            case ets:info(ETS, memory) of
                undefined ->
                    ok;
                Memory ->
                    Bytes = Memory * erlang:system_info(wordsize),
                    case Bytes > 1000000 of
                        false -> ok;
                        true -> _ = prometheus_gauge:set(?METRICS_VM_ETS_MEMORY, [Name], Bytes)
                    end
            end
        end,
        ets:all()
    ),
    ok.

-spec record_queues() -> ok.
record_queues() ->
    CurrentQs = lists:foldl(
        fun({Pid, Length, _Extra}, Acc) ->
            Name = get_pid_name(Pid),
            maps:put(Name, Length, Acc)
        end,
        #{},
        recon:proc_count(message_queue_len, 5)
    ),
    RecorderQs = lists:foldl(
        fun({[{"name", Name} | _], Length}, Acc) ->
            maps:put(Name, Length, Acc)
        end,
        #{},
        prometheus_gauge:values(default, ?METRICS_VM_PROC_Q)
    ),
    OldQs = maps:without(maps:keys(CurrentQs), RecorderQs),
    lists:foreach(
        fun({Name, _Length}) ->
            case name_to_pid(Name) of
                undefined ->
                    prometheus_gauge:remove(?METRICS_VM_PROC_Q, [Name]);
                Pid ->
                    case recon:info(Pid, message_queue_len) of
                        undefined ->
                            prometheus_gauge:remove(?METRICS_VM_PROC_Q, [Name]);
                        {message_queue_len, 0} ->
                            prometheus_gauge:remove(?METRICS_VM_PROC_Q, [Name]);
                        {message_queue_len, Length} ->
                            prometheus_gauge:set(?METRICS_VM_PROC_Q, [Name], Length)
                    end
            end
        end,
        maps:to_list(OldQs)
    ),
    NewQs = maps:without(maps:keys(OldQs), CurrentQs),
    Config = application:get_env(router, metrics, []),
    MinLength = proplists:get_value(record_queue_min_length, Config, 2000),
    lists:foreach(
        fun({Name, Length}) ->
            case Length > MinLength of
                true ->
                    _ = prometheus_gauge:set(?METRICS_VM_PROC_Q, [Name], Length);
                false ->
                    ok
            end
        end,
        maps:to_list(NewQs)
    ),
    ok.

-spec get_pid_name(pid()) -> list().
get_pid_name(Pid) ->
    case recon:info(Pid, registered_name) of
        [] -> erlang:pid_to_list(Pid);
        {registered_name, Name} -> erlang:atom_to_list(Name);
        _Else -> erlang:pid_to_list(Pid)
    end.

-spec name_to_pid(list()) -> pid() | undefined.
name_to_pid(Name) ->
    case erlang:length(string:split(Name, ".")) > 1 of
        true ->
            erlang:list_to_pid(Name);
        false ->
            erlang:whereis(erlang:list_to_atom(Name))
    end.

-spec schedule_next_tick() -> reference().
schedule_next_tick() ->
    erlang:send_after(?METRICS_TICK_INTERVAL, self(), ?METRICS_TICK).
