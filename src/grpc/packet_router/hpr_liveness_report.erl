-module(hpr_liveness_report).

-include("../autogen/packet_router_pb.hrl").

-export([
    new/3,
    gateway/1,
    server/1,
    timestamp/1,
    encode/1,
    decode/1
]).

-ifdef(TEST).

-export([
    test_new/1
]).

-endif.

-type liveness_report() :: #packet_router_liveness_report_v1_pb{}.

-export_type([liveness_report/0]).

-spec new(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Server :: unicode:chardata(),
    LastSeen :: non_neg_integer()
) -> liveness_report().
new(PubKeyBin, Server, LastSeen) ->
    #packet_router_liveness_report_v1_pb{
        gateway = PubKeyBin,
        server = Server,
        timestamp = LastSeen
    }.

-spec gateway(LivenessReport :: liveness_report()) -> binary().
gateway(LivenessReport) ->
    LivenessReport#packet_router_liveness_report_v1_pb.gateway.

%% @doc Note: `server' is a protobuf `string' field. gpb always decodes it
%% back to a list, even if a binary was supplied via `new/3'.
-spec server(LivenessReport :: liveness_report()) -> unicode:chardata() | undefined.
server(LivenessReport) ->
    LivenessReport#packet_router_liveness_report_v1_pb.server.

-spec timestamp(LivenessReport :: liveness_report()) -> non_neg_integer() | undefined.
timestamp(LivenessReport) ->
    LivenessReport#packet_router_liveness_report_v1_pb.timestamp.

-spec encode(LivenessReport :: liveness_report()) -> binary().
encode(#packet_router_liveness_report_v1_pb{} = LivenessReport) ->
    packet_router_pb:encode_msg(LivenessReport).

-spec decode(BinaryReport :: binary()) -> liveness_report().
decode(BinaryReport) ->
    packet_router_pb:decode_msg(BinaryReport, packet_router_liveness_report_v1_pb).

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec test_new(Opts :: map()) -> liveness_report().
test_new(Opts) ->
    #packet_router_liveness_report_v1_pb{
        gateway = maps:get(gateway, Opts, <<"gateway">>),
        server = maps:get(server, Opts, <<"hpr">>),
        timestamp = maps:get(timestamp, Opts, erlang:system_time(millisecond))
    }.

-endif.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

gateway_test() ->
    LivenessReport = test_new(#{gateway => <<"gateway">>}),
    ?assertEqual(<<"gateway">>, gateway(LivenessReport)),
    ok.

server_test() ->
    LivenessReport = test_new(#{server => <<"hpr-1">>}),
    ?assertEqual(<<"hpr-1">>, server(LivenessReport)),
    ok.

timestamp_test() ->
    Now = erlang:system_time(millisecond),
    LivenessReport = test_new(#{timestamp => Now}),
    ?assertEqual(Now, timestamp(LivenessReport)),
    ok.

encode_decode_test() ->
    LivenessReport = test_new(#{}),
    Decoded = decode(encode(LivenessReport)),
    ?assertEqual(gateway(LivenessReport), gateway(Decoded)),
    %% `server' is a protobuf `string' field: gpb decodes it back as a list
    %% regardless of what type (binary or list) was supplied on encode.
    ?assertEqual(erlang:binary_to_list(server(LivenessReport)), server(Decoded)),
    ?assertEqual(timestamp(LivenessReport), timestamp(Decoded)),
    ok.

new_test() ->
    Now = erlang:system_time(millisecond),
    ?assertEqual(
        test_new(#{gateway => <<"gateway">>, server => <<"hpr-1">>, timestamp => Now}),
        ?MODULE:new(<<"gateway">>, <<"hpr-1">>, Now)
    ).

-endif.
