-module(hpr_session_offer).

-include("../autogen/packet_router_pb.hrl").

-export([
    new/1,
    nonce/1
]).

-type offer() :: #packet_router_session_offer_v1_pb{}.

-export_type([offer/0]).

-spec new(Nonce :: binary()) -> offer().
new(Nonce) ->
    #packet_router_session_offer_v1_pb{nonce = Nonce}.

-spec nonce(Offer :: offer()) -> binary().
nonce(Offer) ->
    Offer#packet_router_session_offer_v1_pb.nonce.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

new_test() ->
    Nonce = <<"nonce">>,
    ?assertEqual(#packet_router_session_offer_v1_pb{nonce = Nonce}, ?MODULE:new(Nonce)),
    ok.

nonce_test() ->
    Nonce = <<"nonce">>,
    Offer = ?MODULE:new(Nonce),
    ?assertEqual(Nonce, ?MODULE:nonce(Offer)),
    ok.

-endif.
