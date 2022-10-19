-module(hpr_packet_reporter).

-behaviour(gen_server).

-include("./include/hpr.hrl").

% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    init_ets/0,
    report_packet/2,
    write_packets/0,
    upload_packets/1,
    restart_report_interval/1,
    stop_report_interval/0
]).

%% Exported to allow testing
-export([handle_upload_retry/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(SERVER, ?MODULE).
-define(ETS, hpr_packet_report_ets).

-define(FILE_WRITE_OPTIONS, [write, raw, binary, compressed]).
-define(WRITE_BATCH_SIZE, 1000).

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

-type state() :: #state{}.
-type interval_duration_ms() :: non_neg_integer().
-type timestamp_ms() :: non_neg_integer().

-type packet_reporter_opts() :: #{
    access_key_id => binary(),
    secret_access_key => binary(),
    region => binary(),
    bucket => binary(),
    interval_duration => timestamp_ms(),
    write_dir => string(),
    max_file_size => integer(),
    upload_window => timestamp_ms(),
    retry_sleep_time => timestamp_ms(),
    max_upload_retries => non_neg_integer(),
    localstack_host => binary(),
    localstack_port => binary()
}.

%%%===================================================================
%%% API Function Definitions
%%%===================================================================

-spec start_link(packet_reporter_opts()) -> any().
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [named_table, bag, public, {write_concurrency, true}]),
    ok.

-spec report_packet(Packet :: hpr_packet_up:packet(), PacketRoute :: hpr_route:route()) -> ok.
report_packet(Packet, PacketRoute) ->
    EncodedPacket = encode_packet(Packet, PacketRoute),
    ReportTimestamp = erlang:system_time(millisecond),
    true = ets:insert(?ETS, {ReportTimestamp, EncodedPacket}),
    ok.

-spec write_packets() -> ok.
write_packets() ->
    gen_server:cast(?SERVER, write_packets).

-spec upload_packets(FilePath :: string()) -> ok.
upload_packets(FilePath) ->
    gen_server:cast(?SERVER, {upload_packets, FilePath}).

-spec restart_report_interval(IntervalDuration :: interval_duration_ms()) -> ok.
restart_report_interval(IntervalDuration) ->
    gen_server:cast(?SERVER, {start_interval, IntervalDuration}).

-spec stop_report_interval() -> ok.
stop_report_interval() ->
    gen_server:cast(?SERVER, stop_interval).

%%%===================================================================
%%% gen_server Function Definitions
%%%===================================================================

init(
    #{
        write_dir := WriteDir,
        max_file_size := MaxFileSize,
        interval_duration := IntervalDuration,
        upload_window := UploadWindow,
        bucket := Bucket,
        retry_sleep_time := RetrySleepTime,
        max_upload_retries := MaxUploadRetries
    } = Args
) ->
    AWSClient = setup_aws(Args),
    ok = filelib:ensure_dir(WriteDir),
    TempFilePath = generate_file_name(WriteDir),
    {ok, ReportInterval} = start_report_interval(IntervalDuration),
    {ok, #state{
        aws_client = AWSClient,
        write_dir = WriteDir,
        file_path = TempFilePath,
        max_file_size = MaxFileSize,
        report_interval = ReportInterval,
        interval_duration = IntervalDuration,
        upload_window = UploadWindow,
        upload_window_start_time = erlang:system_time(millisecond),
        upload_retries = #{},
        retry_sleep_time = RetrySleepTime,
        max_upload_retries = MaxUploadRetries,
        bucket = Bucket
    }}.

