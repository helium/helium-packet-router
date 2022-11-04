-module(hpr_packet_service).

-behaviour(helium_packet_router_packet_bhvr).

-export([
    init/2,
    route/2,
    handle_info/2
]).

-export([
    packet_down/2
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    StreamState.

-spec route(hpr_packet_up:packet(), grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
route(PacketUp, StreamState) ->
    Self = self(),
    _ = erlang:spawn(hpr_routing, handle_packet, [PacketUp, Self]),
    {ok, StreamState}.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({reply, Reply}, StreamState) ->
    grpcbox_stream:send(false, Reply, StreamState);
handle_info({http_reply, Reply}, StreamState) ->
    grpcbox_stream:send(false, Reply, StreamState);
handle_info({router_reply, ReplyMap}, StreamState) ->
    Reply = hpr_packet_down:to_record(ReplyMap),
    grpcbox_stream:send(false, Reply, StreamState);
handle_info(_Msg, StreamState) ->
    StreamState.

-spec packet_down(Pid :: pid(), PacketDown :: hpr_packet_down:packet()) -> ok.
packet_down(Pid, PacketDown) ->
    case erlang:is_process_alive(Pid) of
        true ->
            Pid ! {packet_down, PacketDown};
        false ->
            lager:warning("failed to send packet_down to stream ~p", [Pid])
    end,
    ok.
