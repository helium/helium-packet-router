-module(hpr_envelope_down).

-include("../autogen/server/packet_router_pb.hrl").

-export([
    new/1,
    data/1,
    to_map/1,
    to_record/1
]).

-type envelope() :: #envelope_down_v1_pb{}.

-export_type([envelope/0]).

-spec new(hpr_packet_down:packet()) -> envelope().
new(#packet_router_packet_down_v1_pb{} = Packet) ->
    #envelope_down_v1_pb{data = {packet, Packet}}.

-spec data(Env :: envelope()) -> {packet, hpr_packet_down:packet()}.
data(Env) ->
    Env#envelope_down_v1_pb.data.

-spec to_map(Env :: envelope()) -> map().
to_map(Env) ->
    client_packet_router_pb:decode_msg(
        packet_router_pb:encode_msg(Env),
        envelope_down_v1_pb
    ).

-spec to_record(map()) -> envelope().
to_record(MapEnv) ->
    packet_router_pb:decode_msg(
        client_packet_router_pb:encode_msg(MapEnv, envelope_down_v1_pb),
        envelope_down_v1_pb
    ).

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

to_map_test() ->
    EnvDown = ?MODULE:new(fake_down()),
    ?assertEqual(
        #{
            data =>
                {packet, #{
                    payload => <<>>,
                    rx1 => #{timestamp => 1, frequency => 2, datarate => 'SF12BW125'}
                }}
        },
        ?MODULE:to_map(EnvDown)
    ),
    ok.

fake_down() ->
    hpr_packet_down:new_downlink(
        <<>>,
        1,
        2,
        'SF12BW125',
        undefined
    ).

-endif.
