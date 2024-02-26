-module(hpr_packet_reporter).

-behaviour(gen_server).

-include("hpr.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    report_packet/4
]).

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

-ifdef(TEST).

-export([
    get_bucket/1,
    get_client/1
]).

-endif.

-define(SERVER, ?MODULE).
-define(UPLOAD, upload).
-define(MAX_WBITS, 15).

-record(state, {
    bucket :: binary(),
    bucket_region :: binary(),
    report_max_size :: non_neg_integer(),
    report_interval :: non_neg_integer(),
    compressor,
    current_packets = [] :: [iodata()],
    current_size = 0 :: non_neg_integer()
}).

-type state() :: #state{}.

-type packet_reporter_opts() :: #{
    aws_bucket => binary(),
    aws_bucket_region => binary(),
    report_interval => non_neg_integer(),
    report_max_size => non_neg_integer()
}.

%% ------------------------------------------------------------------
%%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(packet_reporter_opts()) -> any().
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec report_packet(
    Packet :: hpr_packet_up:packet(),
    PacketRoute :: hpr_route:route(),
    IsFree :: boolean(),
    ReceivedTime :: non_neg_integer()
) -> ok.
report_packet(Packet, PacketRoute, IsFree, ReceivedTime) ->
    EncodedPacket = encode_packet(Packet, PacketRoute, IsFree, ReceivedTime),
    gen_server:cast(?SERVER, {report_packet, EncodedPacket}).

%% ------------------------------------------------------------------
%%% Test Function Definitions
%% ------------------------------------------------------------------

-ifdef(TEST).

-spec get_bucket(state()) -> binary().
get_bucket(#state{bucket = Bucket}) ->
    Bucket.

-spec get_client(state()) -> aws_client:aws_client().
get_client(State) ->
    setup_aws(State).

-endif.

%% ------------------------------------------------------------------
%%% gen_server Function Definitions
%% ------------------------------------------------------------------
-spec init(packet_reporter_opts()) -> {ok, state()}.
init(
    #{
        aws_bucket := Bucket,
        aws_bucket_region := BucketRegion,
        report_max_size := MaxSize,
        report_interval := Interval
    } = Args
) ->
    lager:info(maps:to_list(Args), "started"),
    ok = schedule_upload(Interval),
    Compressor = zlib:open(),
    ok = zlib:deflateInit(Compressor, default, deflated, 16 + ?MAX_WBITS, 8, default),
    {ok, #state{
        bucket = Bucket,
        compressor = Compressor,
        bucket_region = BucketRegion,
        report_max_size = MaxSize,
        report_interval = Interval
    }}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(
    {report_packet, EncodedPacket},
    #state{
        report_max_size = MaxSize,
        current_packets = Packets,
        current_size = Size,
        compressor = Compressor
    } = State
) when Size < MaxSize ->
    CompressedPacket = zlib:deflate(Compressor, EncodedPacket),
    {noreply, State#state{
        current_packets = [CompressedPacket | Packets],
        current_size = iolist_size(CompressedPacket) + Size
    }};
handle_cast(
    {report_packet, EncodedPacket},
    #state{
        report_max_size = MaxSize,
        current_packets = Packets,
        current_size = Size,
        compressor = Compressor
    } = State
) when Size >= MaxSize ->
    lager:info("got packet, size too big"),
    CompressedPacket = zlib:deflate(Compressor, EncodedPacket),
    {noreply,
        upload(State#state{
            current_packets = [CompressedPacket | Packets],
            current_size = iolist_size(CompressedPacket) + Size
        })};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(?UPLOAD, #state{report_interval = Interval} = State) ->
    lager:info("upload time"),
    ok = schedule_upload(Interval),
    {noreply, upload(State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{current_packets = Packets}) ->
    lager:error("terminate ~p, dropped ~w packets", [_Reason, erlang:length(Packets)]),
    ok.

%% ------------------------------------------------------------------
%%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec encode_packet(
    Packet :: hpr_packet_up:packet(),
    Route :: hpr_route:route(),
    IsFree0 :: boolean(),
    ReceivedTime :: non_neg_integer()
) -> binary().
encode_packet(Packet, Route, IsFree0, ReceivedTime) ->
    NetID = hpr_route:net_id(Route),
    NetIDStr = hpr_utils:int_to_hex_string(NetID),
    FreeNetIDs = application:get_env(?APP, ?HPR_FREE_NET_IDS, []),
    IsFree1 = IsFree0 orelse lists:member(NetIDStr, FreeNetIDs),
    EncodedPacket = hpr_packet_report:encode(
        hpr_packet_report:new(Packet, Route, IsFree1, ReceivedTime)
    ),
    PacketSize = erlang:size(EncodedPacket),
    <<PacketSize:32/big-integer-unsigned, EncodedPacket/binary>>.

-spec setup_aws(state()) -> aws_client:aws_client().
setup_aws(#state{
    bucket_region = <<"local">>
}) ->
    #{
        access_key_id := AccessKey,
        secret_access_key := Secret
    } = aws_credentials:get_credentials(),
    {LocalHost, LocalPort} = get_local_host_port(),
    aws_client:make_local_client(AccessKey, Secret, LocalPort, LocalHost);
