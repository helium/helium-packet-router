-module(hpr_envelope_up).

-include("../autogen/packet_router_pb.hrl").

-export([
    new/1,
    data/1
]).

-type envelope() :: #envelope_up_v1_pb{}.

-export_type([envelope/0]).

-spec new(hpr_packet_up:packet() | hpr_register:register() | hpr_session_init:session()) ->
    envelope().
new(#packet_router_register_v1_pb{} = Reg) ->
    #envelope_up_v1_pb{data = {register, Reg}};
new(#packet_router_packet_up_v1_pb{} = Packet) ->
    #envelope_up_v1_pb{data = {packet, Packet}};
new(#packet_router_session_init_v1_pb{} = SessionInit) ->
    #envelope_up_v1_pb{data = {session_init, SessionInit}}.

-spec data(Env :: envelope()) ->
    {register, hpr_register:register()}
    | {packet, hpr_packet_up:packet()}
    | {session_init, hpr_session_init:session()}.
data(Env) ->
    Env#envelope_up_v1_pb.data.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

new_test() ->
    Packet = hpr_packet_up:test_new(#{}),
    ?assertEqual(#envelope_up_v1_pb{data = {packet, Packet}}, ?MODULE:new(Packet)),
    Reg = hpr_register:test_new(<<"gateway">>),
    ?assertEqual(#envelope_up_v1_pb{data = {register, Reg}}, ?MODULE:new(Reg)),
    SessionInit = hpr_session_init:test_new(<<"gateway">>, <<"nonce">>, <<"session_key">>),
    ?assertEqual(#envelope_up_v1_pb{data = {session_init, SessionInit}}, ?MODULE:new(SessionInit)),
    ok.

data_test() ->
    Packet = hpr_packet_up:test_new(#{}),
    ?assertEqual({packet, Packet}, ?MODULE:data(?MODULE:new(Packet))),
    Reg = hpr_register:test_new(<<"gateway">>),
    ?assertEqual({register, Reg}, ?MODULE:data(?MODULE:new(Reg))),
    SessionInit = hpr_session_init:test_new(<<"gateway">>, <<"nonce">>, <<"session_key">>),
    ?assertEqual({session_init, SessionInit}, ?MODULE:data(?MODULE:new(SessionInit))),
    ok.

-endif.
