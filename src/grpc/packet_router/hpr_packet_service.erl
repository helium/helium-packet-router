-module(hpr_packet_service).

-behaviour(helium_packet_router_packet_bhvr).

-export([
    init/2,
    route/2,
    handle_info/2
]).

-export([
    send_packet_down/2
]).

-define(REG_KEY(Gateway), {?MODULE, Gateway}).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    StreamState.

-spec route(hpr_envelope_up:envelope(), grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()} | {stop, grpcbox_stream:t()}.
route(EnvUp, StreamState) ->
    Self = self(),
    case hpr_envelope_up:data(EnvUp) of
        {packet, PacketUp} ->
            _ = erlang:spawn(hpr_routing, handle_packet, [PacketUp, Self]),
            {ok, StreamState};
        {register, Reg} ->
            PubkeyBin = hpr_register:gateway(Reg),
            case hpr_register:verify(Reg) of
                false ->
                    lager:info("failed to verify"),
                    {stop, StreamState};
                true ->
                    true = gproc:add_local_name(?REG_KEY(PubkeyBin)),
                    {ok, StreamState}
            end
    end.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({packet_down, PacketDown}, StreamState) ->
    EnvDown = hpr_envelope_down:new(PacketDown),
    grpcbox_stream:send(false, EnvDown, StreamState);
handle_info(_Msg, StreamState) ->
    StreamState.

-spec send_packet_down(
    PubkeyBin :: libp2p_crypto:pubkey_bin() | Pid :: pid(), PacketDown :: hpr_envelope_down:packet()
) -> ok | {error, not_found}.
send_packet_down(Pid, PacketDown) when is_pid(Pid) ->
    case erlang:is_process_alive(Pid) of
        true ->
            Pid ! {packet_down, PacketDown};
        false ->
            lager:warning("failed to send envelope_down to stream ~p", [Pid])
    end,
    ok;
send_packet_down(PubkeyBin, PacketDown) ->
    case gproc:lookup_local_name(?REG_KEY(PubkeyBin)) of
        Pid when is_pid(Pid) ->
            Pid ! {packet_down, PacketDown},
            ok;
        undefined ->
            lager:warning(
                [{gateway, hpr_utils:gateway_name(PubkeyBin)}],
                "failed to send PacketDown to stream"
            ),
            {error, not_found}
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
    Self = self(),
    PacketUp = hpr_packet_up:new(#{}),
    EnvUp = hpr_envelope_up:new(PacketUp),
    meck:expect(hpr_routing, handle_packet, [PacketUp, Self], ok),

    ?assertEqual({ok, stream_state}, ?MODULE:route(EnvUp, stream_state)),

    ?assertEqual(1, meck:num_calls(hpr_routing, handle_packet, 2)),

    meck:unload(hpr_routing),
    ok.

route_register_test() ->
    application:ensure_all_started(gproc),

    Self = self(),
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),
    Reg = hpr_register:new(Gateway),
    RegSigned = hpr_register:sign(Reg, SigFun),

    ?assertEqual({stop, stream_state}, ?MODULE:route(hpr_envelope_up:new(Reg), stream_state)),
    ?assertEqual({ok, stream_state}, ?MODULE:route(hpr_envelope_up:new(RegSigned), stream_state)),
    ?assertEqual(Self, gproc:lookup_local_name(?REG_KEY(Gateway))),

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

    ?assertEqual(stream_state, ?MODULE:handle_info({packet_down, PacketDown}, stream_state)),
    ?assertEqual(stream_state, ?MODULE:handle_info(msg, stream_state)),
    ?assertEqual(1, meck:num_calls(grpcbox_stream, send, 3)),

    meck:unload(grpcbox_stream),
    ok.

send_packet_down_test() ->
    application:ensure_all_started(gproc),

    #{public := PubKey0} = libp2p_crypto:generate_keys(ecc_compact),
    PubkeyBin0 = libp2p_crypto:pubkey_to_bin(PubKey0),
    PacketDown = hpr_packet_down:new_downlink(
        <<"data">>,
        1,
        2,
        'SF12BW125',
        undefined
    ),

    ?assertEqual({error, not_found}, ?MODULE:send_packet_down(PubkeyBin0, PacketDown)),
    ?assert(gproc:add_local_name(?REG_KEY(PubkeyBin0))),
    ?assertEqual(ok, ?MODULE:send_packet_down(PubkeyBin0, PacketDown)),

    receive
        {packet_down, PacketDownRcv} ->
            ?assertEqual(PacketDown, PacketDownRcv)
    after 50 ->
        ?assertEqual(PacketDown, timeout)
    end,

    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    PubkeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),
    Pid = erlang:spawn(
        fun() ->
            true = gproc:add_local_name(?REG_KEY(PubkeyBin1)),
            receive
                stop -> ok
            end
        end
    ),
    timer:sleep(10),
    ?assertEqual(ok, ?MODULE:send_packet_down(PubkeyBin1, PacketDown)),
    Pid ! stop,
    timer:sleep(10),
    ?assertEqual({error, not_found}, ?MODULE:send_packet_down(PubkeyBin1, PacketDown)),

    application:stop(gproc),
    ok.

-endif.
