%%%-------------------------------------------------------------------
%% @doc
%% == HPR System Monitor ==
%%
%% Reports VM-level stalls. The runtime can tell us when a process spent an
%% unreasonably long time in garbage collection or holding a scheduler, but
%% nothing asked it to: a multi-second stall used to leave no attributable trace
%% at all, which is what made a periodic CPU spike invisible in a day's worth of
%% logs.
%%
%% `erlang:system_monitor/2' costs nothing while nothing trips -- the emulator
%% checks the thresholds it is already tracking and sends a message only when
%% one is exceeded.
%% @end
%%%-------------------------------------------------------------------
-module(hpr_sysmon).

-behaviour(gen_server).

-include("hpr.hrl").
-include("hpr_metrics.hrl").

-export([start_link/1]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(SERVER, ?MODULE).
-define(DEFAULT_LONG_GC, 500).
-define(DEFAULT_LONG_SCHEDULE, 500).

%% A stall bad enough to trip these thresholds can trip them for thousands of
%% processes at once. Logging all of them would spend the scheduler time we are
%% trying to account for, so events are always counted and only some are
%% logged.
-define(LOG_THROTTLE, hpr_sysmon_log_limit).
-define(DEFAULT_LOGS_PER_SEC, 10).

-record(state, {}).

-spec start_link(map()) -> {ok, pid()} | {error, any()}.
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

init(_Args) ->
    LongGC = hpr_utils:get_env_int(sysmon_long_gc_ms, ?DEFAULT_LONG_GC),
    LongSchedule = hpr_utils:get_env_int(sysmon_long_schedule_ms, ?DEFAULT_LONG_SCHEDULE),
    LogsPerSec = hpr_utils:get_env_int(sysmon_logs_per_sec, ?DEFAULT_LOGS_PER_SEC),
    ok = throttle:setup(?LOG_THROTTLE, LogsPerSec, per_second),
    _ = erlang:system_monitor(self(), [
        {long_gc, LongGC},
        {long_schedule, LongSchedule},
        busy_port,
        busy_dist_port
    ]),
    lager:info(
        [{long_gc_ms, LongGC}, {long_schedule_ms, LongSchedule}, {logs_per_sec, LogsPerSec}],
        "system monitor armed"
    ),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({monitor, PidOrPort, Kind, Info}, State) ->
    _ = prometheus_counter:inc(?METRICS_SYSMON_COUNTER, [Kind]),
    case throttle:check(?LOG_THROTTLE, ?LOG_THROTTLE) of
        {ok, _, _} ->
            %% Bound rather than inlined: lager's parse transform cannot read a
            %% `++' expression in the metadata position.
            MD = [{kind, Kind}, {duration_ms, duration(Info)} | identify(PidOrPort)],
            lager:warning(MD, "system monitor: ~p ~p", [Kind, Info]);
        _ ->
            ok
    end,
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("unknown info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% @doc `long_gc' and `long_schedule' carry a `timeout' in their info list;
%% `busy_port' and `busy_dist_port' carry no duration at all.
-spec duration(Info :: list() | term()) -> non_neg_integer() | undefined.
duration(Info) when is_list(Info) ->
    proplists:get_value(timeout, Info);
duration(_Info) ->
    undefined.

%% @doc Name the offender. A registered name is the useful answer when there is
%% one; otherwise `initial_call' says what kind of process it is, which is what
%% matters when the culprit is one of a hundred thousand identical workers.
-spec identify(pid() | port()) -> proplists:proplist().
identify(Pid) when is_pid(Pid) ->
    Keys = [registered_name, initial_call, current_function],
    case erlang:process_info(Pid, Keys) of
        undefined ->
            [{pid, Pid}, {dead, true}];
        Info ->
            [{pid, Pid} | Info]
    end;
identify(Port) when is_port(Port) ->
    case erlang:port_info(Port, name) of
        undefined -> [{port, Port}, {dead, true}];
        {name, Name} -> [{port, Port}, {port_name, Name}]
    end.
