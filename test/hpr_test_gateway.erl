-module(hpr_test_gateway).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start/1,
    pubkey_bin/1,
    session_key/1,
    send_packet/2,
    receive_send_packet/1,
    receive_env_down/1,
    receive_register/1,
    receive_session_init/2,
    receive_stream_down/1,
    receive_terminate/1
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
-define(CONNECT, connect).
-define(RCV_LOOP, rcv_loop).
-define(RCV_TIMEOUT, 100).
-define(SEND_PACKET, send_packet).
-define(REGISTER, register).
-define(SESSION_INIT, session_init).
-define(STREAM_DOWN, stream_down).

-record(state, {
    forward :: pid(),
    route :: hpr_route:route(),
    eui_pairs :: [hpr_eui_pair:eui_pair()],
    devaddr_ranges :: [hpr_devaddr_range:devaddr_range()],
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    sig_fun :: libp2p_crypto:sig_fun(),
    stream :: grpcbox_client:stream(),
    session_key :: undefined | {libp2p_crypto:pubkey_bin(), libp2p_crypto:sig_fun()}
}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%%% API Function Definitions
%% ------------------------------------------------------------------

-spec start(Args :: map()) -> any().
start(Args) ->
    gen_server:start(?SERVER, Args, []).

-spec pubkey_bin(Pid :: pid()) -> libp2p_crypto:pubkey_bin().
pubkey_bin(Pid) ->
    gen_server:call(Pid, pubkey_bin).

-spec session_key(Pid :: pid()) -> binary().
session_key(Pid) ->
    gen_server:call(Pid, session_key).

-spec send_packet(Pid :: pid(), Args :: map()) -> ok.
send_packet(Pid, Args) ->
    gen_server:cast(Pid, {?SEND_PACKET, Args}).

-spec receive_send_packet(GatewayPid :: pid()) ->
    {ok, EnvDown :: hpr_envelope_up:envelope()} | {error, timeout}.
receive_send_packet(GatewayPid) ->
    receive
        {?MODULE, GatewayPid, {?SEND_PACKET, EnvUp}} ->
            {ok, EnvUp}
    after timer:seconds(2) ->
        {error, timeout}
    end.

-spec receive_env_down(GatewayPid :: pid()) ->
    {ok, EnvDown :: hpr_envelope_down:envelope()} | {error, timeout}.
receive_env_down(GatewayPid) ->
    receive
        {?MODULE, GatewayPid, {data, EnvDown}} ->
            {ok, EnvDown}
    after timer:seconds(2) ->
        {error, timeout}
    end.

-spec receive_register(GatewayPid :: pid()) ->
    {ok, EnvUp :: hpr_envelope_up:envelope()} | {error, timeout}.
receive_register(GatewayPid) ->
    receive
        {?MODULE, GatewayPid, {?REGISTER, EnvUp}} ->
            {ok, EnvUp}
    after timer:seconds(2) ->
        {error, timeout}
    end.

-spec receive_session_init(GatewayPid :: pid(), Timeout :: non_neg_integer()) ->
    {ok, EnvUp :: hpr_envelope_up:envelope()} | {error, timeout}.
receive_session_init(GatewayPid, Timeout) ->
    receive
        {?MODULE, GatewayPid, {?SESSION_INIT, EnvUp}} ->
            {ok, EnvUp}
    after Timeout ->
        {error, timeout}
    end.

-spec receive_stream_down(GatewayPid :: pid()) -> ok | {error, timeout}.
receive_stream_down(GatewayPid) ->
    receive
        {?MODULE, GatewayPid, ?STREAM_DOWN} ->
            ok
    after timer:seconds(2) ->
        {error, timeout}
    end.

-spec receive_terminate(GatewayPid :: pid()) -> {ok, any()} | {error, timeout}.
receive_terminate(GatewayPid) ->
    receive
        {?MODULE, GatewayPid, {terminate, Stream}} ->
            {ok, Stream}
    after timer:seconds(2) ->
        {error, timeout}
    end.

%% ------------------------------------------------------------------
%%% gen_server Function Definitions
%% ------------------------------------------------------------------
-spec init(map()) -> {ok, state()}.
init(
    #{forward := Pid, route := Route, eui_pairs := EUIPairs, devaddr_ranges := DevAddrRanges} = Args
) ->
    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ed25519),
    lager:info(maps:to_list(Args), "started"),
    ok = hpr_route_ets:insert_route(Route),
    ok = lists:foreach(fun hpr_route_ets:insert_eui_pair/1, EUIPairs),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, DevAddrRanges),
    self() ! ?CONNECT,
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    case maps:get(h3_index_str, Args, false) of
        IndexString when is_list(IndexString) ->
            ok = hpr_test_ics_gateway_service:register_gateway_location(
                PubKeyBin,
                IndexString
            );
        false ->
            ok
    end,
    {ok, #state{
        forward = Pid,
        route = Route,
        eui_pairs = EUIPairs,
        devaddr_ranges = DevAddrRanges,
        pubkey_bin = PubKeyBin,
        sig_fun = libp2p_crypto:mk_sig_fun(PrivKey)
    }}.

