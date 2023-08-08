-module(hpr_envelope_down).

-include("../autogen/packet_router_pb.hrl").

-export([
    new/1,
    data/1
]).

-type envelope() :: #envelope_down_v1_pb{}.

-export_type([envelope/0]).

-spec new(hpr_packet_down:packet() | hpr_session_offer:offer() | undefined) -> envelope().
new(undefined) ->
    #envelope_down_v1_pb{data = undefined};
new(#packet_router_packet_down_v1_pb{} = Packet) ->
    #envelope_down_v1_pb{data = {packet, Packet}};
new(#packet_router_session_offer_v1_pb{} = SessionOffer) ->
    #envelope_down_v1_pb{data = {session_offer, SessionOffer}}.

-spec data(Env :: envelope()) ->
    {packet, hpr_packet_down:packet()}
    | {session_offer, hpr_session_offer:offer()}.
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
    Offer = hpr_session_offer:new(<<"nonce">>),
    ?assertEqual(#envelope_down_v1_pb{data = {session_offer, Offer}}, ?MODULE:new(Offer)),
    ok.

data_test() ->
    Packet = fake_down(),
    ?assertEqual({packet, Packet}, ?MODULE:data(?MODULE:new(Packet))),
    Offer = hpr_session_offer:new(<<"nonce">>),
    ?assertEqual({session_offer, Offer}, ?MODULE:data(?MODULE:new(Offer))),
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
