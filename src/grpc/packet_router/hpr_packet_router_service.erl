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

-record(state, {started :: non_neg_integer()}).

-spec init(atom(), grpcbox_stream:t()) -> grpcbox_stream:t().
init(_Rpc, StreamState) ->
    HandlerState = #state{started = erlang:system_time(millisecond)},
    grpcbox_stream:stream_handler_state(StreamState, HandlerState).

-spec route(hpr_envelope_up:envelope(), grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()} | {stop, grpcbox_stream:t()}.
route(eos, StreamState) ->
    #state{started = Started} = grpcbox_stream:stream_handler_state(StreamState),
    _ = hpr_metrics:observe_grpc_connection(?MODULE, Started),
    lager:debug("received eos for stream"),
    {stop, StreamState};
route(EnvUp, StreamState) ->
    try hpr_envelope_up:data(EnvUp) of
        {packet, PacketUp} ->
            _ = erlang:spawn(hpr_routing, handle_packet, [PacketUp]),
            {ok, StreamState};
        {register, Reg} ->
            PubKeyBin = hpr_register:gateway(Reg),
            lager:md([{gateway, hpr_utils:gateway_name(PubKeyBin)}]),
            case hpr_register:verify(Reg) of
                false ->
                    lager:info("failed to verify"),
                    #state{started = Started} = grpcbox_stream:stream_handler_state(StreamState),
                    _ = hpr_metrics:observe_grpc_connection(?MODULE, Started),
                    {stop, StreamState};
                true ->
                    ok = ?MODULE:register(PubKeyBin),
                    {ok, StreamState}
            end
    catch
        _E:_R ->
            lager:warning("reason  ~p", [_R]),
            lager:warning("bad envelope ~p", [EnvUp]),
            #state{started = Started} = grpcbox_stream:stream_handler_state(StreamState),
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
    StreamState;
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
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

init_test() ->
    ?assertEqual(stream_state, ?MODULE:init(rpc, stream_state)),
    ok.

route_packet_test() ->
    meck:new(hpr_routing, [passthrough]),
    PacketUp = hpr_packet_up:test_new(#{}),
    EnvUp = hpr_envelope_up:new(PacketUp),
    meck:expect(hpr_routing, handle_packet, [PacketUp], ok),

    ?assertEqual({ok, stream_state}, ?MODULE:route(EnvUp, stream_state)),

    ?assertEqual(1, meck:num_calls(hpr_routing, handle_packet, 1)),

    meck:unload(hpr_routing),
    ok.

route_register_test() ->
    application:ensure_all_started(gproc),

    Self = self(),
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),
    Reg = hpr_register:test_new(Gateway),
    RegSigned = hpr_register:sign(Reg, SigFun),

    ?assertEqual({stop, stream_state}, ?MODULE:route(hpr_envelope_up:new(Reg), stream_state)),
    ?assertEqual({ok, stream_state}, ?MODULE:route(hpr_envelope_up:new(RegSigned), stream_state)),
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

    % timer:sleep(100),
    ?assertEqual(Pid, gproc:lookup_local_name(?REG_KEY(Gateway))),

    application:stop(gproc),
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
