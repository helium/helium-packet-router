-module(hpr_packet_service).

-behaviour(helium_packet_router_packet_bhvr).

-export([
    init/2,
    route/2,
    handle_info/2
]).

-export([
    send_downlink/2
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
            Gateway = hpr_register:gateway(Reg),
            case hpr_register:verify(Reg) of
                false ->
                    lager:info("failed to verify"),
                    {stop, StreamState};
                true ->
                    true = gproc:add_local_name(?REG_KEY(Gateway)),
                    {ok, StreamState}
            end
    end.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({downlink, PacketDown}, StreamState) ->
    EnvDown = hpr_envelope_down:new(PacketDown),
    grpcbox_stream:send(false, EnvDown, StreamState);
handle_info(_Msg, StreamState) ->
    StreamState.

-spec send_downlink(Pid :: pid(), EnvDown :: hpr_envelope_down:packet()) -> ok.
send_downlink(Pid, EnvDown) ->
    case erlang:is_process_alive(Pid) of
        true ->
            Pid ! {downlink, EnvDown};
        false ->
            lager:warning("failed to send envelope_down to stream ~p", [Pid])
    end,
    ok.

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

    ?assertEqual(stream_state, ?MODULE:handle_info({downlink, PacketDown}, stream_state)),
    ?assertEqual(stream_state, ?MODULE:handle_info(msg, stream_state)),
    ?assertEqual(1, meck:num_calls(grpcbox_stream, send, 3)),

    meck:unload(grpcbox_stream),
    ok.

-endif.
