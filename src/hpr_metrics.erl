-module(hpr_metrics).

-behavior(gen_server).

-include("hpr_metrics.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1
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

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(_Args) ->
    erlang:process_flag(trap_exit, true),
    lager:info("init"),
    ok = declare_metrics(),
    _ = schedule_next_tick(),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(?METRICS_TICK, State) ->
    lager:info("running metrics"),
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
                        {buckets, [50, 100, 250, 500, 1000, 2000, 5000, 10000, 30000, 60000]}
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
