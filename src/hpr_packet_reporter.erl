-module(hpr_packet_reporter).

-behaviour(gen_server).

-include("./grpc/autogen/server/packet_router_pb.hrl").

-export([
    start_link/1,
    init_ets/0,
    report_packet/2,
    write_packets/0,
    upload_packets/1,
    restart_report_interval/1,
    stop_report_interval/0
]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(ETS, hpr_packet_report_ets).

%% 5 minute interval
-define(DEFAULT_REPORT_INTERVAL, 300000).
-define(MAX_FILE_SIZE, 50_000_000).
%% 15 minute maximum upload window
-define(DEFAULT_UPLOAD_WINDOW, 900000).
%% Up to 5 retries, 1 minute sleep
-define(RETRY_SLEEP_TIME, 60000).
-define(AWS_RETRY_OPTIONS, [
    {retry_options, {exponential_with_jitter, {5, ?RETRY_SLEEP_TIME, ?RETRY_SLEEP_TIME}}}
]).

-record(state, {
    aws_client :: aws_client:aws_client(),
    write_dir :: string(),
    file_path :: string(),
    report_interval :: timer:tref() | undefined,
    upload_window_start_time :: non_neg_integer()
}).

-type interval_duration_ms() :: non_neg_integer().
-type timestamp_ms() :: non_neg_integer().

%%%===================================================================
%%% API Functions
%%%===================================================================

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
    gen_server:cast(?SERVER, write).

-spec upload_packets(FilePath :: string()) -> ok.
upload_packets(FilePath) ->
    gen_server:cast(?SERVER, {upload, FilePath}).

-spec restart_report_interval(IntervalDuration :: interval_duration_ms()) -> ok.
restart_report_interval(IntervalDuration) ->
    gen_server:cast(?SERVER, {start_interval, IntervalDuration}).

-spec stop_report_interval() -> ok.
stop_report_interval() ->
    gen_server:cast(?SERVER, stop_interval).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

init(#{base_dir := BaseDir} = _Args) ->
    AWSClient = setup_aws(),
    WriteDir = filename:join(BaseDir, "tmp"),
    ok = filelib:ensure_dir(WriteDir),
    TempFilePath = generate_file_name(WriteDir),
    {ok, ReportInterval} = start_report_interval(),
    {ok, #state{
        aws_client = AWSClient,
        write_dir = WriteDir,
        file_path = TempFilePath,
        report_interval = ReportInterval,
        upload_window_start_time = erlang:system_time(millisecond)
    }}.

handle_call(Request, From, State = #state{}) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [Request, From]),
    {reply, ok, State}.

handle_cast(
    write,
    State = #state{
        write_dir = WriteDir, file_path = FilePath, upload_window_start_time = WindowStartTime
    }
) ->
    {ok, FileSize, MaxFileSize} = handle_write(FilePath, [write, raw, binary, compressed]),

    case FileSize >= MaxFileSize orelse upload_window_elapsed(WindowStartTime) of
        true ->
            ?MODULE:upload_packets(FilePath),
            {noreply, State#state{file_path = generate_file_name(WriteDir)}};
        false ->
            {noreply, State}
    end;
handle_cast({upload, FilePath}, State = #state{aws_client = AWSClient}) ->
    UploadTimestamp = erlang:system_time(millisecond),
    FileName = list_to_binary("packetreport." ++ integer_to_list(UploadTimestamp) ++ ".gz"),

    case upload_file(AWSClient, list_to_binary(FilePath), FileName) of
        {ok, _} ->
            file:delete(FilePath);
        Error ->
            lager:warning("packet reporter failed to upload: ~p~n", [Error]),
            error
    end,
    {noreply, State#state{upload_window_start_time = UploadTimestamp}};
handle_cast({start_interval, IntervalDuration}, State = #state{report_interval = ReportInterval}) ->
    {ok, ReportInterval2} = handle_restart_interval(ReportInterval, IntervalDuration),
    {noreply, State#state{report_interval = ReportInterval2}};
handle_cast(stop_interval, State = #state{report_interval = ReportInterval}) ->
    handle_stop_interval(ReportInterval),
    {noreply, State#state{report_interval = undefined}};
handle_cast(Request, State = #state{}) ->
    lager:warning("rcvd unknown cast msg: ~p", [Request]),
    {noreply, State}.

handle_info(_Info, State = #state{}) ->
    {noreply, State}.

terminate(Reason, _State = #state{file_path = FilePath, report_interval = ReportInterval}) ->
    handle_write(FilePath, [write, raw, binary, compressed]),
    handle_stop_interval(ReportInterval),
    lager:warning("packet reporter process terminated: ~s", [Reason]),
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec handle_write(FilePath :: string(), WriteOptions :: [atom()]) ->
    {ok, FileSize :: integer(), MaxFileSize :: integer()}.

handle_write(FilePath, WriteOptions) ->
    WriteTimestamp = erlang:system_time(millisecond),
    {ok, S} = open_tmp_file(FilePath, WriteOptions),
    Data = get_packets_by_timestamp(WriteTimestamp),

    lists:foreach(
        fun(Packet) ->
            PacketSize = encode_packet_size(Packet),
            file:write(S, PacketSize),
            file:write(S, Packet)
        end,
        Data
    ),
    file:close(S),

    NumDeleted = delete_packets_by_timestamp(WriteTimestamp),
    FileSize = filelib:file_size(FilePath),
    MaxFileSize = application:get_env(hpr, packet_reporter_max_file_size, ?MAX_FILE_SIZE),

    lager:info(
        [
            {packets_processed, length(Data)},
            {packets_deleted, NumDeleted},
            {file_size, FileSize},
            {max_file_size, MaxFileSize}
        ],
        "packet reporter processing"
    ),
    lager:info(
        [
            {state, sys:get_state(hpr_packet_reporter)}
        ],
        "packet reporter state"
    ),
    {ok, FileSize, MaxFileSize}.

-spec setup_aws() -> aws_client:aws_client().
setup_aws() ->
    #{
        access_key_id := AccessKey,
        secret_access_key := Secret,
        aws_region := Region
    } = maps:from_list(application:get_env(hpr, aws_config, [])),
    case Region of
        <<"local">> ->
            aws_client:make_local_client(
                AccessKey,
                Secret,
                application:get_env(hpr, localstack_port, <<"4566">>),
                application:get_env(hpr, localstack_host, <<"localhost">>)
            );
        _ ->
            aws_client:make_client(AccessKey, Secret, Region)
    end.

-spec start_report_interval() -> {ok, timer:tref()}.
-spec start_report_interval(IntervalDuration :: interval_duration_ms()) -> {ok, timer:tref()}.

start_report_interval() ->
    IntervalDuration = application:get_env(
        hpr, packet_reporter_report_interval, ?DEFAULT_REPORT_INTERVAL
    ),
    start_report_interval(IntervalDuration).
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

-spec handle_stop_interval(IntervalRef :: timer:tref()) -> {ok, cancel} | {error, term()}.
handle_stop_interval(undefined) -> {ok, no_interval};
handle_stop_interval(IntervalRef) -> timer:cancel(IntervalRef).

-spec encode_packet(Packet :: hpr_packet_up:packet(), PacketRoute :: hpr_route:route()) -> binary().
encode_packet(
    #packet_router_packet_up_v1_pb{
        payload = Payload,
        timestamp = GatewayTimestamp,
        rssi = RSSI,
        frequency_mhz = FrequencyMhz,
        datarate = Datarate,
        snr = SNR,
        region = Region,
        gateway = Gateway
    },
    #packet_router_route_v1_pb{
        oui = OUI,
        net_id = NetID
    }
) ->
    packet_router_pb:encode_msg(
        #packet_router_packet_report_v1_pb{
            gateway_timestamp_ms = GatewayTimestamp,
            oui = OUI,
            net_id = NetID,
            rssi = RSSI,
            frequency_mhz = FrequencyMhz,
            datarate = Datarate,
            snr = SNR,
            region = Region,
            gateway = Gateway,
            payload_hash = crypto:hash(sha256, Payload)
        },
        packet_router_packet_report_v1_pb
    ).

-spec encode_packet_size(EncodedPacket :: binary()) -> PacketSize :: binary().
encode_packet_size(EncodedPacket) ->
    PacketSize = size(EncodedPacket),
    EncodedValue = binary:encode_unsigned(PacketSize),
    pad_u32(EncodedValue).

-spec pad_u32(binary()) -> binary().
pad_u32(Bin) ->
    <<0:((4 - size(Bin)) * 8), Bin/binary>>.

-spec generate_file_name(WriteDir :: string()) -> FilePath :: string().
generate_file_name(WriteDir) ->
    Timestamp = erlang:system_time(millisecond),
    FileName = "packetreport." ++ integer_to_list(Timestamp),
    filename:join(WriteDir, FileName).

-spec open_tmp_file(FilePath :: string(), WriteOptions :: [atom()]) ->
    {ok, IODevice :: file:io_device()} | {error, Reason :: atom()}.
open_tmp_file(FilePath, WriteOptions) ->
    case file:open(FilePath, WriteOptions) of
        {error, Error} ->
            lager:error("failed to open tmp write file: ~p", [Error]);
        IODevice ->
            IODevice
    end.

-spec upload_file(
    AWSClient :: aws_client:aws_client(), FilePath :: binary(), S3FileName :: binary()
) -> {ok, Response :: term()} | {error, upload_failed}.
upload_file(AWSClient, FilePath, S3FileName) ->
    BucketName = application:get_env(hpr, packet_reporter_bucket, <<"test-bucket">>),
    {ok, Content} = file:read_file(FilePath),
    case
        aws_s3:put_object(
            AWSClient,
            BucketName,
            S3FileName,
            #{
                <<"Body">> => Content
            },
            ?AWS_RETRY_OPTIONS
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

-spec upload_window_elapsed(StartTime :: timestamp_ms()) -> boolean().
upload_window_elapsed(StartTime) ->
    Timestamp = erlang:system_time(millisecond),
    UploadWindow = application:get_env(hpr, packet_reporter_upload_window, ?DEFAULT_UPLOAD_WINDOW),
    Timestamp - StartTime >= UploadWindow.

-spec get_packets_by_timestamp(Timestamp :: timestamp_ms()) -> [term()].
get_packets_by_timestamp(Timestamp) ->
    ets:select(?ETS, [{{'$1', '$2'}, [{'=<', '$1', Timestamp}], ['$2']}]).

-spec delete_packets_by_timestamp(Timestamp :: timestamp_ms()) -> integer().
delete_packets_by_timestamp(Timestamp) ->
    ets:select_delete(?ETS, [{{'$1', '$2'}, [{'=<', '$1', Timestamp}], [true]}]).

% ------------------------------------------------------------------
% EUNIT Tests
% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

file_test() ->
    ?ETS = ets:new(?ETS, [named_table, bag, public, {write_concurrency, true}]),
    Timestamp = erlang:system_time(millisecond),
    FilePath = "./packetreport." ++ integer_to_list(Timestamp),

    Packet = test_utils:join_packet_up(#{}),
    Packet2 = test_utils:uplink_packet_up(#{}),
    Route = test_utils:packet_route(#{}),

    report_packet(Packet, Route),
    report_packet(Packet2, Route),

    handle_write(FilePath, [write, raw, binary, compressed]),

    {ok, S} = file:open(FilePath, [read, raw, binary, compressed]),

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

pad_u32_test() ->
    ?assertEqual(<<0, 0, 0, 0>>, pad_u32(binary:encode_unsigned(0))),
    ?assertEqual(<<0, 0, 0, 1>>, pad_u32(binary:encode_unsigned(1))),
    ?assertEqual(<<0, 0, 3, 232>>, pad_u32(binary:encode_unsigned(1000))),
    ?assertEqual(<<5, 245, 225, 0>>, pad_u32(binary:encode_unsigned(100000000))).

upload_window_elapsed_test() ->
    Timestamp = erlang:system_time(millisecond),
    UploadWindow = application:get_env(hpr, packet_reporter_upload_window, ?DEFAULT_UPLOAD_WINDOW),

    ?assertEqual(false, upload_window_elapsed(Timestamp)),
    ?assertEqual(true, upload_window_elapsed(Timestamp - UploadWindow)).

-endif.
