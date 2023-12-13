-module(hpr_packet_ack).

-include("../autogen/packet_router_pb.hrl").

-export([
    new/1
]).

-type packet_ack() :: #packet_router_packet_ack_v1_pb{}.

-export_type([packet_ack/0]).

-spec new(PHash :: binary()) -> packet_ack().
new(PHash) ->
    #packet_router_packet_ack_v1_pb{payload_hash = PHash}.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

new_test() ->
    PHash = <<"packet_hash">>,
    ?assertEqual(#packet_router_packet_ack_v1_pb{payload_hash = PHash}, new(PHash)),
    ok.

-endif.
