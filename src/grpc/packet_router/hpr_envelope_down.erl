-module(hpr_envelope_down).

-include("../autogen/packet_router_pb.hrl").

-export([
    new/1,
    data/1
]).

-type envelope() :: #envelope_down_v1_pb{}.

-export_type([envelope/0]).

-spec new(hpr_packet_down:packet()) -> envelope().
new(#packet_router_packet_down_v1_pb{} = Packet) ->
    #envelope_down_v1_pb{data = {packet, Packet}}.

-spec data(Env :: envelope()) -> {packet, hpr_packet_down:packet()}.
data(Env) ->
    Env#envelope_down_v1_pb.data.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

new_test() ->
    Packet = fake_down(),
    ?assertEqual(#envelope_down_v1_pb{data = {packet, Packet}}, ?MODULE:new(Packet)),
    ok.

data_test() ->
    Packet = fake_down(),
    EnvDown = ?MODULE:new(Packet),
    ?assertEqual({packet, Packet}, ?MODULE:data(EnvDown)),
    ok.

fake_down() ->
    hpr_packet_down:new_downlink(
        <<>>,
        1,
        2,
        'SF12BW125',
        <<"gateway">>,
        undefined
    ).

-endif.
