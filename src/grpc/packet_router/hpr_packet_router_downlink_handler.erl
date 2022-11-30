-module(hpr_packet_router_downlink_handler).

-behaviour(grpcbox_client_stream).

-export([
    init/3,
    handle_message/2,
    handle_headers/2,
    handle_trailers/4,
    handle_eos/1
]).

-record(state, {
    gateway :: libp2p_crypto:pubkey_bin(),
    stream_id :: stream_id()
}).

-type stream_id() :: non_neg_integer().
-type callback_data() :: #state{}.

-spec init(pid(), stream_id(), term()) -> {ok, callback_data()}.
init(_ConnectionPid, StreamId, #{gateway := Gateway}) ->
    {ok, #state{gateway = Gateway, stream_id = StreamId}}.

-spec handle_message(map(), callback_data()) -> {ok, callback_data()}.
handle_message(EnvDownMap, #state{gateway = Gateway} = CBData) ->
    lager:debug("sending router downlink"),
    EnvDown = hpr_envelope_down:to_record(EnvDownMap),
    {packet, PacketDown} = hpr_envelope_down:data(EnvDown),
    ok = hpr_packet_router_service:send_packet_down(Gateway, PacketDown),
    {ok, CBData}.

-spec handle_headers(map(), callback_data()) -> {ok, callback_data()}.
handle_headers(_Metadata, CBData) ->
    {ok, CBData}.

-spec handle_trailers(binary(), term(), map(), callback_data()) -> {ok, callback_data()}.
handle_trailers(_Status, _Message, _Metadata, CBData) ->
    {ok, CBData}.

-spec handle_eos(callback_data()) -> {ok, callback_data()}.
handle_eos(#state{gateway = Gateway} = CBData) ->
    GatewayName = hpr_utils:gateway_name(Gateway),
    RemoveCount = hpr_protocol_router:remove_stream(Gateway),
    lager:info(
        [{removed_count, RemoveCount}, {gateway, GatewayName}],
        "stream going down"
    ),
    {ok, CBData}.
