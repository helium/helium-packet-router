%%--------------------------------------------------------------------
%% @doc
%% To run this SUITE:
%% - `make test-aws`, which brings up rustfs and runs both reporter suites.
%% Or manually: `docker compose up -d --wait` then
%% `./rebar3 ct --suite=hpr_gateway_liveness_reporter_SUITE`.
%% The endpoint comes from config/ct.config; CI overrides it with
%% HPR_TEST_S3_ENDPOINT because rustfs resolves under another hostname there.
%% @end
%%--------------------------------------------------------------------
-module(hpr_gateway_liveness_reporter_SUITE).

-include_lib("eunit/include/eunit.hrl").

-include("hpr.hrl").
-include("hpr_metrics.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    checkpoint_test/1,
    upload_test/1
]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

all() ->
    [
        checkpoint_test,
        upload_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    ok = maybe_override_endpoint(gateway_liveness_reporter),
    Config1 = test_utils:init_per_testcase(TestCase, Config),
    ok = hpr_gateway_liveness_storage:delete_all(),
    Config1.

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
    State = sys:get_state(hpr_gateway_liveness_reporter),
    ok = empty_bucket(
        hpr_gateway_liveness_reporter:get_client(State),
        hpr_gateway_liveness_reporter:get_bucket(State)
    ),
    ok = hpr_gateway_liveness_storage:delete_all(),
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

checkpoint_test(_Config) ->
    ok = hpr_gateway_liveness_storage:record_connect(<<"gw1">>),
    ok = hpr_gateway_liveness_storage:record_connect(<<"gw2">>),

    ok = gen_server:cast(hpr_gateway_liveness_reporter, checkpoint),

    ok = test_utils:wait_until(
        fun() ->
            DataDir = application:get_env(?APP, data_dir, "data"),
            DETSFile = filename:join([DataDir, "hpr_gateway_liveness.dets"]),
            filelib:is_file(DETSFile)
        end
    ),

    %% ETS is untouched by a checkpoint (no pruning happens here)
    {ok, _} = hpr_gateway_liveness_storage:lookup(<<"gw1">>),
    {ok, _} = hpr_gateway_liveness_storage:lookup(<<"gw2">>),

    ok.

upload_test(_Config) ->
    Now = erlang:system_time(millisecond),
    N = 20,
    ExpectedGateways = [
        erlang:list_to_binary(io_lib:format("gw-~w", [X]))
     || X <- lists:seq(1, N)
    ],
    lists:foreach(
        fun(PubKeyBin) -> ok = hpr_gateway_liveness_storage:record_connect(PubKeyBin) end,
        ExpectedGateways
    ),

    %% A stale entry that should be pruned once the report runs
    StaleGateway = <<"gw-stale">>,
    true = ets:insert(hpr_gateway_liveness_ets, {StaleGateway, Now - timer:minutes(10)}),

    State = sys:get_state(hpr_gateway_liveness_reporter),
    AWSClient = hpr_gateway_liveness_reporter:get_client(State),
    Bucket = hpr_gateway_liveness_reporter:get_bucket(State),

    %% Check that bucket is still empty
    {ok, #{<<"ListBucketResult">> := ListBucketResult0}, _} = aws_s3:list_objects(
        AWSClient, Bucket
    ),
    ?assertNot(maps:is_key(<<"Contents">>, ListBucketResult0)),

    %% Force report
    ok = gen_server:cast(hpr_gateway_liveness_reporter, report),

    %% Wait until bucket report not empty
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
    ?assertEqual(<<"packet_router_liveness_report">>, Prefix),
    ?assert(erlang:binary_to_integer(Timestamp) < erlang:system_time(millisecond)),
    ?assert(
        erlang:binary_to_integer(Timestamp) > erlang:system_time(millisecond) - timer:seconds(2)
    ),
    ?assertEqual(<<"gz">>, Ext),

    %% Get file content and check that all gateways are there (including the stale one,
    %% since pruning happens *after* the report is built and uploaded)
    {ok, #{<<"Body">> := Compressed}, _} = aws_s3:get_object(AWSClient, Bucket, FileName),
    ExtractedReports = extract_reports(Compressed),
    ExtractedGateways = lists:sort([hpr_liveness_report:gateway(R) || R <- ExtractedReports]),
    ?assertEqual(lists:sort([StaleGateway | ExpectedGateways]), ExtractedGateways),

    %% Stale entry is pruned post-report, fresh ones remain
    ok = test_utils:wait_until(
        fun() ->
            {error, not_found} == hpr_gateway_liveness_storage:lookup(StaleGateway)
        end
    ),
    lists:foreach(
        fun(PubKeyBin) ->
            ?assertMatch({ok, _}, hpr_gateway_liveness_storage:lookup(PubKeyBin))
        end,
        ExpectedGateways
    ),

    timer:sleep(100),
    ?assertNotEqual(
        undefined,
        prometheus_histogram:value(?METRICS_LIVENESS_REPORT_HISTOGRAM, [ok])
    ),

    ok.

%% ------------------------------------------------------------------
%% Helpers
%% ------------------------------------------------------------------

-spec extract_reports(Compressed :: binary()) -> [hpr_liveness_report:liveness_report()].
extract_reports(Compressed) ->
    UnCompressed = zlib:gunzip(Compressed),
    extract_reports(UnCompressed, []).

-spec extract_reports(Rest :: binary(), Acc :: [hpr_liveness_report:liveness_report()]) ->
    [hpr_liveness_report:liveness_report()].
extract_reports(<<>>, Acc) ->
    Acc;
extract_reports(<<Size:32/big-integer-unsigned, Rest/binary>>, Acc) ->
    <<EncodedReport:Size/binary, Rest2/binary>> = Rest,
    Report = hpr_liveness_report:decode(EncodedReport),
    extract_reports(Rest2, [Report | Acc]).
