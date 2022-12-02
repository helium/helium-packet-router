-module(hpr_packet_router_downlink_handler).

-behaviour(grpcbox_client_stream).

-export([
    new_state/2,
    init/3,
    handle_message/2,
    handle_headers/2,
    handle_trailers/4,
    handle_eos/1
]).

-record(state, {
    gateway :: libp2p_crypto:pubkey_bin(),
    lns :: binary(),
    stream_id :: stream_id() | undefined
}).

-type stream_id() :: non_neg_integer().
-type state() :: #state{}.

-spec new_state(Gateway :: libp2p_crypto:pubkey_bin(), LNS :: binary()) -> state().
new_state(Gateway, LNS) ->
    #state{gateway = Gateway, lns = LNS}.

-spec init(pid(), stream_id(), term()) -> {ok, state()}.
init(_ConnectionPid, StreamId, State) ->
    {ok, State#state{stream_id = StreamId}}.

-spec handle_message(map(), state()) -> {ok, state()}.
handle_message(EnvDownMap, #state{gateway = Gateway} = CBData) ->
    lager:debug("sending router downlink"),
    EnvDown = hpr_envelope_down:to_record(EnvDownMap),
    {packet, PacketDown} = hpr_envelope_down:data(EnvDown),
    ok = hpr_packet_router_service:send_packet_down(Gateway, PacketDown),
    {ok, CBData}.

-spec handle_headers(map(), state()) -> {ok, state()}.
handle_headers(_Metadata, CBData) ->
    {ok, CBData}.

-spec handle_trailers(binary(), term(), map(), state()) -> {ok, state()}.
handle_trailers(_Status, _Message, _Metadata, CBData) ->
    {ok, CBData}.

-spec handle_eos(state()) -> {ok, state()}.
handle_eos(#state{gateway = Gateway, lns = LNS} = CBData) ->
    GatewayName = hpr_utils:gateway_name(Gateway),
    true = hpr_protocol_router:remove_stream(Gateway, LNS),
    lager:info(
        [{gateway, GatewayName}, {lns, erlang:binary_to_list(LNS)}],
        "stream going down"
    ),
    {ok, CBData}.
