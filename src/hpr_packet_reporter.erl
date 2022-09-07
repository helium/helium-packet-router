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

-type interval_duration_ms() :: non_neg_integer().

-record(state, {
    aws_client :: aws_client:aws_client(),
    file_path :: string(),
    report_interval :: timer:tref() | undefined
}).

%%%===================================================================
%%% API Functions
%%%===================================================================

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [named_table, bag, public, {write_concurrency, true}]),
    ok.

-spec report_packet(hpr_packet_up:packet(), hpr_route:route()) -> ok.
report_packet(Packet, Route) ->
    EncodedPacket = encode_packet(Packet, Route),
    Timestamp = erlang:system_time(millisecond),
    true = ets:insert(?ETS, {Timestamp, EncodedPacket}),
    ok.

-spec write_packets() -> ok.
write_packets() ->
    gen_server:cast(?SERVER, write).

-spec upload_packets(string()) -> ok.
upload_packets(FilePath) ->
    gen_server:cast(?SERVER, {upload, FilePath}).

-spec restart_report_interval(interval_duration_ms()) -> ok.
restart_report_interval(IntervalDuration) ->
    gen_server:cast(?SERVER, {start_interval, IntervalDuration}).

stop_report_interval() ->
    gen_server:cast(?SERVER, stop_interval).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

init(#{base_dir := BaseDir} = _Args) ->
    AWSClient = setup_aws(),
    WriteDir = filename:join(BaseDir, "tmp/"),
    ok = filelib:ensure_dir(WriteDir),
    %% TODO: File rotation
    TempFilePath = filename:join(WriteDir, "packetreport.gz"),
    {ok, ReportInterval} = start_report_interval(),
    {ok, #state{
        aws_client = AWSClient,
        file_path = TempFilePath,
        report_interval = ReportInterval
    }}.

