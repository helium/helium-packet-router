-module(hpr_protocol_router).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    init/0,
    send/3,
    get_stream/3,
    remove_stream/1, remove_stream/2,
    register/2
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

-ifdef(TEST).
-export([all_streams/0]).
-endif.

-define(SERVER, ?MODULE).
-define(STREAM_ETS, hpr_protocol_router_ets).
-define(KEY(Gateway, LNS), {Gateway, LNS}).
-define(CONNECTING, connecting).
-define(CONNECTING_FAILED, connecting_failed).
-define(BACKOFF_MIN, 10).
-define(BACKOFF_MAX, timer:seconds(5)).
-define(BACKOFF_RETRIES, 5).
-define(CLEANUP, '__cleanup').
-define(CLEANUP_TIMER, timer:minutes(10)).

-ifdef(TEST).
-define(CLEANUP_TIME, timer:seconds(1)).
-else.
-define(CLEANUP_TIME, timer:seconds(30)).
-endif.

-record(state, {waiting_cleanups :: map()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec init() -> ok.
init() ->
    ?STREAM_ETS = ets:new(?STREAM_ETS, [
        public, named_table, set, {read_concurrency, true}, {write_concurrency, true}
    ]),
    ok.

-spec send(
    PacketUp :: hpr_packet_up:packet(),
    Route :: hpr_route:route(),
    GatewayLocation :: {h3:index(), float(), float()} | undefined
) -> ok | {error, any()}.
send(PacketUp, Route, _GatewayLocation) ->
    Gateway = hpr_packet_up:gateway(PacketUp),
    LNS = hpr_route:lns(Route),
    Server = hpr_route:server(Route),
    case get_stream(Gateway, LNS, Server) of
        {ok, RouterStream} ->
            EnvUp = hpr_envelope_up:new(PacketUp),
            ok = grpcbox_client:send(RouterStream, EnvUp);
        {error, _} = Err ->
            Err
    end.

-spec get_stream(
    Gateway :: libp2p_crypto:pubkey_bin(),
    LNS :: binary(),
    Server :: hpr_route:server()
) -> {ok, grpcbox_client:stream()} | {error, any()}.
get_stream(Gateway, LNS, Server) ->
    Backoff = backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX),
    get_stream(Gateway, LNS, Server, Backoff, ?BACKOFF_RETRIES).

-spec remove_stream(Gateway :: libp2p_crypto:pubkey_bin()) -> ok.
remove_stream(Gateway) ->
    %% ets:fun2ms(fun({{1337, _}, _}=X) -> X end),
    %% ets:select(hpr_protocol_router_ets, [{{{GW, '_'}, '_'}, [], ['$_']}]),
    StreamEntries = ets:select(?STREAM_ETS, [{{{Gateway, '_'}, '_'}, [], ['$_']}]),
    lists:foreach(
        fun
            ({Key, {?CONNECTING, _Pid}}) ->
                true = ets:delete(?STREAM_ETS, Key),
                lager:debug("delete connecting pid");
            ({Key, Stream}) ->
                grpcbox_client:close_send(Stream),
                true = ets:delete(?STREAM_ETS, Key),
                lager:debug("closed stream")
        end,
        StreamEntries
    ).

-spec remove_stream(Gateway :: libp2p_crypto:pubkey_bin(), LNS :: binary()) -> ok.
remove_stream(Gateway, LNS) ->
    case ets:lookup(?STREAM_ETS, ?KEY(Gateway, LNS)) of
        [{_, {?CONNECTING, _Pid}}] ->
            true = ets:delete(?STREAM_ETS, ?KEY(Gateway, LNS)),
            lager:debug("delete connecting pid"),
            ok;
        [{_, Stream}] ->
            ok = grpcbox_client:close_send(Stream),
            true = ets:delete(?STREAM_ETS, ?KEY(Gateway, LNS)),
            lager:debug("closed stream"),
            ok;
        [] ->
            lager:debug("did not close stream"),
            ok
    end.

-spec register(PubKeyBin :: binary(), Pid :: pid()) -> ok.
register(PubKeyBin, Pid) ->
    gen_server:cast(?MODULE, {register, PubKeyBin, Pid}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    lager:debug("~p started", [?MODULE]),
    _ = schedule_cleanup(),
    {ok, #state{waiting_cleanups = #{}}}.

-spec handle_call(Msg, _From, #state{}) -> {stop, {unimplemented_call, Msg}, #state{}}.
handle_call(Msg, _From, State) ->
    lager:warning("unknown call ~p", [Msg]),
    {stop, {unimplemented_call, Msg}, State}.

handle_cast({register, PubKeyBin, Pid}, #state{waiting_cleanups = WaitingCleanups0} = State) ->
    %% Always monitor the new pid.
    _ = erlang:monitor(process, Pid, [{tag, {'DOWN', PubKeyBin}}]),
    WaitingCleanups1 =
        %% Is this the first time we're registering?
        case maps:take(PubKeyBin, WaitingCleanups0) of
            %% Yes, monitor and move along
            error ->
                WaitingCleanups0;
            {CleanupTimerRef, NewMap} ->
                TimeLeft = erlang:cancel_timer(CleanupTimerRef),
                Name = hpr_utils:gateway_name(PubKeyBin),
                lager:debug(
                    [{gateway, Name}, {time_left_ms, TimeLeft}, {stream, Pid}],
                    "gw registered while waiting to take down streams"
                ),
                NewMap
        end,

    {noreply, State#state{waiting_cleanups = WaitingCleanups1}};
handle_cast(_Msg, State) ->
    lager:warning("unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(?CLEANUP, State) ->
    SizeBefore = ets:info(?STREAM_ETS, size),
    %% ets:fun2ms(fun({_, M}=V) when is_map(M) -> V end).
    MS = [{{'_', '$1'}, [{is_map, '$1'}], ['$_']}],
    lists:foreach(
        fun({{Gateway, _} = Key, Stream}) ->
            case hpr_packet_router_service:locate(Gateway) of
                {ok, _} ->
                    ok;
                {error, _} ->
                    ok = grpcbox_client:close_send(Stream),
                    true = ets:delete(?STREAM_ETS, Key),
                    ok
            end
        end,
        ets:select(?STREAM_ETS, MS)
    ),
    SizeAfter = ets:info(?STREAM_ETS, size),
    lager:info("closed and removed ~w streams", [SizeBefore - SizeAfter]),
    ok = schedule_cleanup(),
    {noreply, State};
handle_info(
    {{'DOWN', Gateway}, _Monitor, process, _Pid, _ExitReason},
    #state{waiting_cleanups = WaitingCleanups} = State
) ->
    Name = hpr_utils:gateway_name(Gateway),
    lager:debug(
        [{gateway, Name}, {stream, _Pid}],
        "stream went down: ~p waiting ~wms",
        [_ExitReason, ?CLEANUP_TIME]
    ),
    CleanupTimer = erlang:send_after(?CLEANUP_TIME, self(), {remove_stream, Gateway}),
    {noreply, State#state{waiting_cleanups = WaitingCleanups#{Gateway => CleanupTimer}}};
handle_info({remove_stream, Gateway}, #state{waiting_cleanups = WaitingCleanups} = State) ->
    Name = hpr_utils:gateway_name(Gateway),
    lager:debug([{gateway, Name}], "removing streams"),
    ?MODULE:remove_stream(Gateway),
    {noreply, State#state{waiting_cleanups = maps:without([Gateway], WaitingCleanups)}};
handle_info(_Msg, State) ->
    lager:warning("unknown info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec schedule_cleanup() -> ok.
schedule_cleanup() ->
    _ = erlang:send_after(?CLEANUP_TIMER, self(), ?CLEANUP),
    ok.

-spec get_stream(
    Gateway :: libp2p_crypto:pubkey_bin(),
    LNS :: binary(),
    Server :: hpr_route:server(),
    Backoff :: backoff:backoff(),
    BackoffRetries :: non_neg_integer()
) -> {ok, grpcbox_client:stream()} | {error, any()}.
get_stream(_Gateway, _LNS, _Server, _Backoff0, 0) ->
    {error, max_retries};
get_stream(Gateway, LNS, Server, Backoff0, BackoffRetries) ->
    {Delay, BackoffFailed} = backoff:fail(Backoff0),

    Self = self(),
    ConnectingLock = {?KEY(Gateway, LNS), {?CONNECTING, Self}},

    CreateStream = fun() ->
        case create_stream(Gateway, LNS, Server) of
            {error, _} = Error ->
                true = ets:delete(?STREAM_ETS, ?KEY(Gateway, LNS)),
                Error;
            {ok, Stream} = OK ->
                case
                    ets:select_replace(?STREAM_ETS, [
                        {ConnectingLock, [], [{const, {?KEY(Gateway, LNS), Stream}}]}
                    ])
                of
                    1 ->
                        OK;
                    0 ->
                        ok = grpcbox_client:close_send(Stream),
                        {error, missing_lock}
                end
        end
    end,

    case ets:lookup(?STREAM_ETS, ?KEY(Gateway, LNS)) of
        [{_, {?CONNECTING, Self}}] ->
            %% No idea how we get here but lets go and create the stream
            CreateStream();
        [{_, {?CONNECTING, Pid}} = OldLock] ->
            case erlang:is_process_alive(Pid) of
                %% Somebody else is trying to connect
                true ->
                    timer:sleep(Delay),
                    get_stream(Gateway, LNS, Server, BackoffFailed, BackoffRetries - 1);
                false ->
                    case
                        ets:select_replace(
                            ?STREAM_ETS,
                            [{OldLock, [], [{const, ConnectingLock}]}]
                        )
                    of
                        %% we grabbed the lock, proceed by reconnecting
                        1 ->
                            CreateStream();
                        0 ->
                            timer:sleep(Delay),
                            get_stream(Gateway, LNS, Server, BackoffFailed, BackoffRetries - 1)
                    end
            end;
        [{_, #{channel := StreamSet, stream_pid := StreamPid} = Stream}] ->
            ConnPid = h2_stream_set:connection(StreamSet),
            case erlang:is_process_alive(ConnPid) andalso erlang:is_process_alive(StreamPid) of
                true ->
                    {ok, Stream};
                %% Connection or Stream are not alive lets delete and try to get a new one
                false ->
                    true = ets:delete(?STREAM_ETS, ?KEY(Gateway, LNS)),
                    get_stream(Gateway, LNS, Server, BackoffFailed, BackoffRetries - 1)
            end;
        [] ->
            case ets:insert_new(?STREAM_ETS, ConnectingLock) of
                %% some process already got the lock we will wait
                false ->
                    timer:sleep(Delay),
                    get_stream(Gateway, LNS, Server, BackoffFailed, BackoffRetries - 1);
                true ->
                    CreateStream()
            end
    end.

-spec create_stream(
    Gateway :: libp2p_crypto:pubkey_bin(),
    LNS :: binary(),
    Server :: hpr_route:server()
) -> {ok, grpcbox_client:stream()} | {error, any()}.
create_stream(Gateway, LNS, Server) ->
    case connect(LNS, Server) of
        {error, _} = Error ->
            Error;
        ok ->
            try
                helium_packet_router_packet_client:route(#{
                    channel => LNS,
                    callback_module => {
                        hpr_packet_router_downlink_handler,
                        hpr_packet_router_downlink_handler:new_state(Gateway, LNS)
                    }
                })
            of
                {error, _} = Error ->
                    Error;
                {ok, Stream} ->
                    {ok, Stream}
            catch
                _E:Reason:_S ->
                    {error, Reason}
            end
    end.

-spec connect(
    LNS :: binary(),
    Server :: hpr_route:server()
) -> ok | {error, any()}.
connect(LNS, Server) ->
    case grpcbox_channel:pick(LNS, stream) of
        %% No connection, lets try to connect
        {error, _} ->
            lager:debug("connecting for the first time: ~p", [LNS]),
            Host = hpr_route:host(Server),
            Port = hpr_route:port(Server),
            case
                grpcbox_client:connect(LNS, [{http, Host, Port, []}], #{
                    sync_start => true
                })
            of
                {ok, _Conn, _} -> connect(LNS, Server);
                {ok, _Conn} -> connect(LNS, Server);
                {error, _} = Error -> Error
            end;
        {ok, {_Conn, _Interceptor}} ->
            ok
    end.

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec all_streams() -> [{{libp2p_crypto:pubkey_bin(), binary()}, map()}].
all_streams() ->
    ets:tab2list(?STREAM_ETS).

-endif.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        {"test_full", ?_test(test_full())},
        {"test_cannot_locate_stream", ?_test(test_cannot_locate_stream())},
        {"test_cleanup", ?_test(test_cleanup())}
    ]}.

foreach_setup() ->
    application:ensure_all_started(gproc),
    meck:new(grpcbox_channel),
    meck:new(grpcbox_client),
    ?MODULE:init(),
    {ok, Pid} = ?MODULE:start_link(#{}),
    Pid.

foreach_cleanup(Pid) ->
    ok = gen_server:stop(Pid),
    true = ets:delete(?STREAM_ETS),
    meck:unload(grpcbox_channel),
    meck:unload(grpcbox_client),
    application:stop(gproc),
    ok.

test_full() ->
    Route = test_route(),
    LNS = hpr_route:lns(Route),

    SleepRandom = fun(X) -> timer:sleep(rand:uniform(X)) end,

    meck:expect(grpcbox_channel, pick, fun(_LNS, stream) ->
        SleepRandom(25),
        {ok, {undefined, undefined}}
    end),

    Stream = #{
        channel =>
            {stream_set, client, undefined, undefined, self(), undefined, undefined, undefined,
                false},
        stream_pid => self()
    },
    meck:expect(grpcbox_client, stream, fun(_Ctx, <<"/helium.packet_router.packet/route">>, _, _) ->
        SleepRandom(25),
        {ok, Stream}
    end),

    meck:expect(grpcbox_client, send, fun(_, _) -> ok end),

    PubKeyBin = <<"PubKeyBin">>,
    ok = hpr_packet_router_service:register(PubKeyBin),

    HprPacketUp = test_utils:join_packet_up(#{gateway => PubKeyBin}),

    NumPackets = 3,
    Self = self(),
    Pids = lists:map(
        fun(_X) ->
            erlang:spawn(fun() ->
                R = ?MODULE:send(HprPacketUp, Route),
                Self ! {send_result, R},
                receive
                    stop -> ok
                end
            end)
        end,
        lists:seq(1, NumPackets)
    ),
    timer:sleep(?CLEANUP_TIME + 100),

    ok = test_utils:wait_until(
        fun() ->
            NumPackets == rcv_send_result(0)
        end
    ),

    ?assertEqual(
        [{?KEY(PubKeyBin, LNS), Stream}], ets:lookup(?STREAM_ETS, ?KEY(PubKeyBin, LNS))
    ),
    ?assertEqual(1, meck:num_calls(grpcbox_channel, pick, [LNS, stream])),
    ?assert(erlang:is_process_alive(erlang:whereis(?MODULE))),

    [P ! stop || P <- Pids],
    ok.

test_cleanup() ->
    meck:expect(grpcbox_client, close_send, fun(_) -> ok end),
    ?assertEqual(0, ets:info(?STREAM_ETS, size)),

    Max = 10,
    LNS = <<"LNS">>,
    lists:foreach(
        fun(_) ->
            #{public := PubKey} = libp2p_crypto:generate_keys(ed25519),
            PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
            true = ets:insert(?STREAM_ETS, {?KEY(PubKeyBin, LNS), #{}})
        end,
        lists:seq(1, Max)
    ),
    ?assertEqual(10, ets:info(?STREAM_ETS, size)),
    ?MODULE ! ?CLEANUP,
    timer:sleep(10),
    ?assertEqual(0, ets:info(?STREAM_ETS, size)),
    ok.

%% We do not register a gateway to trigger cleanup
test_cannot_locate_stream() ->
    Route = test_route(),

    meck:expect(grpcbox_channel, pick, fun(_LNS, stream) -> {ok, {undefined, undefined}} end),

    Stream = #{
        channel =>
            {stream_set, client, undefined, undefined, self(), undefined, undefined, undefined,
                false},
        stream_pid => self()
    },
    meck:expect(grpcbox_client, stream, fun(_Ctx, <<"/helium.packet_router.packet/route">>, _, _) ->
        {ok, Stream}
    end),

    meck:expect(grpcbox_client, send, fun(_, _) -> ok end),
    meck:expect(grpcbox_client, close_send, fun(_) -> ok end),

    PubKeyBin = <<"PubKeyBin">>,
    HprPacketUp = test_utils:join_packet_up(#{gateway => PubKeyBin}),
    Self = self(),

    %% Cleanup is triggered for outgoing streams when the incoming stream dies.
    %% So we wrap the sender in a process so we it can be killed and start the cleanup.
    SenderPid = spawn(fun() ->
        ?MODULE:register(PubKeyBin, self()),
        ?assertEqual(ok, ?MODULE:send(HprPacketUp, Route)),
        receive
            stop ->
                Self ! stopped,
                ok
        end
    end),

    SenderPid ! stop,
    ok =
        receive
            stopped -> ok
        after timer:seconds(5) -> throw(sender_pid_never_stopped)
        end,

    ok = test_utils:wait_until(
        fun() ->
            0 == ets:info(?STREAM_ETS, size)
        end
    ),
    ?assert(erlang:is_process_alive(erlang:whereis(?MODULE))),
    ok.

rcv_send_result(C) ->
    receive
        {send_result, ok} ->
            rcv_send_result(C + 1)
    after 1000 ->
        C
    end.

test_route() ->
    Host = "example-lns.com",
    Port = 4321,
    hpr_route:test_new(#{
        id => "7d502f32-4d58-4746-965e-8c7dfdcfc624",
        net_id => 1,
        devaddr_ranges => [],
        euis => [],
        oui => 1,
        server => #{
            host => Host,
            port => Port,
            protocol => {packet_router, #{}}
        },
        max_copies => 1,
        nonce => 1
    }).

-endif.
