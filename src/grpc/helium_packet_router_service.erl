-module(helium_packet_router_service).

%% TODO use https://github.com/helium/proto/pull/157 but maybe wait
%% for https://github.com/helium/helium-packet-router/pull/22

%% See proto_files subsection in ../config/grpc_server_gen.config
-behaviour(helium_router_bhvr).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

-ifdef(TEST).
-define(TIMEOUT, 5000).
-else.
-define(TIMEOUT, 8000).
-endif.

-export([
    route/2
]).

%% TODO the `route()` rpc call already existed within Helium "proto"
%% repo which was originally used by "router" repo.  In future we
%% could create `packet_router()` rpc call that takes just `packet`
%% protobuf, but we're keeping with the state-channel version just in
%% case there's some bit of information that we may need from gateways.

route(Ctx, #blockchain_state_channel_message_v1_pb{msg = {packet, SCPacket}} = _Message) ->
    lager:info("executing RPC route with msg ~p", [_Message]),
    %% Handle the packet and then await response.
    %% If no response within given time, then give up and return error.
    _ = packet_routing:handle_packet(SCPacket, erlang:system_time(millisecond), self()),
    wait_for_response(Ctx).

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
wait_for_response(Ctx) ->
    receive
        {send_response, Resp} ->
            lager:debug("received response msg ~p", [Resp]),
            {ok, #blockchain_state_channel_message_v1_pb{msg = {response, Resp}}, Ctx};
        {packet, Packet} ->
            lager:debug("received packet ~p", [Packet]),
            {ok, #blockchain_state_channel_message_v1_pb{msg = {packet, Packet}}, Ctx}
    after ?TIMEOUT ->
        lager:debug("failed to receive response msg after ~p seconds", [?TIMEOUT]),
        {grpc_error, {grpcbox_stream:code_to_status(2), <<"no response">>}}
    end.
