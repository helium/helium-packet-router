-module(hpr_routing_cache).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    init_ets/0
]).

-export([
    lookup/1,
    queue/2,
    lock/2,
    error/2,
    no_routes/1,
    routes/2
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(SERVER, ?MODULE).
-define(ROUTING_ETS, hpr_routing_cache_ets).
-define(CLEANUP, cleanup_tick).

-type packet() :: {hpr_packet_up:packet(), Time :: non_neg_integer()}.

-record(state, {
    window :: non_neg_integer(),
    timeout :: non_neg_integer(),
    timer_ref :: reference()
}).

-record(routing_entry, {
    hash :: binary(),
    time :: non_neg_integer(),
    state :: route | no_routes | locked | {error, any()},
    routes = [] :: list(hpr_route_ets:route()),
    packets = [] :: list(packet())
}).

%% ------------------------------------------------------------------
%% ETS Function Definitions
%% ------------------------------------------------------------------

init_ets() ->
    ?ROUTING_ETS = ets:new(?ROUTING_ETS, [
        public,
        named_table,
        set,
        {write_concurrency, true},
        {read_concurrency, true},
        {keypos, #routing_entry.hash}
    ]),
    ok.

-spec lookup(binary()) ->
    new
    | no_routes
    | {route, list(hpr_route_ets:route())}
    | {locked, #routing_entry{}}
    | {error, any()}.
lookup(Hash) ->
    case ets:lookup(?ROUTING_ETS, Hash) of
        [] -> new;
        [#routing_entry{state = no_routes}] -> no_routes;
        [#routing_entry{state = route, routes = Routes}] -> {route, Routes};
        [#routing_entry{state = locked} = Entry] -> {locked, Entry};
        [#routing_entry{state = {error, _} = Err}] -> Err
    end.

-spec queue(#routing_entry{}, packet()) -> ok.
queue(#routing_entry{packets = Packets} = Entry, NewPacket) ->
    ets:insert(?ROUTING_ETS, Entry#routing_entry{packets = [NewPacket | Packets]}),
    ok.

-spec lock(hpr_packet_up:packet(), StartTime :: non_neg_integer()) ->
    {ok, #routing_entry{}} | {error, already_locked}.
lock(PacketUp, StartTime) ->
    Entry = #routing_entry{
        hash = hpr_packet_up:phash(PacketUp),
        time = StartTime,
        state = locked,
        packets = [{PacketUp, StartTime}]
    },
    case ets:insert_new(?ROUTING_ETS, Entry) of
        true -> {ok, Entry};
        false -> {error, already_locked}
    end.

-spec error(#routing_entry{}, {error, any()}) -> ok.
error(Entry, Error) ->
    ets:insert(?ROUTING_ETS, Entry#routing_entry{state = Error}),
    ok.

-spec no_routes(#routing_entry{}) -> ok.
no_routes(Entry) ->
    ets:insert(?ROUTING_ETS, Entry#routing_entry{state = no_routes}),
    ok.

-spec routes(#routing_entry{}, list(hpr_routing:route())) -> list(packet()).
routes(#routing_entry{hash = Hash} = Entry, RoutesETS) ->
    case ?MODULE:lookup(Hash) of
        {locked, #routing_entry{packets = QueuedPackets}} ->
            ets:insert(?ROUTING_ETS, Entry#routing_entry{state = route, routes = RoutesETS}),
            QueuedPackets;
        Other ->
            lager:warning(
                [{hash, Hash}, {result, Other}],
                "trying to apply routes to a non-locked entry, ignoring"
            ),
            []
    end.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    Window = hpr_utils:get_env_int(routing_cache_window_secs, 120),
    Timeout = hpr_utils:get_env_int(routing_cache_timeout_secs, 15),
    TRef = erlang:send_after(0, self(), ?CLEANUP),
    {ok, #state{
        window = timer:seconds(Window),
        timeout = timer:seconds(Timeout),
        timer_ref = TRef
    }}.

-spec handle_call(Msg, _From, #state{}) -> {stop, {unimplemented_call, Msg}, #state{}}.
handle_call(Msg, _From, State) ->
    lager:warning("unknown call ~p", [Msg]),
    {stop, {unimplemented_call, Msg}, State}.

handle_cast(_Msg, State) ->
    lager:warning("unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(?CLEANUP, #state{window = Window, timeout = Timeout} = State) ->
    {Time0, NumDeleted} = timer:tc(fun() -> do_crawl_routing(Window) end),
    Time = erlang:convert_time_unit(Time0, microsecond, millisecond),
    lager:debug([{duration, Time}, {deleted, NumDeleted}], "routing cache cleanup"),
    TRef = erlang:send_after(Timeout, self(), ?CLEANUP),
    {noreply, State#state{timer_ref = TRef}};
handle_info(_Msg, State) ->
    lager:warning("unknown info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec do_crawl_routing(Window :: non_neg_integer()) -> NumDeleted :: non_neg_integer().
do_crawl_routing(Window) ->
    Now = erlang:system_time(millisecond) - Window,
    %% MS = ets:fun2ms(fun(#routing_entry{time = Time}) when Time < 1234 -> true end).
    MS = [{
        {routing_entry,
            '_',
            '$1',
            '_',
            '_',
            '_'
        },
        [{'<', '$1', Now}],
        [true]
    }],
    ets:select_delete(?ROUTING_ETS, MS).