handle_call(pubkey_bin, _From, #state{pubkey_bin = PubKeyBin} = State) ->
    {reply, PubKeyBin, State};
handle_call(session_key, _From, #state{session_key = {SessionKey, _}} = State) ->
    {reply, SessionKey, State};
handle_call(_Msg, _From, State) ->
    lager:debug("unknown call ~p", [_Msg]),
    {reply, ok, State}.

handle_cast(
    {?SEND_PACKET, Args},
    #state{
        forward = Pid,
        devaddr_ranges = DevAddrRanges,
        pubkey_bin = PubKeyBin,
        sig_fun = SigFun,
        stream = Stream,
        session_key = undefined
    } =
        State
) ->
    DevAddr =
        case maps:get(devaddr, Args, undefined) of
            undefined ->
                [DevAddrRange | _] = DevAddrRanges,
                hpr_devaddr_range:start_addr(DevAddrRange);
            DevAddr0 ->
                DevAddr0
        end,
    PacketUp = test_utils:uplink_packet_up(Args#{
        gateway => PubKeyBin, sig_fun => SigFun, devaddr => DevAddr
    }),
    EnvUp = hpr_envelope_up:new(PacketUp),
    ok = grpcbox_client:send(Stream, EnvUp),
    Pid ! {?MODULE, self(), {?SEND_PACKET, EnvUp}},
    lager:debug("send_packet ~p", [EnvUp]),
    {noreply, State};
handle_cast(
    {?SEND_PACKET, Args},
    #state{
        forward = Pid,
        devaddr_ranges = DevAddrRanges,
        pubkey_bin = Gateway,
        stream = Stream,
        session_key = {_SessionKey, SigFun}
    } =
        State
) ->
    DevAddr =
        case maps:get(devaddr, Args, undefined) of
            undefined ->
                [DevAddrRange | _] = DevAddrRanges,
                hpr_devaddr_range:start_addr(DevAddrRange);
            DevAddr0 ->
                DevAddr0
        end,
    PacketUp = test_utils:uplink_packet_up(Args#{
        gateway => Gateway, sig_fun => SigFun, devaddr => DevAddr
    }),
    EnvUp = hpr_envelope_up:new(PacketUp),
    ok = grpcbox_client:send(Stream, EnvUp),
    Pid ! {?MODULE, self(), {?SEND_PACKET, EnvUp}},
    lager:debug("send_packet ~p", [EnvUp]),
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:debug("unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(?CONNECT, #state{forward = Pid, pubkey_bin = PubKeyBin, sig_fun = SigFun} = State) ->
    lager:debug("connecting"),
    case
        grpcbox_client:connect(PubKeyBin, [{http, "localhost", 8080, []}], #{
            sync_start => true
        })
    of
        {error, Reason} = Error ->
            Pid ! {?MODULE, self(), Error},
            {stop, Reason, State};
        % {ok, _Conn, _} -> ok;
        % {ok, _Conn} -> ok
        _ ->
            {ok, Stream} = helium_packet_router_packet_client:route(#{
                channel => PubKeyBin
            }),
            Reg = hpr_register:test_new(#{gateway => PubKeyBin, session_capable => true}),
            SignedReg = hpr_register:sign(Reg, SigFun),
            EnvUp = hpr_envelope_up:new(SignedReg),
            ok = grpcbox_client:send(Stream, EnvUp),
            Pid ! {?MODULE, self(), {?REGISTER, EnvUp}},
            lager:debug("connected and registering"),
            {noreply, State#state{stream = Stream}}
    end;
%% GRPC stream callbacks
handle_info(
    {data, _StreamID, EnvDown},
    #state{forward = Pid, pubkey_bin = Gateway, sig_fun = SigFun, stream = Stream} = State
) ->
    lager:debug("got EnvDown ~p", [EnvDown]),
    case hpr_envelope_down:data(EnvDown) of
        undefined ->
            {noreply, State};
        {packet, _Packet} ->
            Pid ! {?MODULE, self(), {data, EnvDown}},
            {noreply, State};
        {session_offer, SessionOffer} ->
            Nonce = hpr_session_offer:nonce(SessionOffer),
            #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ed25519),
            SessionKey = libp2p_crypto:pubkey_to_bin(PubKey),
            SessionInit = hpr_session_init:test_new(Gateway, Nonce, SessionKey),
            SignedSessionInit = hpr_session_init:sign(SessionInit, SigFun),
            EnvUp = hpr_envelope_up:new(SignedSessionInit),
            ok = grpcbox_client:send(Stream, EnvUp),
            Pid ! {?MODULE, self(), {session_init, EnvUp}},
            lager:debug("session initialized"),
            {noreply, State#state{session_key = {SessionKey, libp2p_crypto:mk_sig_fun(PrivKey)}}}
    end;
handle_info({headers, _StreamID, _Headers}, State) ->
    lager:debug("test gateway got headers ~p for ~w", [_Headers, _StreamID]),
    {noreply, State};
handle_info({trailers, _StreamID, _Trailers}, State) ->
    lager:debug("test gateway got trailers ~p for ~w", [_Trailers, _StreamID]),
    {noreply, State};
handle_info({eos, StreamID}, #state{forward = ForwardPid} = State) ->
    lager:debug("test gateway got eos for ~w", [StreamID]),
    ForwardPid ! {?MODULE, self(), ?STREAM_DOWN},
    {noreply, State#state{stream = undefined}};
handle_info(_Msg, State) ->
    lager:debug("unknown info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, #state{forward = Pid, pubkey_bin = PubKeyBin, stream = undefined}) ->
    ok = grpcbox_channel:stop(PubKeyBin),
    lager:debug("terminate ~p", [_Reason]),
    Pid ! {?MODULE, self(), {terminate, undefined}},
    ok;
terminate(_Reason, #state{forward = Pid, pubkey_bin = PubKeyBin, stream = Stream}) ->
    ok = grpcbox_client:close_send(Stream),
    ok = grpcbox_channel:stop(PubKeyBin),
    lager:debug("terminate ~p", [_Reason]),
    Pid ! {?MODULE, self(), {terminate, Stream}},
    ok.

%% ------------------------------------------------------------------
%%% Internal Function Definitions
%% ------------------------------------------------------------------
