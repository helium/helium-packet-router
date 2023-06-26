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
    started :: non_neg_integer(),
    gateway :: libp2p_crypto:pubkey_bin(),
    lns :: binary(),
    conn_pid :: pid() | undefined,
    stream_id :: stream_id() | undefined
}).

-type stream_id() :: non_neg_integer().
-type state() :: #state{}.

-spec new_state(Gateway :: libp2p_crypto:pubkey_bin(), LNS :: binary()) -> state().
new_state(Gateway, LNS) ->
    #state{started = erlang:system_time(millisecond), gateway = Gateway, lns = LNS}.

-spec init(pid(), stream_id(), state()) -> {ok, state()}.
init(ConnectionPid, StreamId, State) ->
    State1 = State#state{
        started = erlang:system_time(millisecond), conn_pid = ConnectionPid, stream_id = StreamId
    },
    lager:debug(state_to_md(State1), "init"),
    {ok, State1}.

-spec handle_message(hpr_envelop_down:envelope(), state()) -> {ok, state()}.
handle_message(EnvDown, #state{gateway = Gateway} = State) ->
    lager:debug(state_to_md(State), "sending router downlink"),
    {packet, PacketDown} = hpr_envelope_down:data(EnvDown),
    _ = hpr_packet_router_service:send_packet_down(Gateway, PacketDown),
    {ok, State}.

-spec handle_headers(map(), state()) -> {ok, state()}.
handle_headers(_Metadata, State) ->
    lager:debug(state_to_md(State), "got headers ~p", [_Metadata]),
    {ok, State}.

-spec handle_trailers(binary(), term(), map(), state()) -> {ok, state()}.
handle_trailers(_Status, _Message, _Metadata, State) ->
    lager:debug(state_to_md(State), "got trailers ~s ~p ~p", [_Status, _Message, _Metadata]),
    {ok, State}.

-spec handle_eos(state()) -> {ok, state()}.
handle_eos(#state{started = Started, gateway = Gateway, lns = LNS} = State) ->
    ok = hpr_protocol_router:remove_stream(Gateway, LNS),
    _ = hpr_metrics:observe_grpc_connection(?MODULE, Started),
    lager:info(state_to_md(State), "stream going down"),
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec state_to_md(state()) -> list().
state_to_md(#state{stream_id = StreamId, gateway = Gateway, lns = LNS}) ->
    GatewayName = hpr_utils:gateway_name(Gateway),
    [
        {stream_id, StreamId},
        {gateway, GatewayName},
        {lns, erlang:binary_to_list(LNS)}
    ].
