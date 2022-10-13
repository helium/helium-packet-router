-module(hpr_packet_reporter_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    upload_report_test/1,
    upload_error_test/1,
    report_interval_test/1,
    upload_window_test/1
]).

-include("hpr.hrl").

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-record(state, {
    aws_client :: aws_client:aws_client(),
    write_dir :: string(),
    file_path :: string(),
    max_file_size :: non_neg_integer(),
    report_interval :: timer:tref() | undefined,
    interval_duration :: non_neg_integer() | undefined,
    upload_window :: non_neg_integer(),
    upload_window_start_time :: non_neg_integer(),
    upload_retries :: map(),
    retry_sleep_time :: non_neg_integer(),
    max_upload_retries :: non_neg_integer(),
    bucket :: binary()
}).

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
        upload_report_test,
        upload_error_test,
        report_interval_test,
        upload_window_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    Config1 = test_utils:init_per_testcase(TestCase, Config),
    meck:new(aws_s3, [passthrough]),
    meck:new(aws_request, [passthrough]),
    meck:new(hpr_packet_reporter, [passthrough]),

    Config1.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    ets:delete_all_objects(hpr_packet_report_ets),
    meck:unload(),

    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

upload_report_test(_Config) ->
    State = sys:get_state(hpr_packet_reporter),
    #state{file_path = FilePath, aws_client = AWSClient, bucket = Bucket} = State,

    Packet = test_utils:join_packet_up(#{}),
    Packet2 = test_utils:uplink_packet_up(#{}),
    Route = test_utils:packet_route(#{}),

    %% Reported packets are encoded and saved to ETS
    hpr_packet_reporter:report_packet(Packet, Route),
    hpr_packet_reporter:report_packet(Packet2, Route),

    ETSValues = ets:tab2list(hpr_packet_report_ets),
    ?assertEqual(2, length(ETSValues)),
    [P1, P2] = lists:map(
        fun({_, P}) ->
            P
        end,
        ETSValues
    ),
    verify_packet(Packet, Route, P1),
    verify_packet(Packet2, Route, P2),

    %% Ensure write doesn't occur on same timestamp as report
    timer:sleep(100),

    %% Encoded packets are written to a tmp write file
    hpr_packet_reporter:handle_cast(write_packets, State),

    %% Contents of tmp file are uploaded to S3 (localstack)
    hpr_packet_reporter:handle_cast({upload_packets, FilePath}, State),

    UploadedFile = meck:capture(first, aws_s3, put_object, '_', 3),
    {ok, #{<<"Body">> := ResponseBody}, _} = aws_s3:get_object(AWSClient, Bucket, UploadedFile),

    [EncodedPacket, EncodedPacket2] = parse_packet_report(ResponseBody),
    verify_packet(Packet, Route, EncodedPacket),
    verify_packet(Packet2, Route, EncodedPacket2),

    %% Packets are cleared from ETS
    ?assertEqual(0, length(ets:tab2list(hpr_packet_report_ets))),

    file:delete(FilePath),

    ok.

upload_error_test(_Config) ->
    State = sys:get_state(hpr_packet_reporter),
    #state{file_path = FilePath, max_upload_retries = MaxUploadRetries} = State,

    Packet = test_utils:join_packet_up(#{}),
    Packet2 = test_utils:uplink_packet_up(#{}),
    Route = test_utils:packet_route(#{}),

    %% Reported packets are encoded and saved to ETS
    hpr_packet_reporter:report_packet(Packet, Route),
    hpr_packet_reporter:report_packet(Packet2, Route),

    %% Ensure write doesn't occur on same timestamp as report
    timer:sleep(100),

    %% Encoded packets are written to a tmp write file
    hpr_packet_reporter:handle_cast(write_packets, State),

    %% Mock failed connection to AWS
    meck:expect(aws_request, request, fun(_, Opts) ->
        meck:passthrough([fun() -> {error, connect_timeout} end, Opts])
    end),

    % hpr_packet_reporter:handle_cast({upload_packets, FilePath}, State),
    hpr_packet_reporter:upload_packets(FilePath),

    % Allow time for asychronous uploads, call to upload_packets + retries
    timer:sleep(1000),

    ExpectedAttempts = MaxUploadRetries + 1,
    ?assertEqual(ExpectedAttempts, meck:num_calls(hpr_packet_reporter, handle_upload_retry, '_')),
    ?assertEqual(
        ExpectedAttempts,
        meck:num_calls(hpr_packet_reporter, handle_cast, [{upload_packets, FilePath}, '_'])
    ),

    file:delete(FilePath),

    ok.

report_interval_test(_Config) ->
    PacketReporterConfig = application:get_env(hpr, packet_reporter, #{}),
    #{interval_duration := DefaultDuration} = PacketReporterConfig,
    State = sys:get_state(hpr_packet_reporter),
    #state{report_interval = IntervalRef, interval_duration = IntervalDuration} = State,

    ?assertEqual(DefaultDuration, IntervalDuration),
    verify_timer(IntervalRef, IntervalDuration),

    hpr_packet_reporter:stop_report_interval(),
    State2 = sys:get_state(hpr_packet_reporter),
    #state{report_interval = IntervalRef2, interval_duration = IntervalDuration2} = State2,

    ?assertEqual(undefined, IntervalRef2),
    ?assertEqual(undefined, IntervalDuration2),

    NewDuration = 500000,
    hpr_packet_reporter:restart_report_interval(NewDuration),
    State3 = sys:get_state(hpr_packet_reporter),
    #state{report_interval = IntervalRef3, interval_duration = IntervalDuration3} = State3,

    ?assertEqual(NewDuration, IntervalDuration3),
    verify_timer(IntervalRef3, IntervalDuration3),

    ok.

upload_window_test(_Config) ->
    Env = application:get_env(?APP, packet_reporter, #{}),
    UploadWindow = maps:get(upload_window, Env, 900000),
    State = sys:get_state(hpr_packet_reporter),
    #state{file_path = FilePath, upload_window_start_time = WindowStartTime} = State,

    Packet = test_utils:join_packet_up(#{}),
    Route = test_utils:packet_route(#{}),

    %% Reported packets are encoded and saved to ETS
    hpr_packet_reporter:report_packet(Packet, Route),

    %% Encoded packets are written to a tmp write file
    hpr_packet_reporter:handle_cast(write_packets, State),

    ?assertEqual(false, meck:called(hpr_packet_reporter, upload_packets, '_')),

    %% Write packets after upload window has elapsed
    hpr_packet_reporter:handle_cast(write_packets, State#state{
        upload_window_start_time = (WindowStartTime - UploadWindow - 1000)
    }),

    ?assertEqual(true, meck:called(hpr_packet_reporter, upload_packets, '_')),

    file:delete(FilePath),

    ok.

%% ------------------------------------------------------------------
%% Helpers
%% ------------------------------------------------------------------

verify_packet(Packet, PacketRoute, EncodedPacket) ->
    PacketReport = hpr_packet_report:decode(EncodedPacket),
    ?assertEqual(
        hpr_packet_up:timestamp(Packet), hpr_packet_report:gateway_timestamp_ms(PacketReport)
    ),
    ?assertEqual(hpr_route:oui(PacketRoute), hpr_packet_report:oui(PacketReport)),
    ?assertEqual(hpr_route:net_id(PacketRoute), hpr_packet_report:net_id(PacketReport)),
    ?assertEqual(hpr_packet_up:rssi(Packet), hpr_packet_report:rssi(PacketReport)),
    ?assertEqual(hpr_packet_up:frequency(Packet), hpr_packet_report:frequency(PacketReport)),
    ?assertEqual(hpr_packet_up:snr(Packet), hpr_packet_report:snr(PacketReport)),
    ?assertEqual(hpr_packet_up:datarate(Packet), hpr_packet_report:datarate(PacketReport)),
    ?assertEqual(hpr_packet_up:region(Packet), hpr_packet_report:region(PacketReport)),
    ?assertEqual(hpr_packet_up:gateway(Packet), hpr_packet_report:gateway(PacketReport)),
    ?assertEqual(hpr_packet_up:phash(Packet), hpr_packet_report:payload_hash(PacketReport)).

%% Parse length-delimited protobufs
parse_packet_report(Report) ->
    UncompressedReport = zlib:gunzip(Report),
    parse_packet_report(UncompressedReport, []).

parse_packet_report(<<>>, Acc) ->
    lists:reverse(Acc);
parse_packet_report(<<Size:4/binary, Rest/binary>>, Acc) ->
    DecodedSize = binary:decode_unsigned(Size),
    <<Packet:DecodedSize/binary, Rest2/binary>> = Rest,
    parse_packet_report(Rest2, [Packet | Acc]).

verify_timer({interval, ExpectedReportInterval}, ExpectedDuration) ->
    case get_write_interval() of
        {{_, TimerRef}, {_, Duration, _}, {_, _, _}} ->
            ?assertEqual(ExpectedReportInterval, TimerRef),
            ?assertEqual(ExpectedDuration, Duration div 1000);
        _ ->
            ?assertEqual(undefined, ExpectedReportInterval)
    end.

get_write_interval() ->
    case
        lists:filter(
            fun
                ({_, _, {hpr_packet_reporter, write_packets, []}}) -> true;
                (_) -> false
            end,
            ets:tab2list(timer_tab)
        )
    of
        [] -> undefined;
        [Interval] -> Interval
    end.
