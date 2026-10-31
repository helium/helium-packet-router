-module(hpr_packet_router_service).

-behaviour(helium_packet_router_packet_bhvr).

-export([ip_key/0]).

-export([
    init/2,
    route/2,
    handle_info/2
]).
-export([
    send_packet_down/2,
    locate/1,
    register/1,
    connected_count/0,
    spread_sessions/1,
    spread_status/0,
    cancel_spread/0
]).

-ifdef(TEST).
-export([test_session_key/1]).
-endif.

-define(REG_KEY(Gateway), {?MODULE, Gateway}).
-define(IP_KEY, {?MODULE, ip}).
-define(SESSION_TIMER, timer:minutes(35)).
-define(SESSION_KILL, session_kill).
-define(SPREADER, hpr_session_spreader).

-record(handler_state, {
    started :: non_neg_integer(),
    pubkey_bin :: undefined | binary(),
    %% Resolved once at register time and handed to every packet via Opts.
    %% hpr_utils:gateway_name/1 is a base58check encode plus an md5 (~13us
    %% measured), and the router process was paying it per packet just to build
    %% lager metadata.
    gateway_name :: undefined | string(),
    nonce :: undefined | binary(),
    session_key :: undefined | binary(),
    last_phash = <<>> :: binary()
}).

-spec ip_key() -> ?IP_KEY.
ip_key() -> ?IP_KEY.

-spec init(atom(), grpcbox_stream:t()) -> grpcbox_stream:t().
init(_Rpc, StreamState) ->
    HandlerState = #handler_state{started = erlang:system_time(millisecond)},
    ok = schedule_session_kill(),
    grpcbox_stream:stream_handler_state(StreamState, HandlerState).

-spec route(hpr_envelope_up:envelope(), grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()}
    | {ok, hpr_envelope_down:envelope(), grpcbox_stream:t()}
    | {stop, grpcbox_stream:t()}.
route(eos, StreamState) ->
    #handler_state{started = Started} = grpcbox_stream:stream_handler_state(StreamState),
    _ = hpr_metrics:observe_grpc_connection(?MODULE, Started),
    lager:debug("received eos for stream"),
    {stop, StreamState};
route(EnvUp, StreamState) ->
    Timestamp = erlang:system_time(millisecond),
    lager:debug("got env up ~p", [EnvUp]),
    try hpr_envelope_up:data(EnvUp) of
        {packet, PacketUp} ->
            handle_packet(PacketUp, Timestamp, StreamState);
        {register, Reg} ->
            handle_register(Reg, StreamState);
        {session_init, SessionInit} ->
            handle_session_init(SessionInit, StreamState)
    catch
        _E:_R ->
            lager:warning("reason  ~p", [_R]),
            lager:warning("bad envelope ~p", [EnvUp]),
            #handler_state{started = Started} = grpcbox_stream:stream_handler_state(StreamState),
            _ = hpr_metrics:observe_grpc_connection(?MODULE, Started),
            {stop, StreamState}
    end.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({packet_down, PacketDown}, StreamState) ->
    lager:debug("received packet_down"),
    EnvDown = hpr_envelope_down:new(PacketDown),
    _ = hpr_metrics:packet_down(ok),
    grpcbox_stream:send(false, EnvDown, StreamState);
handle_info({give_away, NewPid, PubKeyBin}, StreamState) ->
    lager:info("give_away registration to ~p", [NewPid]),
    gproc:give_away({n, l, ?REG_KEY(PubKeyBin)}, NewPid),
    grpcbox_stream:send(true, hpr_envelope_down:new(undefined), StreamState);
