-module(hpr_packet_reporter).

-behaviour(gen_server).

-include("hpr.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1, report_packet/4]).
%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).

-export([get_bucket/1, get_client/1, get_current_packets/1]).

-endif.

-define(SERVER, ?MODULE).
-define(UPLOAD, upload).
-define(MAX_WBITS, 15).

-record(state, {
    aws :: hpr_s3_client:opts(),
    report_max_size :: non_neg_integer(),
    report_interval :: non_neg_integer(),
    compressor,
    current_packets = [] :: [iodata()],
    current_size = 0 :: non_neg_integer()
}).

-type state() :: #state{}.
-type packet_reporter_opts() ::
    #{
        aws_bucket => binary(),
        aws_bucket_region => binary(),
        aws_endpoint => binary(),
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
) ->
    ok.
report_packet(Packet, PacketRoute, IsFree, ReceivedTime) ->
    EncodedPacket = encode_packet(Packet, PacketRoute, IsFree, ReceivedTime),
    gen_server:cast(?SERVER, {report_packet, EncodedPacket}).

%% ------------------------------------------------------------------
%%% Test Function Definitions
%% ------------------------------------------------------------------

-ifdef(TEST).

-spec get_bucket(state()) -> binary().
get_bucket(#state{aws = Aws}) ->
    hpr_s3_client:bucket(Aws).

-spec get_client(state()) -> aws_client:aws_client().
get_client(#state{aws = Aws}) ->
    hpr_s3_client:client(Aws).

%% Named accessor so suites do not index into #state{} positionally — adding a
%% field silently shifts every element/2 index after it.
-spec get_current_packets(state()) -> [iodata()].
get_current_packets(#state{current_packets = Packets}) ->
    Packets.

-endif.

%% ------------------------------------------------------------------
%%% gen_server Function Definitions
%% ------------------------------------------------------------------
-spec init(packet_reporter_opts()) -> {ok, state()}.
init(
    #{
        aws_bucket := _,
        report_max_size := MaxSize,
        report_interval := Interval
    } =
        Args
) ->
    %% Resolved before the log line below: a half-configured credential pair
    %% raises here, and Args must never be logged wholesale.
    Aws = hpr_s3_client:from_config(Args),
    lager:info(
        [
            {bucket, hpr_s3_client:bucket(Aws)},
            {endpoint, hpr_s3_client:endpoint(Aws)},
            {credential_source, hpr_s3_client:credential_source(Aws)},
            {report_interval, Interval},
            {report_max_size, MaxSize}
        ],
        "started"
    ),
    %% One cast arrives here per reported uplink while this process holds up to
    %% report_max_size of compressed report between uploads. Keeping the mailbox
    %% off-heap stops every GC of that heap from also walking the queued messages.
    _ = erlang:process_flag(message_queue_data, off_heap),
    ok = schedule_upload(Interval),
    Compressor = zlib:open(),
    ok = zlib:deflateInit(Compressor, default, deflated, 16 + ?MAX_WBITS, 8, default),
    {ok, #state{
        aws = Aws,
        compressor = Compressor,
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
    } =
        State
) when
    Size < MaxSize
->
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
    } =
        State
) when
    Size >= MaxSize
->
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
    IsFree :: boolean(),
    ReceivedTime :: non_neg_integer()
) ->
    binary().
encode_packet(Packet, Route, true = IsFree, ReceivedTime) ->
    EncodedPacket =
        hpr_packet_report:encode(
            hpr_packet_report:new(Packet, Route, IsFree, ReceivedTime)
        ),
    PacketSize = erlang:size(EncodedPacket),
    <<PacketSize:32/big-integer-unsigned, EncodedPacket/binary>>;
encode_packet(Packet, Route, false, ReceivedTime) ->
    NetID = hpr_route:net_id(Route),
    FreeNetIDs = application:get_env(?APP, ?HPR_FREE_NET_IDS, []),
    IsFree = lists:member(NetID, FreeNetIDs),
    EncodedPacket =
        hpr_packet_report:encode(
            hpr_packet_report:new(Packet, Route, IsFree, ReceivedTime)
        ),
    PacketSize = erlang:size(EncodedPacket),
    <<PacketSize:32/big-integer-unsigned, EncodedPacket/binary>>.

-spec upload(state()) -> state().
upload(#state{current_packets = []} = State) ->
    lager:info("nothing to upload"),
    State;
upload(
    #state{
        aws = Aws,
        current_packets = Packets,
        current_size = Size,
        compressor = Compressor
    } =
        State
) ->
    StartTime = erlang:system_time(millisecond),
    Bucket = hpr_s3_client:bucket(Aws),

    Timestamp = erlang:system_time(millisecond),
    FileName =
        erlang:list_to_binary("packetreport." ++ erlang:integer_to_list(Timestamp) ++ ".gz"),
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
    %% Building the client can raise (missing or half-configured credentials);
    %% without the catch those failures would bypass the error metric entirely.
    try
        aws_s3:put_object(
            hpr_s3_client:client(Aws),
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
            State#state{
                current_packets = [],
                current_size = 0,
                compressor = NewCompressor
            };
        _Error ->
            %% XXX the zlib compressor is not reusable
            %% XXX we should put the failed upload somewhere
            lager:error(MD, "upload failed ~p", [_Error]),
            ok = hpr_metrics:observe_packet_report(error, StartTime),
            State#state{
                current_packets = [],
                current_size = 0,
                compressor = NewCompressor
            }
    catch
        Class:Reason ->
            lager:error(MD, "upload crashed ~p:~p", [Class, Reason]),
            ok = hpr_metrics:observe_packet_report(error, StartTime),
            State#state{
                current_packets = [],
                current_size = 0,
                compressor = NewCompressor
            }
    end.

-spec schedule_upload(Interval :: non_neg_integer()) -> ok.
schedule_upload(Interval) ->
    _ = erlang:send_after(Interval, self(), ?UPLOAD),
    ok.