handle_call(Request, From, State = #state{}) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [Request, From]),
    {reply, ok, State}.

handle_cast(write, State = #state{file_path = FilePath}) ->
    {ok, FileSize, MaxFileSize} = handle_write(FilePath),

    case FileSize >= MaxFileSize of
        true -> ?MODULE:upload_packets(FilePath);
        false -> skip
    end,
    {noreply, State};
handle_cast({upload, FilePath}, State = #state{aws_client = AWSClient}) ->
    Timestamp = erlang:system_time(millisecond),
    FileName = list_to_binary("packetreport." ++ integer_to_list(Timestamp) ++ ".gz"),
    upload_file(AWSClient, FilePath, FileName),
    file:delete(FilePath),
    {noreply, State};
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
    handle_write(FilePath),
    handle_stop_interval(ReportInterval),
    lager:warning("packet reporter process terminated: ~s", [Reason]),
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec handle_write(string()) -> {ok, integer(), integer()}.
-spec handle_write(string(), [atom()]) -> {ok, integer(), integer()}.

handle_write(FilePath) -> handle_write(FilePath, [compressed]).
handle_write(FilePath, Options) ->
    Timestamp = erlang:system_time(millisecond),
    {ok, S} = open_tmp_file(FilePath, Options),
    Data = get_packets_by_timestamp(Timestamp),

    lists:foreach(
        fun(Packet) ->
            io:fwrite(S, "~w~n", [Packet])
        end,
        Data
    ),
    file:close(S),

    NumDeleted = delete_packets_by_timestamp(Timestamp),
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
    {ok, FileSize, MaxFileSize}.

-spec setup_aws() -> aws_client:aws_client().
setup_aws() ->
    #{
        access_key_id := AccessKey,
        secret_access_key := Secret,
        aws_region := Region
    } = maps:from_list(application:get_env(hpr, aws_config, [])),
    aws_client:make_client(AccessKey, Secret, Region).

-spec start_report_interval() -> {ok, timer:tref()}.
-spec start_report_interval(interval_duration_ms()) -> {ok, timer:tref()}.

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

-spec encode_packet(hpr_packet_up:packet(), hpr_route:route()) ->
    #packet_router_packet_report_v1_pb{}.
encode_packet(
    #packet_router_packet_up_v1_pb{
        payload = Payload,
        timestamp = Timestamp,
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
    #packet_router_packet_report_v1_pb{
        gateway_timestamp_ms = Timestamp,
        oui = OUI,
        net_id = NetID,
        rssi = RSSI,
        frequency_mhz = FrequencyMhz,
        datarate = Datarate,
        snr = SNR,
        region = Region,
        gateway = Gateway,
        payload_hash = crypto:hash(sha256, Payload)
    }.

-spec open_tmp_file(string(), [atom()]) -> {ok, file:io_device()} | {error, atom()}.
open_tmp_file(FilePath, Options) ->
    case file:open(FilePath, [append] ++ Options) of
        {error, Error} ->
            lager:error("failed to open tmp write file: ~p", [Error]);
        IODevice ->
            IODevice
    end.

-spec upload_file(aws_client:aws_client(), string(), binary()) -> ok.
upload_file(AWSClient, Path, FileName) ->
    BucketName = application:get_env(hpr, packet_reporter_bucket, <<"default_bucket">>),
    {ok, Content} = file:read_file(Path),
    case
        aws_s3:put_object(AWSClient, BucketName, FileName, #{
            <<"Body">> => Content
        })
    of
        {ok, _, _} ->
            ok;
        Error ->
            lager:error(
                "failed to upload packet report: file: ~p, error: ~p", [Path, Error]
            )
    end.

-spec get_packets_by_timestamp(integer()) -> [term()].
get_packets_by_timestamp(Timestamp) ->
    ets:select(?ETS, [{{'$1', '$2'}, [{'<', '$1', Timestamp}], ['$2']}]).

-spec delete_packets_by_timestamp(integer()) -> integer().
delete_packets_by_timestamp(Timestamp) ->
    ets:select_delete(?ETS, [{{'$1', '$2'}, [{'<', '$1', Timestamp}], [true]}]).

% ------------------------------------------------------------------
% EUNIT Tests
% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

file_test() ->
    ?ETS = ets:new(?ETS, [named_table, bag, public, {write_concurrency, true}]),
    Timestamp = erlang:system_time(millisecond),
    FilePath = "./data/tmp/packetreport." ++ integer_to_list(Timestamp) ++ ".txt",

    Packet = test_utils:join_packet_up(#{}),
    Packet2 = test_utils:uplink_packet_up(#{}),
    Route = test_utils:packet_route(#{}),

    report_packet(Packet, Route),
    report_packet(Packet2, Route),

    timer:sleep(1000),

    handle_write(FilePath, []),

    {ok, Content} = file:read_file(FilePath),

    2 = length(binary:split(Content, <<"\n">>, [trim, global])),

    Packet3 = test_utils:join_packet_up(#{}),
    Packet4 = test_utils:uplink_packet_up(#{}),

    report_packet(Packet3, Route),
    report_packet(Packet4, Route),

    timer:sleep(1000),

    handle_write(FilePath, []),

    {ok, Content2} = file:read_file(FilePath),

    4 = length(binary:split(Content2, <<"\n">>, [trim, global])),

    file:delete(FilePath),

    ok.

% aws_test() ->
%     AccessKey = <<"">>,
%     SecretKey = <<"">>,
%     Region = <<"">>,
%     Client = aws_client:make_client(AccessKey, SecretKey, Region),
%     {ok, S} = file:open("/tmp/test.txt", [write, compressed]),
%     file:write(S, <<"HelloWorld">>),
%     file:close(S),

%     {ok, Content} = file:read_file("/tmp/test.txt"),
%     io:format("~p~n", [Content]),
%     aws_s3:put_object(Client, <<"test-bucket-hw">>, <<"my-key3">>, #{
%         <<"Body">> => Content
%     }),
%     {ok, Response, _} = aws_s3:get_object(Client, <<"test-bucket-hw">>, <<"my-key3">>),
%     io:format("Test2: ~p~n", [Response]),
%     Content = maps:get(<<"Body">>, Response).

-endif.