handle_call(Msg, _From, State = #state{}) ->
    {stop, {unimplemented_call, Msg}, State}.

handle_cast(
    write_packets,
    State = #state{
        write_dir = WriteDir,
        file_path = FilePath,
        max_file_size = MaxFileSize,
        upload_window_start_time = WindowStartTime,
        upload_window = UploadWindow
    }
) ->
    try
        {ok, FileSize} = handle_write(FilePath, MaxFileSize, ?FILE_WRITE_OPTIONS),

        case FileSize >= MaxFileSize orelse upload_window_elapsed(WindowStartTime, UploadWindow) of
            true ->
                ?MODULE:upload_packets(FilePath),
                {noreply, State#state{file_path = generate_file_name(WriteDir)}};
            false ->
                {noreply, State}
        end
    catch
        _:file_error:_ ->
            {noreply, State#state{file_path = generate_file_name(WriteDir)}}
    end;
handle_cast(
    {upload_packets, FilePath},
    State = #state{aws_client = AWSClient, bucket = Bucket}
) ->
    UploadTimestamp = erlang:system_time(millisecond),
    FileName = list_to_binary("packetreport." ++ integer_to_list(UploadTimestamp) ++ ".gz"),
    try
        {ok, UpdatedState} =
            case handle_upload(AWSClient, list_to_binary(FilePath), FileName, Bucket) of
                {ok, _} ->
                    file:delete(FilePath),
                    clear_retry_state(FilePath, State);
                Error ->
                    lager:warning("packet reporter failed to upload: ~p~n", [Error]),
                    ?MODULE:handle_upload_retry(FilePath, State)
            end,
        {noreply, UpdatedState#state{upload_window_start_time = UploadTimestamp}}
    catch
        _:file_error:_ ->
            {noreply, State}
    end;
handle_cast({start_interval, IntervalDuration}, State = #state{report_interval = ReportInterval}) ->
    {ok, ReportInterval2} = handle_restart_interval(ReportInterval, IntervalDuration),
    {noreply, State#state{report_interval = ReportInterval2, interval_duration = IntervalDuration}};
handle_cast(stop_interval, State = #state{report_interval = ReportInterval}) ->
    handle_stop_interval(ReportInterval),
    {noreply, State#state{report_interval = undefined, interval_duration = undefined}};
handle_cast(_Msg, State = #state{}) ->
    {noreply, State}.

handle_info(_Info, State = #state{}) ->
    {noreply, State}.

terminate(
    Reason,
    #state{
        file_path = FilePath,
        report_interval = ReportInterval,
        max_file_size = MaxFileSize
    }
) ->
    handle_write(FilePath, MaxFileSize, ?FILE_WRITE_OPTIONS),
    handle_stop_interval(ReportInterval),
    lager:warning("packet reporter process terminated: ~s", [Reason]),
    ok.

%%%===================================================================
%%% Internal Function Definitions
%%%===================================================================

-spec handle_write(FilePath :: string(), MaxFileSize :: integer(), WriteOptions :: [atom()]) ->
    {ok, FileSize :: integer()} | {error, Error :: term}.

handle_write(FilePath, MaxFileSize, WriteOptions) ->
    case file:open(FilePath, WriteOptions) of
        {ok, S} ->
            {ok, PacketsProcessed, PacketsDeleted} = write_packets(S),
            FileSize = filelib:file_size(FilePath),

            lager:info(
                [
                    {packets_processed, PacketsProcessed},
                    {packets_deleted, PacketsDeleted},
                    {file_size, FileSize},
                    {max_file_size, MaxFileSize}
                ],
                "packet reporter processing"
            ),

            {ok, FileSize};
        {error, Error} ->
            lager:error("failed to open tmp write file: ~p", [Error]),
            throw(file_error)
    end.

-spec write_packets(FileStream :: file:io_device()) ->
    {ok, PacketsProcessed :: integer(), NumDeleted :: integer()}.
write_packets(FileStream) ->
    WriteTimestamp = erlang:system_time(millisecond),
    write_packets(
        FileStream, WriteTimestamp, get_packets_by_timestamp(WriteTimestamp, ?WRITE_BATCH_SIZE), 0
    ).

-spec write_packets(
    FileStream :: file:io_device(),
    WriteTimestamp :: timestamp_ms(),
    {[term()], ets:continuation()} | '$end_of_table',
    non_neg_integer()
) ->
    {ok, PacketsProcessed :: integer(), NumDeleted :: integer()}.
write_packets(FileStream, WriteTimestamp, '$end_of_table', PacketsProcessed) ->
    NumDeleted = delete_packets_by_timestamp(WriteTimestamp),
    file:close(FileStream),
    {ok, PacketsProcessed, NumDeleted};
write_packets(FileStream, WriteTimestamp, {Data, Cont}, PacketsProcessed) ->
    lists:foreach(
        fun(Packet) ->
            PacketSize = encode_packet_size(Packet),
            file:write(FileStream, [PacketSize, Packet])
        end,
        Data
    ),
    write_packets(FileStream, WriteTimestamp, ets:select(Cont), PacketsProcessed + length(Data)).

-spec setup_aws(packet_reporter_opts()) -> aws_client:aws_client().
setup_aws(#{
    access_key_id := AccessKey,
    secret_access_key := Secret,
    region := Region,
    localstack_port := LocalstackPort,
    localstack_host := LocalstackHost
}) ->
    case Region of
        <<"local">> ->
            aws_client:make_local_client(
                AccessKey,
                Secret,
                LocalstackPort,
                LocalstackHost
            );
        _ ->
            aws_client:make_client(AccessKey, Secret, Region)
    end.

-spec start_report_interval(IntervalDuration :: interval_duration_ms()) -> {ok, timer:tref()}.

start_report_interval(IntervalDuration) ->
    timer:apply_interval(IntervalDuration, ?MODULE, write_packets, []).

-spec handle_restart_interval(
    IntervalRef :: timer:tref() | undefined, IntervalDuration :: interval_duration_ms()
) -> {ok, timer:tref()}.
handle_restart_interval(undefined, IntervalDuration) ->
    start_report_interval(IntervalDuration);
handle_restart_interval(IntervalRef, IntervalDuration) ->
    timer:cancel(IntervalRef),
    start_report_interval(IntervalDuration).

-spec handle_stop_interval(IntervalRef :: timer:tref()) ->
    {ok, no_interval} | {ok, cancel} | {error, term()}.
handle_stop_interval(undefined) -> {ok, no_interval};
handle_stop_interval(IntervalRef) -> timer:cancel(IntervalRef).

-spec encode_packet(Packet :: hpr_packet_up:packet(), PacketRoute :: hpr_route:route()) -> binary().
encode_packet(Packet, PacketRoute) ->
    hpr_packet_report:encode(
        hpr_packet_report:to_record(#{
            gateway_timestamp_ms => hpr_packet_up:timestamp(Packet),
            oui => hpr_route:oui(PacketRoute),
            net_id => hpr_route:net_id(PacketRoute),
            rssi => hpr_packet_up:rssi(Packet),
            frequency => hpr_packet_up:frequency(Packet),
            datarate => hpr_packet_up:datarate(Packet),
            snr => hpr_packet_up:snr(Packet),
            region => hpr_packet_up:region(Packet),
            gateway => hpr_packet_up:gateway(Packet),
            payload_hash => hpr_packet_up:phash(Packet)
        })
    ).

-spec encode_packet_size(EncodedPacket :: binary()) -> PacketSize :: binary().
encode_packet_size(EncodedPacket) ->
    PacketSize = size(EncodedPacket),
    <<PacketSize:32/big-integer-unsigned>>.

-spec generate_file_name(WriteDir :: string()) -> FilePath :: string().
generate_file_name(WriteDir) ->
    Timestamp = erlang:system_time(millisecond),
    FileName = "packetreport." ++ integer_to_list(Timestamp),
    filename:join(WriteDir, FileName).

-spec handle_upload(
    AWSClient :: aws_client:aws_client(),
    FilePath :: binary(),
    S3FileName :: binary(),
    BucketName :: binary()
) -> {ok, Response :: term()} | {error, upload_failed}.
handle_upload(AWSClient, FilePath, S3FileName, BucketName) ->
    {ok, Content} =
        case file:read_file(FilePath) of
            {error, Reason} ->
                lager:error("failed to read file for upload: ~p", [Reason]),
                throw(file_error);
            Contents ->
                Contents
        end,

    case
        aws_s3:put_object(
            AWSClient,
            BucketName,
            S3FileName,
            #{
                <<"Body">> => Content
            }
        )
    of
        {ok, _, Response} ->
            {ok, Response};
        Error ->
            lager:error(
                "failed to upload packet report: file: ~p, error: ~p", [FilePath, Error]
            ),
            {error, upload_failed}
    end.

-spec upload_window_elapsed(StartTime :: timestamp_ms(), UploadWindow :: timestamp_ms()) ->
    WindowElapsed :: boolean().
upload_window_elapsed(StartTime, UploadWindow) ->
    Timestamp = erlang:system_time(millisecond),
    Timestamp - StartTime >= UploadWindow.

-spec handle_upload_retry(FilePath :: string(), state()) -> {ok, state()}.
handle_upload_retry(FilePath, #state{retry_sleep_time = RetrySleepTime} = State) ->
    case should_retry_upload(FilePath, State) of
        true ->
            schedule_upload_retry(RetrySleepTime, FilePath),
            increment_upload_retries(FilePath, State);
        false ->
            clear_retry_state(FilePath, State)
    end.

-spec should_retry_upload(FilePath :: string(), state()) -> boolean().
should_retry_upload(FilePath, #state{
    upload_retries = RetriesMap, max_upload_retries = MaxUploadRetries
}) ->
    maps:get(FilePath, RetriesMap, 0) < MaxUploadRetries.

-spec clear_retry_state(FilePath :: string(), state()) -> {ok, state()}.
clear_retry_state(FilePath, #state{upload_retries = UploadRetries} = State) ->
    {ok, State#state{upload_retries = maps:remove(FilePath, UploadRetries)}}.

-spec increment_upload_retries(FilePath :: string(), state()) -> {ok, state()}.
increment_upload_retries(FilePath, #state{upload_retries = UploadRetries} = State) ->
    RetryValue = maps:get(FilePath, UploadRetries, 0) + 1,
    {ok, State#state{upload_retries = maps:put(FilePath, RetryValue, UploadRetries)}}.

-spec schedule_upload_retry(RetrySleepTime :: interval_duration_ms(), FilePath :: string()) ->
    {ok, timer:tref()} | {error, term()}.
schedule_upload_retry(RetrySleepTime, FilePath) ->
    timer:apply_after(RetrySleepTime, ?MODULE, upload_packets, [FilePath]).

-spec get_packets_by_timestamp(Timestamp :: timestamp_ms(), BatchSize :: non_neg_integer()) ->
    [term()].
get_packets_by_timestamp(Timestamp, BatchSize) ->
    ets:select(?ETS, [{{'$1', '$2'}, [{'<', '$1', Timestamp}], ['$2']}], BatchSize).

-spec delete_packets_by_timestamp(Timestamp :: timestamp_ms()) -> integer().
delete_packets_by_timestamp(Timestamp) ->
    ets:select_delete(?ETS, [{{'$1', '$2'}, [{'<', '$1', Timestamp}], [true]}]).

% ------------------------------------------------------------------
% EUnit Tests
% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

file_test() ->
    init_ets(),
    Timestamp = erlang:system_time(millisecond),
    FilePath = "./packetreport." ++ integer_to_list(Timestamp),
    MaxFileSize = 50_000_000,

    Packet = test_utils:join_packet_up(#{}),
    Packet2 = test_utils:uplink_packet_up(#{}),
    Route = test_utils:packet_route(#{}),

    report_packet(Packet, Route),
    report_packet(Packet2, Route),

    %% Ensure write doesn't occur on same timestamp as report
    timer:sleep(100),

    handle_write(FilePath, MaxFileSize, ?FILE_WRITE_OPTIONS),

    {ok, S} = file:open(FilePath, [raw, binary, compressed]),

    %% Read length-delimited protobufs
    {ok, EncodedPacketSize} = file:read(S, 4),
    {ok, EncodedPacket} = file:read(S, binary:decode_unsigned(EncodedPacketSize)),

    {ok, EncodedPacketSize2} = file:read(S, 4),
    {ok, EncodedPacket2} = file:read(S, binary:decode_unsigned(EncodedPacketSize2)),

    ?assertEqual(eof, file:read(S, 4)),

    file:close(S),

    ?assertEqual(encode_packet(Packet, Route), EncodedPacket),
    ?assertEqual(encode_packet(Packet2, Route), EncodedPacket2),

    file:delete(FilePath),

    ok.

upload_window_elapsed_test() ->
    Timestamp = erlang:system_time(millisecond),
    Config = application:get_env(?APP, packet_reporter, #{}),
    UploadWindow = maps:get(upload_window, Config, 900000),

    ?assertEqual(false, upload_window_elapsed(Timestamp, UploadWindow)),
    ?assertEqual(true, upload_window_elapsed(Timestamp - UploadWindow, UploadWindow)).

upload_retry_state_test() ->
    {ok, State} = ?MODULE:init(test_opts()),
    FilePath = State#state.file_path,

    ?assertEqual(#{}, State#state.upload_retries),
    ?assertEqual(true, should_retry_upload(FilePath, State)),

    {ok, State2} = increment_upload_retries(FilePath, State),

    ?assertEqual(#{FilePath => 1}, State2#state.upload_retries),
    ?assertEqual(true, should_retry_upload(FilePath, State2)),

    {ok, State3} = increment_upload_retries(FilePath, State2),

    ?assertEqual(#{FilePath => 2}, State3#state.upload_retries),
    ?assertEqual(false, should_retry_upload(FilePath, State3)),

    {ok, State4} = clear_retry_state(FilePath, State3),

    ?assertEqual(#{}, State4#state.upload_retries),

    ok.

test_opts() ->
    #{
        access_key_id => <<"testkey">>,
        secret_access_key => <<"testsecret">>,
        region => <<"local">>,
        bucket => <<"test-bucket">>,
        interval_duration => 300000,
        write_dir => "./data/tmp/",
        max_file_size => 50_000_000,
        upload_window => 900000,
        retry_sleep_time => 100,
        max_upload_retries => 2,
        localstack_host => <<"localhost">>,
        localstack_port => <<"4566">>
    }.

-endif.
