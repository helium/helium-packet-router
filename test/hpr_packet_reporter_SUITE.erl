%%--------------------------------------------------------------------
%% @doc
%% To run this SUITE:
%% - `docker-compose -f docker-compose-ct.yaml up`
%% @end
%%--------------------------------------------------------------------
-module(hpr_packet_reporter_SUITE).

-include("hpr.hrl").

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    upload_test/1
]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        upload_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    ReporterCfg = application:get_env(?APP, packet_reporter, #{}),
    OSEnv = os:getenv("HPR_PACKET_REPORTER_LOCAL_HOST", "localhost"),
    ok = application:set_env(?APP, packet_reporter, ReporterCfg#{local_host => OSEnv}, [
        {persistent, true}
    ]),
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    %% Empty bucket for next test
    AWSClient = erlang:element(2, sys:get_state(hpr_packet_reporter)),
    Bucket = erlang:element(3, sys:get_state(hpr_packet_reporter)),
    {ok, #{<<"ListBucketResult">> := #{<<"Contents">> := Contents}}, _} = aws_s3:list_objects(
        AWSClient, Bucket
    ),
    Keys =
        case erlang:is_map(Contents) of
            true ->
                [maps:get(<<"Key">>, Contents)];
            false ->
                [maps:get(<<"Key">>, Content) || Content <- Contents]
        end,
    {ok, _, _} = aws_s3:delete_objects(
        AWSClient, Bucket, #{
            <<"Body">> => #{
                <<"Delete">> => [
                    #{<<"Object">> => #{<<"Key">> => Key}}
                 || Key <- Keys
                ]
            }
        }
    ),
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

upload_test(_Config) ->
    %% Send N packets
    N = 100,
    OUI = 1,
    NetID = 2,
    Route = hpr_route:new(#{oui => OUI, net_id => NetID}),
    ExpectedPackets = lists:foldl(
        fun(X, Acc) ->
            Packet = test_utils:uplink_packet_up(#{rssi => X}),
            hpr_packet_reporter:report_packet(Packet, Route),
            PacketReport = hpr_packet_report:to_record(#{
                gateway_timestamp_ms => hpr_packet_up:timestamp(Packet),
                oui => OUI,
                net_id => NetID,
                rssi => hpr_packet_up:rssi(Packet),
                frequency => hpr_packet_up:frequency(Packet),
                datarate => hpr_packet_up:datarate(Packet),
                snr => hpr_packet_up:snr(Packet),
                region => hpr_packet_up:region(Packet),
                gateway => hpr_packet_up:gateway(Packet),
                payload_hash => hpr_packet_up:phash(Packet)
            }),
            [PacketReport | Acc]
        end,
        [],
        lists:seq(1, N)
    ),

    %% Wait until packets are all in state
    ok = test_utils:wait_until(
        fun() ->
            State = sys:get_state(hpr_packet_reporter),
            N == erlang:length(erlang:element(6, State))
        end
    ),

    AWSClient = erlang:element(2, sys:get_state(hpr_packet_reporter)),
    Bucket = erlang:element(3, sys:get_state(hpr_packet_reporter)),

    %% Check that bucket is still empty
    {ok, #{<<"ListBucketResult">> := ListBucketResult0}, _} = aws_s3:list_objects(
        AWSClient, Bucket
    ),
    ?assertNot(maps:is_key(<<"Contents">>, ListBucketResult0)),

    %% Force upload
    hpr_packet_reporter ! upload,

    %% Wait unitl bucket report not empty
    ok = test_utils:wait_until(
        fun() ->
            {ok, #{<<"ListBucketResult">> := ListBucketResult}, _} = aws_s3:list_objects(
                AWSClient, Bucket
            ),
            maps:is_key(<<"Contents">>, ListBucketResult)
        end
    ),

    %% Check file name
    {ok, #{<<"ListBucketResult">> := #{<<"Contents">> := Contents}}, _} = aws_s3:list_objects(
        AWSClient, Bucket
    ),
    FileName = maps:get(<<"Key">>, Contents),
    [Prefix, Timestamp, Ext] = binary:split(FileName, <<".">>, [global]),
    ?assertEqual(<<"packetreport">>, Prefix),
    ?assert(erlang:binary_to_integer(Timestamp) < erlang:system_time(millisecond)),
    ?assert(
        erlang:binary_to_integer(Timestamp) > erlang:system_time(millisecond) - timer:seconds(2)
    ),
    ?assertEqual(<<"gz">>, Ext),

    %% Get file content and check that all packets are there
    {ok, #{<<"Body">> := Compressed}, _} = aws_s3:get_object(AWSClient, Bucket, FileName),
    ExtractedPackets = extract_packets(Compressed),
    ?assertEqual(ExpectedPackets, ExtractedPackets),

    ok.

%% ------------------------------------------------------------------
%% Helpers
%% ------------------------------------------------------------------

-spec extract_packets(Compressed :: binary()) -> [hpr_packet_report:packet_report()].
extract_packets(Compressed) ->
    UnCompressed = zlib:gunzip(Compressed),
    extract_packets(UnCompressed, []).

-spec extract_packets(Rest :: binary(), Acc :: [hpr_packet_report:packet_report()]) ->
    [hpr_packet_report:packet_report()].
extract_packets(<<>>, Acc) ->
    lists:reverse(Acc);
extract_packets(<<Size:32/big-integer-unsigned, Rest/binary>>, Acc) ->
    <<EncodedPacket:Size/binary, Rest2/binary>> = Rest,
    Packet = hpr_packet_report:decode(EncodedPacket),
    extract_packets(Rest2, [Packet | Acc]).