handle_info({ack, N}, StreamState) ->
    HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    erlang:send_after(timer:seconds(N), self(), {ack, N}),
    grpcbox_stream:send(
        false,
        hpr_envelope_down:new(hpr_packet_ack:new(HandlerState#handler_state.last_phash)),
        grpcbox_stream:stream_handler_state(
            StreamState,
            HandlerState#handler_state{last_phash = <<>>}
        )
    );
handle_info(?SESSION_KILL, StreamState0) ->
    lager:debug("received session kill for stream"),
    grpcbox_stream:send(true, hpr_envelope_down:new(undefined), StreamState0);
handle_info(_Msg, StreamState) ->
    StreamState.

-spec send_packet_down(
    PubKeyBin :: libp2p_crypto:pubkey_bin(), PacketDown :: hpr_envelope_down:packet()
) -> ok | {error, not_found}.
send_packet_down(PubKeyBin, PacketDown) ->
    case ?MODULE:locate(PubKeyBin) of
        {ok, Pid} ->
            lager:debug("send_packet_down to ~p", [Pid]),
            Pid ! {packet_down, PacketDown},
            ok;
        {error, not_found} = Err ->
            lager:warning("failed to send PacketDown to stream: not_found"),
            _ = hpr_metrics:packet_down(not_found),
            Err
    end.

-spec locate(PubKeyBin :: libp2p_crypto:pubkey_bin()) -> {ok, pid()} | {error, not_found}.
locate(PubKeyBin) ->
    case gproc:lookup_local_name(?REG_KEY(PubKeyBin)) of
        Pid when is_pid(Pid) ->
            {ok, Pid};
        undefined ->
            {error, not_found}
    end.

-spec register(PubKeyBin :: libp2p_crypto:pubkey_bin()) -> ok.
register(PubKeyBin) ->
    Self = self(),
    case ?MODULE:locate(PubKeyBin) of
        {error, not_found} ->
            true = gproc:add_local_name(?REG_KEY(PubKeyBin)),
            lager:debug("register"),
            ok = hpr_protocol_router:register(PubKeyBin, Self),
            ok;
        {ok, Self} ->
            lager:info("nothing to do, already registered"),
            ok;
        {ok, OldPid} ->
            lager:warning("already registered to ~p, trying to give away", [OldPid]),
            OldPid ! {give_away, Self, PubKeyBin},
            ok
    end.

%% ------------------------------------------------------------------
%% Session spread
%%
%% gateway-rs reconnects exactly 30 minutes after each successful session, with
%% no jitter: its backoff applies jitter and *then* clamps to the 30 minute
%% max, which erases it. So anything that disconnects a lot of gateways at once
%% -- a restart, a deploy, a network blip -- leaves them reconnecting together
%% every 30 minutes from then on, and nothing ever spreads them out again.
%%
%% When HPR closes a stream (the same empty-envelope close as ?SESSION_KILL),
%% gateway-rs treats it as an error, reconnects within 5-6.5 seconds, and starts
%% its next 30 minutes from the new session. So closing each stream once, at a
%% uniformly random time in a window of 30 minutes or more, leaves the
%% reconnects spread evenly instead of arriving as one wave.
%%
%% Gateways are looked up again at the moment their close fires, not captured
%% up front: one that reconnects on its own during the window has a new stream
%% by then, and aiming at the old pid would let it keep its old phase. A gateway
%% no longer on this node by then is counted and skipped -- run the spread on
%% every node behind the same load balancer.
%% ------------------------------------------------------------------

-spec connected_count() -> non_neg_integer().
connected_count() ->
    length(connected_gateways()).

%% @doc Close every connected gateway's stream once, each at a random time
%% within `WindowMs'. Returns how many were scheduled. Only one spread runs at a
%% time on a node.
-spec spread_sessions(WindowMs :: pos_integer()) ->
    {ok, non_neg_integer()} | {error, already_running}.
spread_sessions(WindowMs) when is_integer(WindowMs), WindowMs > 0 ->
    spread_sessions(WindowMs, fun(W) -> rand:uniform(W) - 1 end).

-spec spread_sessions(
    WindowMs :: pos_integer(), DelayFun :: fun((pos_integer()) -> non_neg_integer())
) ->
    {ok, non_neg_integer()} | {error, already_running}.
spread_sessions(WindowMs, DelayFun) ->
    Gateways = connected_gateways(),
    Total = length(Gateways),
    Spreader = erlang:spawn(fun() -> spread_wait_go(Total, WindowMs) end),
    try erlang:register(?SPREADER, Spreader) of
        true ->
            %% Timers aimed at the spreader, not at the streams: see above.
            lists:foreach(
                fun(Gateway) ->
                    erlang:send_after(DelayFun(WindowMs), Spreader, {spread_close, Gateway})
                end,
                Gateways
            ),
            Spreader ! go,
            lager:info("spreading ~w gateway sessions over ~wms", [Total, WindowMs]),
            {ok, Total}
    catch
        error:badarg ->
            exit(Spreader, kill),
            {error, already_running}
    end.

-spec spread_status() ->
    not_running
    | {running, #{
        total := non_neg_integer(),
        closed := non_neg_integer(),
        not_found := non_neg_integer(),
        ends_in_ms := integer()
    }}.
spread_status() ->
    case erlang:whereis(?SPREADER) of
        undefined ->
            not_running;
        Pid ->
            Ref = erlang:monitor(process, Pid),
            Pid ! {status, self(), Ref},
            receive
                {Ref, Status} ->
                    erlang:demonitor(Ref, [flush]),
                    {running, Status};
                {'DOWN', Ref, process, Pid, _} ->
                    not_running
            after 5000 ->
                erlang:demonitor(Ref, [flush]),
                not_running
            end
    end.

%% @doc Stop a running spread. Closes still pending are dropped: their timers
%% are aimed at the spreader, so they go nowhere once it is gone.
-spec cancel_spread() -> ok | not_running.
cancel_spread() ->
    case erlang:whereis(?SPREADER) of
        undefined ->
            not_running;
        Pid ->
            exit(Pid, kill),
            lager:info("session spread cancelled"),
            ok
    end.

-spec connected_gateways() -> [libp2p_crypto:pubkey_bin()].
connected_gateways() ->
    gproc:select({l, n}, [{{{n, l, ?REG_KEY('$1')}, '_', '_'}, [], ['$1']}]).

%% Holds until the caller has armed every timer, so a zero delay cannot be
%% counted before the spread is fully set up.
spread_wait_go(Total, WindowMs) ->
    receive
        go ->
            Deadline = erlang:monotonic_time(millisecond) + WindowMs,
            spread_loop(#{total => Total, closed => 0, not_found => 0, deadline => Deadline})
    end.

spread_loop(#{total := Total, closed := Closed, not_found := NotFound}) when
    Closed + NotFound >= Total
->
    lager:info("session spread done: ~w closed, ~w no longer on this node", [Closed, NotFound]);
spread_loop(#{deadline := Deadline} = S) ->
    receive
        {spread_close, Gateway} ->
            case ?MODULE:locate(Gateway) of
                {ok, Pid} ->
                    Pid ! ?SESSION_KILL,
                    ok = hpr_metrics:session_spread(closed),
                    spread_loop(S#{closed => maps:get(closed, S) + 1});
                {error, not_found} ->
                    ok = hpr_metrics:session_spread(not_found),
                    spread_loop(S#{not_found => maps:get(not_found, S) + 1})
            end;
        {status, From, Ref} ->
            Status = maps:with([total, closed, not_found], S),
            EndsIn = Deadline - erlang:monotonic_time(millisecond),
            From ! {Ref, Status#{ends_in_ms => EndsIn}},
            spread_loop(S)
    after
        %% Every timer fires within the window, so this only guards against a
        %% spreader left waiting forever if something unexpected happens.
        max(0, Deadline - erlang:monotonic_time(millisecond)) + timer:minutes(1) ->
            lager:warning("session spread gave up waiting: ~p", [maps:remove(deadline, S)])
    end.

-ifdef(TEST).

%% Named accessor so suites do not index into #handler_state{} positionally --
%% adding a field silently shifts every element/2 index after it, and the failure
%% shows up as an unrelated-looking assertion in a CT suite (see the same note in
%% hpr_packet_reporter). The grpcbox_stream digging lives here too, next to the
%% record it depends on.
-spec test_session_key(Pid :: pid()) -> undefined | binary().
test_session_key(Pid) ->
    State = sys:get_state(Pid),
    StreamState = erlang:element(2, State),
    CallbackState = erlang:element(20, StreamState),
    HandlerState = erlang:element(3, CallbackState),
    HandlerState#handler_state.session_key.

-endif.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec handle_packet(
    PacketUp :: hpr_packet_up:packet(),
    Timestamp :: non_neg_integer(),
    StreamState0 :: grpcbox_stream:t()
) ->
    {ok, grpcbox_stream:t()}.
handle_packet(PacketUp, Timestamp, StreamState) ->
    HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    %% Hashed once here and shared: we need it for last_phash regardless, and the
    %% router process would otherwise hash the payload again for its metadata.
    PHash = hpr_packet_up:phash(PacketUp),
    %% Admission control before the spawn. The rate limits used to be applied
    %% inside the routing process, so a gateway flushing a buffer -- which is
    %% what a fleet does when it reconnects -- got a process per packet, and its
    %% metadata built, before anything could say no. Two ETS lookups here make a
    %% rejected packet cost nothing but those lookups. hpr_routing is told the
    %% limits already ran, so the budget is consumed once.
    %%
    %% The budget is the gateway this stream registered as, and a packet
    %% claiming any other is turned away before it touches one: the packet's
    %% gateway field is not verified yet, so charging it would let one hotspot
    %% spend another's limits. hpr_routing's gateway_check rejects the same
    %% packets; this only does it before the throttles instead of after.
    Gateway = HandlerState#handler_state.pubkey_bin,
    Admitted =
        case hpr_packet_up:gateway(PacketUp) of
            Gateway -> hpr_routing:admit(Gateway, PHash);
            _Other -> {error, wrong_gateway}
        end,
    case Admitted of
        {error, _Reason} = Error ->
            lager:debug("packet not admitted: ~p", [_Reason]),
            _ = hpr_metrics:observe_packet_up(
                hpr_packet_up:type(PacketUp), Error, 0, Timestamp
            ),
            ok;
        ok ->
            Opts = #{
                session_key => HandlerState#handler_state.session_key,
                gateway => Gateway,
                gateway_name => HandlerState#handler_state.gateway_name,
                phash => PHash,
                stream_pid => self(),
                timestamp => Timestamp,
                admitted => true
            },
            _ = erlang:spawn_opt(
                hpr_routing, handle_packet, [PacketUp, Opts], [{fullsweep_after, 0}]
            ),
            ok
    end,
    %% Recorded either way: last_phash is what the packet ack echoes back, and
    %% we did receive the packet even when we declined to route it.
    {ok,
        grpcbox_stream:stream_handler_state(
            StreamState,
            HandlerState#handler_state{last_phash = PHash}
        )}.

-spec handle_register(Reg :: hpr_register:register(), StreamState0 :: grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()}
    | {ok, hpr_envelope_down:envelope(), grpcbox_stream:t()}
    | {stop, grpcbox_stream:t()}.
handle_register(Reg, StreamState0) ->
    PubKeyBin = hpr_register:gateway(Reg),
    ok = record_ip(StreamState0, PubKeyBin),
    GatewayName = hpr_utils:gateway_name(PubKeyBin),
    lager:md([{stream_gateway, GatewayName}]),
    case hpr_register:verify(Reg) of
        false ->
            lager:warning("failed to verify register"),
            #handler_state{started = Started} = grpcbox_stream:stream_handler_state(
                StreamState0
            ),
            _ = hpr_metrics:observe_grpc_connection(?MODULE, Started),
            {stop, StreamState0};
        true ->
            ok = ?MODULE:register(PubKeyBin),
            ok = hpr_gateway_liveness_storage:record_connect(PubKeyBin),
            %% Atttempt to get location from ICS to pre-cache data
            _ = hpr_gateway_location:get(PubKeyBin),
            HandlerState = grpcbox_stream:stream_handler_state(StreamState0),
            StreamState1 = grpcbox_stream:stream_handler_state(
                StreamState0, HandlerState#handler_state{
                    pubkey_bin = PubKeyBin, gateway_name = GatewayName
                }
            ),
            case hpr_register:packet_ack_interval(Reg) of
                N when is_integer(N), N > 0 ->
                    erlang:send_after(timer:seconds(N), self(), {ack, N});
                _ ->
                    ok
            end,
            case hpr_register:session_capable(Reg) of
                true ->
                    {EnvDown, StreamState2} = create_session_offer(StreamState1),
                    {ok, EnvDown, StreamState2};
                false ->
                    {ok, StreamState1}
            end
    end.

-spec handle_session_init(Reg :: hpr_session_init:init(), StreamState :: grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()} | {stop, grpcbox_stream:t()}.
handle_session_init(SessionInit, StreamState) ->
    case hpr_session_init:verify(SessionInit) of
        false ->
            lager:warning("failed to verify session init"),
            {stop, StreamState};
        true ->
            HandlerState0 = grpcbox_stream:stream_handler_state(StreamState),
            Nonce = hpr_session_init:nonce(SessionInit),
            SessionKey = hpr_session_init:session_key(SessionInit),
            case Nonce == HandlerState0#handler_state.nonce of
                false ->
                    lager:warning("nonce did not match ~s vs ~s key=~s", [
                        hpr_utils:bin_to_hex_string(Nonce),
                        hpr_utils:bin_to_hex_string(HandlerState0#handler_state.nonce),
                        libp2p_crypto:bin_to_b58(SessionKey)
                    ]),
                    {ok, StreamState};
                true ->
                    lager:debug("session init nonce=~s key=~s", [
                        hpr_utils:bin_to_hex_string(Nonce),
                        libp2p_crypto:bin_to_b58(SessionKey)
                    ]),
                    HandlerState1 = HandlerState0#handler_state{session_key = SessionKey},
                    {ok, grpcbox_stream:stream_handler_state(StreamState, HandlerState1)}
            end
    end.

-spec create_session_offer(StreamState0 :: grpcbox_stream:t()) ->
    {hpr_envelope_down:envelope(), grpcbox_stream:t()}.
create_session_offer(StreamState0) ->
    HandlerState0 = grpcbox_stream:stream_handler_state(StreamState0),
    Nonce = crypto:strong_rand_bytes(32),
    EnvDown = hpr_envelope_down:new(hpr_session_offer:new(Nonce)),
    StreamState1 = grpcbox_stream:stream_handler_state(
        StreamState0, HandlerState0#handler_state{nonce = Nonce}
    ),
    lager:debug("session offer ~s", [
        hpr_utils:bin_to_hex_string(Nonce)
    ]),
    {EnvDown, StreamState1}.

-spec schedule_session_kill() -> ok.
schedule_session_kill() ->
    erlang:send_after(?SESSION_TIMER, self(), ?SESSION_KILL),
    ok.

-spec record_ip(StreamState :: grpcbox_stream:t(), PubKeyBin :: libp2p_crypto:pubkey_bin()) -> ok.
record_ip(StreamState, PubKeyBin) ->
    case get_ip_port(StreamState) of
        {ok, IP} ->
            true = gproc:add_local_property(?IP_KEY, {IP, PubKeyBin}),
            lager:debug("IP recorded ~p for ~p", [IP, PubKeyBin]);
        {error, _R} ->
            lager:warning("failed to get IP for ~p : ~p", [PubKeyBin, _R])
    end.

-spec get_ip_port(StreamState :: grpcbox_stream:t()) -> {ok, string()} | {error, any()}.
get_ip_port(StreamState) ->
    try
        {_, Socket} = element(4, StreamState),
        case inet:peername(Socket) of
            {ok, {IP, Port}} ->
                IPString = inet_parse:ntoa(IP),
                {ok, lists:concat([IPString, ":", integer_to_list(Port)])};
            {error, Reason} ->
                {error, Reason}
        end
    catch
        C:E:S ->
            lager:debug("ERROR ~p ~p ~p", [C, E, S]),
            {error, E}
    end.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-record(state, {
    handler,
    stream_handler_state,
    socket,
    auth_fun,
    buffer,
    ctx,
    services_table,
    req_headers = [],
    full_method,
    connection_pid,
    request_encoding,
    response_encoding,
    content_type,
    resp_headers = [],
    resp_trailers = [],
    headers_sent = false,
    trailers_sent = false,
    unary_interceptor,
    stream_interceptor,
    stream_id,
    method,
    stats_handler,
    stats
}).

init_test() ->
    StreamState = ?MODULE:init(rpc, #state{}),
    #handler_state{started = Started} = grpcbox_stream:stream_handler_state(StreamState),
    ?assert(Started > 0),
    ok.

route_packet_test() ->
    %% handle_packet/3 now consults the rate limits before spawning, so the
    %% throttle tables have to exist -- in the release hpr_routing:init/0 runs
    %% from hpr_sup before the grpc server accepts anything.
    {ok, _} = application:ensure_all_started(throttle),
    ok = hpr_routing:init(),
    meck:new(hpr_routing, [passthrough]),
    PacketUp = hpr_packet_up:test_new(#{}),
    EnvUp = hpr_envelope_up:new(PacketUp),
    meck:expect(hpr_routing, handle_packet, fun(_PacketUp, _Opts) -> ok end),

    meck:new(hpr_metrics, [passthrough]),

    %% Registered as the gateway the packet names, as a real stream is.
    StreamState = grpcbox_stream:stream_handler_state(
        #state{},
        #handler_state{
            last_phash = hpr_packet_up:phash(PacketUp),
            pubkey_bin = hpr_packet_up:gateway(PacketUp)
        }
    ),

    ?assertEqual({ok, StreamState}, ?MODULE:route(EnvUp, StreamState)),
    %% Wait for the spawned process to execute (handle_packet spawns a process)
    timer:sleep(100),
    ?assertEqual(1, meck:num_calls(hpr_routing, handle_packet, 2)),

    meck:unload(hpr_routing),
    meck:unload(hpr_metrics),
    ok.

%% A packet over its gateway's rate limit must be dropped without a process
%% being spawned for it -- that is the whole point of moving the check here.
route_packet_not_admitted_test() ->
    {ok, _} = application:ensure_all_started(throttle),
    ok = hpr_routing:init(),
    meck:new(hpr_routing, [passthrough]),
    meck:expect(hpr_routing, handle_packet, fun(_PacketUp, _Opts) -> ok end),
    meck:expect(hpr_routing, admit, fun(_Gateway, _PHash) ->
        {error, gateway_limit_exceeded}
    end),
    meck:new(hpr_metrics, [passthrough]),
    meck:expect(hpr_metrics, observe_packet_up, fun(_, _, _, _) -> ok end),

    PacketUp = hpr_packet_up:test_new(#{}),
    EnvUp = hpr_envelope_up:new(PacketUp),
    StreamState = grpcbox_stream:stream_handler_state(
        #state{}, #handler_state{pubkey_bin = hpr_packet_up:gateway(PacketUp)}
    ),

    ?assertMatch({ok, _}, ?MODULE:route(EnvUp, StreamState)),
    timer:sleep(100),
    ?assertEqual(0, meck:num_calls(hpr_routing, handle_packet, 2)),
    ?assertEqual(1, meck:num_calls(hpr_metrics, observe_packet_up, 4)),

    meck:unload(hpr_routing),
    meck:unload(hpr_metrics),
    ok.

route_register_test() ->
    meck:new(hpr_metrics, [passthrough]),
    meck:expect(hpr_metrics, observe_grpc_connection, fun(_, _) -> ok end),
    meck:new(hpr_gateway_location, [passthrough]),
    meck:expect(hpr_gateway_location, get, fun(_) -> ok end),
    meck:new(hpr_gateway_liveness_storage, [passthrough]),
    meck:expect(hpr_gateway_liveness_storage, record_connect, fun(_) -> ok end),
    application:ensure_all_started(gproc),
    application:ensure_all_started(lager),

    Self = self(),
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),
    Reg = hpr_register:test_new(Gateway),
    RegSigned = hpr_register:sign(Reg, SigFun),

    StreamState = ?MODULE:init(rpc, #state{}),
    ?assertMatch({stop, _}, ?MODULE:route(hpr_envelope_up:new(Reg), StreamState)),
    ?assertMatch({ok, _}, ?MODULE:route(hpr_envelope_up:new(RegSigned), StreamState)),
    ?assertEqual(Self, gproc:lookup_local_name(?REG_KEY(Gateway))),

    Pid = erlang:spawn(fun() ->
        ok = ?MODULE:register(Gateway),
        timer:sleep(5000)
    end),

    receive
        {give_away, Pid, Gateway} ->
            ?assertEqual(Pid, gproc:give_away({n, l, ?REG_KEY(Gateway)}, Pid))
    after 1000 ->
        ?assert(true == timeout)
    end,

    ?assertEqual(Pid, gproc:lookup_local_name(?REG_KEY(Gateway))),

    application:stop(gproc),
    application:stop(lager),
    meck:unload(hpr_metrics),
    meck:unload(hpr_gateway_location),
    meck:unload(hpr_gateway_liveness_storage),
    ok.

handle_info_test() ->
    meck:new(grpcbox_stream, [passthrough]),

    PacketDown = hpr_packet_down:new_downlink(
        <<"data">>,
        1,
        2,
        'SF12BW125',
        undefined
    ),
    EnvDown = hpr_envelope_down:new(PacketDown),
    meck:expect(grpcbox_stream, send, [false, EnvDown, stream_state], stream_state),

    meck:new(hpr_metrics, [passthrough]),
    meck:expect(hpr_metrics, packet_down, fun(_) -> ok end),
    meck:expect(hpr_metrics, observe_multi_buy, fun(_, _, _) -> ok end),

    ?assertEqual(stream_state, ?MODULE:handle_info({packet_down, PacketDown}, stream_state)),
    ?assertEqual(stream_state, ?MODULE:handle_info(msg, stream_state)),
    ?assertEqual(1, meck:num_calls(grpcbox_stream, send, 3)),

    meck:unload(hpr_metrics),
    meck:unload(grpcbox_stream),
    ok.

send_packet_down_test() ->
    application:ensure_all_started(gproc),

    meck:new(hpr_metrics, [passthrough]),
    meck:expect(hpr_metrics, packet_down, fun(_) -> ok end),
    meck:expect(hpr_metrics, observe_multi_buy, fun(_, _, _) -> ok end),

    #{public := PubKey0} = libp2p_crypto:generate_keys(ed25519),
    PubKeyBin0 = libp2p_crypto:pubkey_to_bin(PubKey0),
    PacketDown = hpr_packet_down:new_downlink(
        <<"data">>,
        1,
        2,
        'SF12BW125',
        undefined
    ),

    ?assertEqual({error, not_found}, ?MODULE:send_packet_down(PubKeyBin0, PacketDown)),
    ?assert(gproc:add_local_name(?REG_KEY(PubKeyBin0))),
    ?assertEqual(ok, ?MODULE:send_packet_down(PubKeyBin0, PacketDown)),

    receive
        {packet_down, PacketDownRcv} ->
            ?assertEqual(PacketDown, PacketDownRcv)
    after 50 ->
        ?assertEqual(PacketDown, timeout)
    end,

    #{public := PubKey1} = libp2p_crypto:generate_keys(ed25519),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),
    Pid = erlang:spawn(
        fun() ->
            true = gproc:add_local_name(?REG_KEY(PubKeyBin1)),
            receive
                stop -> ok
            end
        end
    ),
    timer:sleep(10),
    ?assertEqual(ok, ?MODULE:send_packet_down(PubKeyBin1, PacketDown)),
    Pid ! stop,
    timer:sleep(10),
    ?assertEqual({error, not_found}, ?MODULE:send_packet_down(PubKeyBin1, PacketDown)),

    meck:unload(hpr_metrics),
    application:stop(gproc),
    ok.

spread_sessions_test() ->
    application:ensure_all_started(gproc),
    meck:new(hpr_metrics, [passthrough]),
    meck:expect(hpr_metrics, session_spread, fun(_) -> ok end),
    Self = self(),

    [Stay1, Stay2, Moves, Leaves] =
        Gateways = [<<"stay1">>, <<"stay2">>, <<"moves">>, <<"leaves">>],
    Streams = maps:from_list([{G, start_fake_stream(G, Self)} || G <- Gateways]),
    ?assertEqual(4, ?MODULE:connected_count()),

    %% Every close fires at 200ms, so the changes below land before any of them.
    ?assertEqual({ok, 4}, spread_sessions(timer:seconds(1), fun(_Window) -> 200 end)),
    ?assertEqual({error, already_running}, ?MODULE:spread_sessions(1000)),
    ?assertMatch(
        {running, #{total := 4, closed := 0, not_found := 0}}, ?MODULE:spread_status()
    ),

    %% One gateway reconnects on a new stream before its close fires; one is gone.
    ok = stop_fake_stream(maps:get(Moves, Streams)),
    NewMovesStream = start_fake_stream(Moves, Self),
    ok = stop_fake_stream(maps:get(Leaves, Streams)),

    %% Each gateway still here is closed exactly once, on the stream holding it
    %% when the close fires -- the new stream for the one that moved.
    ?assertEqual(
        lists:sort([
            {Stay1, maps:get(Stay1, Streams)},
            {Stay2, maps:get(Stay2, Streams)},
            {Moves, NewMovesStream}
        ]),
        lists:sort(collect_session_kills(3, 1000))
    ),
    ?assertEqual([], collect_session_kills(1, 300)),

    ok = wait_for_no_spreader(),
    ?assertEqual(not_running, ?MODULE:spread_status()),
    ?assertEqual(3, meck:num_calls(hpr_metrics, session_spread, [closed])),
    ?assertEqual(1, meck:num_calls(hpr_metrics, session_spread, [not_found])),

    [
        ok = stop_fake_stream(P)
     || P <- [maps:get(Stay1, Streams), maps:get(Stay2, Streams), NewMovesStream]
    ],
    meck:unload(hpr_metrics),
    application:stop(gproc),
    ok.

cancel_spread_test() ->
    application:ensure_all_started(gproc),
    meck:new(hpr_metrics, [passthrough]),
    meck:expect(hpr_metrics, session_spread, fun(_) -> ok end),
    Stream = start_fake_stream(<<"cancelled">>, self()),

    ?assertEqual({ok, 1}, spread_sessions(timer:seconds(1), fun(_Window) -> 200 end)),
    ?assertEqual(ok, ?MODULE:cancel_spread()),
    ok = wait_for_no_spreader(),
    ?assertEqual(not_running, ?MODULE:spread_status()),
    ?assertEqual(not_running, ?MODULE:cancel_spread()),
    %% The pending close went nowhere.
    ?assertEqual([], collect_session_kills(1, 400)),

    %% Nothing connected is a spread that finishes straight away.
    ok = stop_fake_stream(Stream),
    ?assertEqual({ok, 0}, ?MODULE:spread_sessions(1000)),
    ok = wait_for_no_spreader(),

    meck:unload(hpr_metrics),
    application:stop(gproc),
    ok.

%% Stands in for a gateway's stream process: holds the gateway's name and
%% reports what it is sent.
start_fake_stream(Gateway, Parent) ->
    Pid = erlang:spawn(fun() ->
        true = gproc:add_local_name(?REG_KEY(Gateway)),
        Parent ! {fake_stream_up, self()},
        fake_stream_loop(Gateway, Parent)
    end),
    receive
        {fake_stream_up, Pid} -> Pid
    after 1000 -> error(fake_stream_did_not_start)
    end.

fake_stream_loop(Gateway, Parent) ->
    receive
        {stop, From} ->
            gproc:unreg({n, l, ?REG_KEY(Gateway)}),
            From ! {fake_stream_stopped, self()};
        Msg ->
            Parent ! {fake_stream_got, Gateway, self(), Msg},
            fake_stream_loop(Gateway, Parent)
    end.

stop_fake_stream(Pid) ->
    Pid ! {stop, self()},
    receive
        {fake_stream_stopped, Pid} -> ok
    after 1000 -> error(fake_stream_did_not_stop)
    end.

collect_session_kills(0, _Timeout) ->
    [];
collect_session_kills(N, Timeout) ->
    receive
        {fake_stream_got, Gateway, Pid, ?SESSION_KILL} ->
            [{Gateway, Pid} | collect_session_kills(N - 1, Timeout)]
    after Timeout -> []
    end.

wait_for_no_spreader() ->
    wait_for_no_spreader(50).

wait_for_no_spreader(0) ->
    error(spreader_still_running);
wait_for_no_spreader(N) ->
    case erlang:whereis(?SPREADER) of
        undefined ->
            ok;
        _ ->
            timer:sleep(20),
            wait_for_no_spreader(N - 1)
    end.

-endif.
