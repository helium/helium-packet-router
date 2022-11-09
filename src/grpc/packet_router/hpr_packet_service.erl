-module(hpr_packet_service).

-behaviour(helium_packet_router_packet_bhvr).

-export([
    init/2,
    route/2,
    handle_info/2
]).

-export([
    envelope_down/2
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    StreamState.

-spec route(hpr_envelope_up:envelope(), grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
route(Env, StreamState) ->
    Self = self(),
    case hpr_envelope_up:data(Env) of
        {packet, PacketUp} ->
            _ = erlang:spawn(hpr_routing, handle_packet, [PacketUp, Self]);
        {register, _Reg} ->
            %% TODO
            ok
    end,
    {ok, StreamState}.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({envelope_down, EnvDown}, StreamState) ->
    grpcbox_stream:send(false, EnvDown, StreamState);
handle_info(_Msg, StreamState) ->
    StreamState.

-spec envelope_down(Pid :: pid(), EnvDown :: hpr_envelope_down:packet()) -> ok.
envelope_down(Pid, EnvDown) ->
    case erlang:is_process_alive(Pid) of
        true ->
            Pid ! {envelope_down, EnvDown};
        false ->
            lager:warning("failed to send envelope_down to stream ~p", [Pid])
    end,
    ok.
