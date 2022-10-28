-module(hpr_packet_reporter).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    report_packet/2
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

-define(SERVER, ?MODULE).
-define(UPLOAD, upload).

-record(state, {
    aws_client :: aws_client:aws_client(),
    bucket :: binary(),
    report_max_size :: non_neg_integer(),
    report_interval :: non_neg_integer(),
    current_packets = [] :: [binary()],
    current_size = 0 :: non_neg_integer()
}).

-type state() :: #state{}.

-type packet_reporter_opts() :: #{
    aws_key => binary(),
    aws_secret => binary(),
    aws_region => binary(),
    aws_bucket => binary(),
    report_interval => non_neg_integer(),
    report_max_size => non_neg_integer(),
    local_host => binary(),
    local_port => binary()
}.

%% ------------------------------------------------------------------
%%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(packet_reporter_opts()) -> any().
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec report_packet(Packet :: hpr_packet_up:packet(), PacketRoute :: hpr_route:route()) -> ok.
report_packet(Packet, PacketRoute) ->
    EncodedPacket = encode_packet(Packet, PacketRoute),
    gen_server:cast(?SERVER, {report_packet, EncodedPacket}).

%% ------------------------------------------------------------------
%%% gen_server Function Definitions
%% ------------------------------------------------------------------
-spec init(packet_reporter_opts()) -> {ok, state()}.
init(
    #{
        aws_bucket := Bucket,
        report_max_size := MaxSize,
        report_interval := Interval
    } = Args
) ->
    lager:info(maps:to_list(Args), "started"),
    AWSClient = setup_aws(Args),
    ok = schedule_upload(Interval),
    {ok, #state{
        aws_client = AWSClient,
        bucket = Bucket,
        report_max_size = MaxSize,
        report_interval = Interval
    }}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(
    {report_packet, EncodedPacket},
    #state{report_max_size = MaxSize, current_packets = Packets, current_size = Size} = State
) when Size < MaxSize ->
    lager:debug("got packet"),
    {noreply, State#state{
        current_packets = [EncodedPacket | Packets],
        current_size = erlang:size(EncodedPacket) + Size
    }};
handle_cast(
    {report_packet, EncodedPacket},
    #state{report_max_size = MaxSize, current_packets = Packets, current_size = Size} = State
) when Size >= MaxSize ->
    lager:debug("got packet, size too big"),
    {noreply,
        upload(State#state{
            current_packets = [EncodedPacket | Packets],
            current_size = erlang:size(EncodedPacket) + Size
        })};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(?UPLOAD, #state{report_interval = Interval} = State) ->
    lager:debug("upload time"),
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

-spec encode_packet(Packet :: hpr_packet_up:packet(), PacketRoute :: hpr_route:route()) -> binary().
encode_packet(Packet, PacketRoute) ->
    EncodedPacket = hpr_packet_report:encode(
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
    ),
    PacketSize = erlang:size(EncodedPacket),
    <<PacketSize:32/big-integer-unsigned, EncodedPacket/binary>>.

-spec setup_aws(packet_reporter_opts()) -> aws_client:aws_client().
setup_aws(#{
    aws_key := AccessKey,
    aws_secret := Secret,
    aws_region := <<"local">>,
    local_port := LocalPort,
    local_host := LocalHost
}) ->
    aws_client:make_local_client(AccessKey, Secret, LocalPort, LocalHost);
setup_aws(#{
    aws_key := AccessKey,
    aws_secret := Secret,
    aws_region := Region
}) ->
    aws_client:make_client(AccessKey, Secret, Region).

-spec upload(state()) -> state().
upload(#state{current_packets = []} = State) ->
    lager:info("nothing to upload"),
    State;
upload(
    #state{aws_client = AWSClient, bucket = Bucket, current_packets = Packets, current_size = Size} =
        State
) ->
    Timestamp = erlang:system_time(millisecond),
    FileName = erlang:list_to_binary("packetreport." ++ erlang:integer_to_list(Timestamp) ++ ".gz"),
    Compressed = zlib:gzip(Packets),

    MD = [
        {filename, FileName},
        {bucket, Bucket},
        {packet_cnt, erlang:length(Packets)},
        {gzip_bytes, erlang:size(Compressed)},
        {bytes, Size}
    ],
    lager:info(MD, "uploading report"),
    case
        aws_s3:put_object(
            AWSClient,
            Bucket,
            FileName,
            #{
                <<"Body">> => Compressed
            }
        )
    of
        {ok, _, _Response} ->
            lager:info(MD, "upload success"),
            State#state{current_packets = [], current_size = 0};
        _Error ->
            lager:error(MD, "upload failed ~p", [_Error]),
            State
    end.

-spec schedule_upload(Interval :: non_neg_integer()) -> ok.
schedule_upload(Interval) ->
    _ = erlang:send_after(Interval, self(), ?UPLOAD),
    ok.
