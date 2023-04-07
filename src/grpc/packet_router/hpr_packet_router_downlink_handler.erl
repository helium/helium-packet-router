-module(hpr_packet_router_downlink_handler).

-behaviour(grpcbox_client_stream).

-export([
    new_state/1,
    init/3,
    handle_message/2,
    handle_headers/2,
    handle_trailers/4,
    handle_eos/1
]).

-record(state, {
    lns :: binary(),
    conn_pid :: pid() | undefined,
    stream_id :: stream_id() | undefined
}).

-type stream_id() :: non_neg_integer().
-type state() :: #state{}.

-spec new_state(LNS :: binary()) -> state().
new_state(LNS) ->
    #state{lns = LNS}.

-spec init(pid(), stream_id(), state()) -> {ok, state()}.
init(ConnectionPid, StreamId, State) ->
    State1 = State#state{conn_pid = ConnectionPid, stream_id = StreamId},
    lager:debug(state_to_md(State1), "init"),
    {ok, State1}.

-spec handle_message(hpr_envelop_down:envelope(), state()) -> {ok, state()}.
handle_message(EnvDown, State) ->
    lager:debug(state_to_md(State), "sending router downlink"),
    _ = erlang:spawn(fun() ->
        {packet, PacketDown} = hpr_envelope_down:data(EnvDown),
        Gateway = hpr_packet_down:gateway(PacketDown),
        _ = hpr_packet_router_service:send_packet_down(Gateway, PacketDown)
    end),
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
handle_eos(State) ->
    lager:info(state_to_md(State), "stream going down"),
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec state_to_md(state()) -> list().
state_to_md(#state{conn_pid = ConnectionPid, stream_id = StreamId, lns = LNS}) ->
    [
        {conn_pid, ConnectionPid},
        {stream_id, StreamId},
        {lns, erlang:binary_to_list(LNS)}
    ].
