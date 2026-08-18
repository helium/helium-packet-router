%%--------------------------------------------------------------------
%% @doc
%% To run this SUITE:
%% - `make test-aws`, which brings up rustfs and runs both reporter suites.
%% Or manually: `docker compose up -d --wait` then
%% `./rebar3 ct --suite=hpr_packet_reporter_SUITE`.
%% The endpoint comes from config/ct.config; CI overrides it with
%% HPR_TEST_S3_ENDPOINT because rustfs resolves under another hostname there.
%% @end
%%--------------------------------------------------------------------
-module(hpr_packet_reporter_SUITE).

-include_lib("eunit/include/eunit.hrl").

-include("hpr.hrl").
-include("hpr_metrics.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    upload_test/1,
    free_net_ids_test/1
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
        upload_test,
        free_net_ids_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    ok = maybe_override_endpoint(packet_reporter),
    test_utils:init_per_testcase(TestCase, Config).

%% ct.config points at rustfs on localhost. CI runs the suites inside a
%% container where rustfs resolves under a different hostname, so it overrides
%% the endpoint rather than duplicating the whole reporter config.
maybe_override_endpoint(Key) ->
    case os:getenv("HPR_TEST_S3_ENDPOINT") of
        false ->
            ok;
        Endpoint ->
            Cfg = application:get_env(hpr, Key, #{}),
            application:set_env(hpr, Key, Cfg#{
                aws_endpoint => erlang:list_to_binary(Endpoint)
            })
    end.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    %% Empty bucket for next test
    State = sys:get_state(hpr_packet_reporter),
    ok = empty_bucket(
        hpr_packet_reporter:get_client(State),
        hpr_packet_reporter:get_bucket(State)
    ),
    test_utils:end_per_testcase(TestCase, Config).

%% rustfs does not implement the batch DeleteObjects API (aws_s3:delete_objects/3
%% returns an error against it), so objects are removed one key at a time.
empty_bucket(AWSClient, Bucket) ->
    {ok, #{<<"ListBucketResult">> := ListBucketResult}, _} = aws_s3:list_objects(
        AWSClient, Bucket
    ),
    Keys =
        case maps:get(<<"Contents">>, ListBucketResult, undefined) of
            undefined ->
                [];
            Contents when erlang:is_map(Contents) ->
                [maps:get(<<"Key">>, Contents)];
            Contents ->
                [maps:get(<<"Key">>, Content) || Content <- Contents]
        end,
    lists:foreach(
        fun(Key) ->
            {ok, _, _} = aws_s3:delete_object(AWSClient, Bucket, Key, #{})
        end,
        Keys
    ).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

upload_test(_Config) ->
    %% Send N packets
    N = 100,
    OUI = 1,
    NetID = 2,
    Route = hpr_route:test_new(#{
        id => "test-route",
        oui => OUI,
        net_id => NetID,
        devaddr_ranges => [],
        euis => [],
        max_copies => 1,
        nonce => 1,
        server => #{host => "example.com", port => 8080, protocol => undefined}
    }),
    ExpectedPackets = lists:map(
        fun(X) ->
            Time = erlang:system_time(millisecond),
            Packet = test_utils:uplink_packet_up(#{rssi => X}),
            hpr_packet_reporter:report_packet(
                Packet, Route, false, Time
            ),
            hpr_packet_report:new(Packet, Route, false, Time)
        end,
        lists:seq(1, N)
    ),

    %% Wait until packets are all in state
    ok = test_utils:wait_until(
        fun() ->
            State = sys:get_state(hpr_packet_reporter),
            N == erlang:length(hpr_packet_reporter:get_current_packets(State))
        end
    ),

    State = sys:get_state(hpr_packet_reporter),
    AWSClient = hpr_packet_reporter:get_client(State),
    Bucket = hpr_packet_reporter:get_bucket(State),

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
    ?assertEqual(lists:sort(ExpectedPackets), lists:sort(ExtractedPackets)),

    timer:sleep(100),
    ?assertNotEqual(
        undefined,
        prometheus_histogram:value(?METRICS_PACKET_REPORT_HISTOGRAM, [ok])
    ),

    ok.

free_net_ids_test(_Config) ->
    %% Send N packets
    N = 100,
    OUI = 1,
    NetID = 16#C00053,
    Route = hpr_route:test_new(#{
        id => "test-route",
        oui => OUI,
        net_id => NetID,
        devaddr_ranges => [],
        euis => [],
        max_copies => 1,
        nonce => 1,
        server => #{host => "example.com", port => 8080, protocol => undefined}
    }),
    ExpectedPackets = lists:map(
        fun(X) ->
            Time = erlang:system_time(millisecond),
            Packet = test_utils:uplink_packet_up(#{rssi => X}),
            %% No reported free here
            hpr_packet_reporter:report_packet(
                Packet, Route, false, Time
            ),
            %% Should be after checking NetID
            hpr_packet_report:new(Packet, Route, true, Time)
        end,
        lists:seq(1, N)
    ),

    %% Wait until packets are all in state
    ok = test_utils:wait_until(
        fun() ->
            State = sys:get_state(hpr_packet_reporter),
            N == erlang:length(hpr_packet_reporter:get_current_packets(State))
        end
    ),

    State = sys:get_state(hpr_packet_reporter),
    AWSClient = hpr_packet_reporter:get_client(State),
    Bucket = hpr_packet_reporter:get_bucket(State),

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
    ?assertEqual(lists:sort(ExpectedPackets), lists:sort(ExtractedPackets)),

    timer:sleep(100),
    ?assertNotEqual(
        undefined,
        prometheus_histogram:value(?METRICS_PACKET_REPORT_HISTOGRAM, [ok])
    ),

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
    Acc;
extract_packets(<<Size:32/big-integer-unsigned, Rest/binary>>, Acc) ->
    <<EncodedPacket:Size/binary, Rest2/binary>> = Rest,
    Packet = hpr_packet_report:decode(EncodedPacket),
    extract_packets(Rest2, [Packet | Acc]).