setup_aws(#state{
    bucket_region = BucketRegion
}) ->
    #{
        access_key_id := AccessKey,
        secret_access_key := Secret,
        token := Token
    } = aws_credentials:get_credentials(),
    aws_client:make_temporary_client(AccessKey, Secret, Token, BucketRegion).

-spec upload(state()) -> state().
upload(#state{current_packets = []} = State) ->
    lager:info("nothing to upload"),
    State;
upload(
    #state{
        bucket = Bucket,
        current_packets = Packets,
        current_size = Size,
        compressor = Compressor
    } = State
) ->
    StartTime = erlang:system_time(millisecond),
    AWSClient = setup_aws(State),

    Timestamp = erlang:system_time(millisecond),
    FileName = erlang:list_to_binary("packetreport." ++ erlang:integer_to_list(Timestamp) ++ ".gz"),
    Last = zlib:deflate(Compressor, [], finish),
    zlib:deflateEnd(Compressor),
    zlib:close(Compressor),

    NewCompressor = zlib:open(),
    ok = zlib:deflateInit(NewCompressor, default, deflated, 16 + ?MAX_WBITS, 8, default),

    MD = [
        {filename, erlang:binary_to_list(FileName)},
        {bucket, erlang:binary_to_list(Bucket)},
        {packet_cnt, erlang:length(Packets)},
        {gzip_bytes, Size + erlang:iolist_size(Last)},
        {bytes, Size}
    ],
    lager:info(MD, "uploading report"),
    case
        aws_s3:put_object(
            AWSClient,
            Bucket,
            FileName,
            #{
                <<"Body">> => lists:reverse([Last | Packets]),
                <<"ContentType">> => <<"application/octet-stream">>
            }
        )
    of
        {ok, _, _Response} ->
            lager:info(MD, "upload success"),
            ok = hpr_metrics:observe_packet_report(ok, StartTime),
            State#state{current_packets = [], current_size = 0, compressor = NewCompressor};
        _Error ->
            %% XXX the zlib compressor is not reusable
            %% XXX we should put the failed upload somewhere
            lager:error(MD, "upload failed ~p", [_Error]),
            ok = hpr_metrics:observe_packet_report(error, StartTime),
            State#state{current_packets = [], current_size = 0, compressor = NewCompressor}
    end.

-spec schedule_upload(Interval :: non_neg_integer()) -> ok.
schedule_upload(Interval) ->
    _ = erlang:send_after(Interval, self(), ?UPLOAD),
    ok.

-spec get_local_host_port() -> {binary(), binary()}.
get_local_host_port() ->
    get_local_host_port(
        os:getenv("HPR_PACKET_REPORTER_LOCAL_HOST", []),
        os:getenv("HPR_PACKET_REPORTER_LOCAL_PORT", [])
    ).

-spec get_local_host_port(Host :: string() | binary(), Port :: string() | binary()) ->
    {binary(), binary()}.
get_local_host_port([], []) ->
    {<<"localhost">>, <<"4556">>};
get_local_host_port([], Port) ->
    get_local_host_port(<<"localhost">>, Port);
get_local_host_port(Host, []) ->
    get_local_host_port(Host, <<"4556">>);
get_local_host_port(Host, Port) when is_list(Host) ->
    get_local_host_port(erlang:list_to_binary(Host), Port);
get_local_host_port(Host, Port) when is_list(Port) ->
    get_local_host_port(Host, erlang:list_to_binary(Port));
get_local_host_port(Host, Port) when is_binary(Host) andalso is_binary(Port) ->
    {Host, Port}.
