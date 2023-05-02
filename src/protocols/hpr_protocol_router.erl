-module(hpr_protocol_router).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    init/0,
    send/2,
    get_stream/3,
    remove_stream/2
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
-define(BACKOFF_MIN, 10).
-define(BACKOFF_MAX, timer:seconds(1)).

-ifdef(TEST).
-define(CLEANUP_TIME, timer:seconds(1)).
-else.
-define(CLEANUP_TIME, timer:seconds(30)).
-endif.

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec init() -> ok.
init() ->
    ?STREAM_ETS = ets:new(?STREAM_ETS, [public, named_table, set, {read_concurrency, true}]),
    ok.

-spec send(
    PacketUp :: hpr_packet_up:packet(),
    Route :: hpr_route:route()
) -> ok | {error, any()}.
send(PacketUp, Route) ->
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
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    get_stream(Gateway, LNS, Server, Backoff).

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

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    lager:info("~p started", [?MODULE]),
    {ok, #state{}}.

-spec handle_call(Msg, _From, #state{}) -> {stop, {unimplemented_call, Msg}, #state{}}.
handle_call(Msg, _From, State) ->
    lager:warning("unknown call ~p", [Msg]),
    {stop, {unimplemented_call, Msg}, State}.

handle_cast({monitor, Gateway, LNS, Pid}, State) ->
    _ = erlang:monitor(process, Pid, [{tag, {'DOWN', Gateway, LNS}}]),
    lager:debug("monitoring gateway stream ~p", [Pid]),
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:warning("unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {{'DOWN', Gateway, LNS}, _Monitor, process, _Pid, _ExitReason},
    #state{} = State
) ->
    lager:debug("gateway stream ~p went down: ~p waiting ~wms", [_Pid, _ExitReason, ?CLEANUP_TIME]),
    ok = maybe_trigger_cleanup(Gateway, LNS),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("unknown info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec get_stream(
    Gateway :: libp2p_crypto:pubkey_bin(),
    LNS :: binary(),
    Server :: hpr_route:server(),
    Backoff :: backoff:backoff()
) -> {ok, grpcbox_client:stream()} | {error, any()}.
get_stream(Gateway, LNS, Server, Backoff0) ->
    {Delay, BackoffFailed} = backoff:fail(Backoff0),

    Self = self(),
    NewLock = {?KEY(Gateway, LNS), {?CONNECTING, Self}},

    CreateStream = fun() ->
        case create_stream(Gateway, LNS, Server) of
            {error, _} = Error ->
                true = ets:delete(?STREAM_ETS, ?KEY(Gateway, LNS)),
                Error;
            {ok, Stream} = OK ->
                1 = ets:select_replace(?STREAM_ETS, [
                    {NewLock, [], [{const, {?KEY(Gateway, LNS), Stream}}]}
                ]),
                ok = maybe_trigger_monitor(Gateway, LNS),
                OK
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
                    get_stream(Gateway, LNS, Server, BackoffFailed);
                false ->
                    case
                        ets:select_replace(
                            ?STREAM_ETS,
                            [{OldLock, [], [{const, NewLock}]}]
                        )
                    of
                        %% we grabbed the lock, proceed by reconnecting
                        1 ->
                            CreateStream();
                        0 ->
                            timer:sleep(Delay),
                            get_stream(Gateway, LNS, Server, BackoffFailed)
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
                    get_stream(Gateway, LNS, Server, BackoffFailed)
            end;
        [] ->
            case ets:insert_new(?STREAM_ETS, NewLock) of
                %% some process already got the lock we will wait
                false ->
                    timer:sleep(Delay),
                    get_stream(Gateway, LNS, Server, BackoffFailed);
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

-spec maybe_trigger_monitor(Gateway :: libp2p_crypto:pubkey_bin(), LNS :: binary()) -> ok.
maybe_trigger_monitor(Gateway, LNS) ->
    erlang:spawn(fun() ->
        case hpr_packet_router_service:locate(Gateway) of
            {ok, Pid} ->
                ok = gen_server:cast(?MODULE, {monitor, Gateway, LNS, Pid});
            {error, _Reason} ->
                lager:debug(
                    "failed to monitor gateway (~s) stream for lns (~s) ~p",
                    [
                        hpr_utils:gateway_name(Gateway), LNS, _Reason
                    ]
                ),
                %% Instead of doing a remove_stream, we trigger a maybe cleaup, we dont kill
                %% the stream to Router right away so if a downlink comes back and
                %% the gateway reconnected we can still send that downlink
                ok = maybe_trigger_cleanup(Gateway, LNS)
        end
    end),
    ok.

-spec maybe_trigger_cleanup(Gateway :: libp2p_crypto:pubkey_bin(), LNS :: binary()) -> ok.
maybe_trigger_cleanup(Gateway, LNS) ->
    erlang:spawn(fun() ->
        timer:sleep(?CLEANUP_TIME),
        case hpr_packet_router_service:locate(Gateway) of
            {error, _Reason} ->
                lager:debug("connot find a gateway stream: ~p, shutting down", [_Reason]),
                ?MODULE:remove_stream(Gateway, LNS);
            {ok, NewPid} ->
                ok = gen_server:cast(?MODULE, {monitor, Gateway, LNS, NewPid}),
                lager:debug("monitoring new gateway stream ~p", [NewPid])
        end
    end),
    ok.

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
        ?_test(test_full()),
        ?_test(test_cannot_locate_stream())
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
            {stream_set, client, undefined, undefined, self(), undefined, undefined, undefined},
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
    lists:foreach(
        fun(_X) ->
            erlang:spawn(fun() ->
                R = ?MODULE:send(HprPacketUp, Route),
                Self ! {send_result, R}
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
    ok.

%% We do not register a gateway to trigger cleanup
test_cannot_locate_stream() ->
    Route = test_route(),

    meck:expect(grpcbox_channel, pick, fun(_LNS, stream) -> {ok, {undefined, undefined}} end),

    Stream = #{
        channel =>
            {stream_set, client, undefined, undefined, self(), undefined, undefined, undefined},
        stream_pid => self()
    },
    meck:expect(grpcbox_client, stream, fun(_Ctx, <<"/helium.packet_router.packet/route">>, _, _) ->
        {ok, Stream}
    end),

    meck:expect(grpcbox_client, send, fun(_, _) -> ok end),
    meck:expect(grpcbox_client, close_send, fun(_) -> ok end),

    PubKeyBin = <<"PubKeyBin">>,
    HprPacketUp = test_utils:join_packet_up(#{gateway => PubKeyBin}),
    ?assertEqual(ok, ?MODULE:send(HprPacketUp, Route)),

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
