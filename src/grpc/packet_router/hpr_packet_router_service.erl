-module(hpr_packet_router_service).

-behaviour(helium_packet_router_packet_bhvr).

-export([
    init/2,
    route/2,
    handle_info/2
]).

-export([
    send_packet_down/2,
    locate/1,
    register/1
]).

-define(REG_KEY(Gateway), {?MODULE, Gateway}).
-define(SESSION_TIMER, timer:minutes(35)).
-define(SESSION_KILL, session_kill).

-record(handler_state, {
    started :: non_neg_integer(),
    pubkey_bin :: undefined | binary(),
    nonce :: undefined | binary(),
    session_key :: undefined | binary(),
    last_phash = <<>> :: binary()
}).

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
    lager:debug("got env up ~p", [EnvUp]),
    try hpr_envelope_up:data(EnvUp) of
        {packet, PacketUp} ->
            handle_packet(PacketUp, StreamState);
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
        true,
        hpr_envelope_down:new(hpr_packet_ack:new(HandlerState#handler_state.last_phash)),
        grpcbox_stream:stream_handler_state(
            StreamState,
            HandlerState#handler_state{last_phash = <<>>})
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
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec handle_packet(PacketUp :: hpr_packet_up:packet(), StreamState0 :: grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()}.
handle_packet(PacketUp, StreamState) ->
    HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    Opts = #{
        session_key => HandlerState#handler_state.session_key,
        gateway => HandlerState#handler_state.pubkey_bin,
        stream_pid => self()
    },
    _ = erlang:spawn_opt(hpr_routing, handle_packet, [PacketUp, Opts], [{fullsweep_after, 0}]),
    {ok,
        grpcbox_stream:stream_handler_state(
            StreamState,
            HandlerState#handler_state{last_phash = hpr_packet_up:phash(PacketUp)}
        )}.

-spec handle_register(Reg :: hpr_register:register(), StreamState0 :: grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()}
    | {ok, hpr_envelope_down:envelope(), grpcbox_stream:t()}
    | {stop, grpcbox_stream:t()}.
handle_register(Reg, StreamState0) ->
    PubKeyBin = hpr_register:gateway(Reg),
    lager:md([{stream_gateway, hpr_utils:gateway_name(PubKeyBin)}]),
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
            %% Atttempt to get location from ICS to pre-cache data
            _ = hpr_gateway_location:get(PubKeyBin),
            HandlerState = grpcbox_stream:stream_handler_state(StreamState0),
            StreamState1 = grpcbox_stream:stream_handler_state(
                StreamState0, HandlerState#handler_state{pubkey_bin = PubKeyBin}
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
    meck:new(hpr_routing, [passthrough]),
    PacketUp = hpr_packet_up:test_new(#{}),
    EnvUp = hpr_envelope_up:new(PacketUp),
    meck:expect(hpr_routing, handle_packet, fun(_PacketUp, _Opts) -> ok end),

    StreamState = grpcbox_stream:stream_handler_state(
        #state{}, #handler_state{}
    ),

    ?assertEqual({ok, StreamState}, ?MODULE:route(EnvUp, StreamState)),
    ?assertEqual(1, meck:num_calls(hpr_routing, handle_packet, 2)),

    meck:unload(hpr_routing),
    ok.

route_register_test() ->
    meck:new(hpr_metrics, [passthrough]),
    meck:expect(hpr_metrics, observe_grpc_connection, fun(_, _) -> ok end),
    meck:new(hpr_gateway_location, [passthrough]),
    meck:expect(hpr_gateway_location, get, fun(_) -> ok end),
    application:ensure_all_started(gproc),

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
    meck:unload(hpr_metrics),
    meck:unload(hpr_gateway_location),
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
    meck:expect(hpr_metrics, observe_multi_buy, fun(_, _) -> ok end),

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
    meck:expect(hpr_metrics, observe_multi_buy, fun(_, _) -> ok end),

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

-endif.
