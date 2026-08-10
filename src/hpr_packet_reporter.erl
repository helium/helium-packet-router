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
    %% Optional S3-compatible endpoint, e.g. <<"https://t3.storageapi.dev">>.
    %% Empty means use the real AWS endpoint derived from bucket_region.
    endpoint = <<>> :: binary(),
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
        endpoint = normalize_endpoint(maps:get(aws_endpoint, Args, <<>>)),
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
    IsFree :: boolean(),
    ReceivedTime :: non_neg_integer()
) -> binary().
encode_packet(Packet, Route, true = IsFree, ReceivedTime) ->
    EncodedPacket = hpr_packet_report:encode(
        hpr_packet_report:new(Packet, Route, IsFree, ReceivedTime)
    ),
    PacketSize = erlang:size(EncodedPacket),
    <<PacketSize:32/big-integer-unsigned, EncodedPacket/binary>>;
encode_packet(Packet, Route, false, ReceivedTime) ->
    NetID = hpr_route:net_id(Route),
    FreeNetIDs = application:get_env(?APP, ?HPR_FREE_NET_IDS, []),
    IsFree = lists:member(NetID, FreeNetIDs),
    EncodedPacket = hpr_packet_report:encode(
        hpr_packet_report:new(Packet, Route, IsFree, ReceivedTime)
    ),
    PacketSize = erlang:size(EncodedPacket),
    <<PacketSize:32/big-integer-unsigned, EncodedPacket/binary>>.

-spec setup_aws(state()) -> aws_client:aws_client().
%% Explicit S3-compatible endpoint (MinIO, rustfs, Railway buckets, ...).
%%
%% aws_s3 keys two behaviours off `region := <<"local">>`: build_host/3 uses the
%% `endpoint` verbatim instead of composing <bucket>.s3.<region>.<endpoint>, and
%% build_url/4 keeps the bucket in the path instead of the host. That is exactly
%% path-style addressing against a custom host, so the client map is built here
%% rather than via aws_client:make_local_client/4, whose `proto` is hardcoded to
%% http and whose port defaults to 4556.
setup_aws(#state{endpoint = Endpoint}) when Endpoint =/= <<>> ->
    Credentials = aws_credentials:get_credentials(),
    {Proto, Host, Port} = parse_endpoint(Endpoint),
    with_token(
        #{
            access_key_id => maps:get(access_key_id, Credentials),
            secret_access_key => maps:get(secret_access_key, Credentials),
            region => <<"local">>,
            endpoint => Host,
            proto => Proto,
            port => Port,
            service => undefined
        },
        Credentials
    );
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
    Credentials = aws_credentials:get_credentials(),
    %% Static credentials come from aws_credentials:make_map/3, which has no
    %% `token` key at all, so matching on `token :=` would badmatch. Only
    %% temporary (STS) credentials carry one.
    with_token(
        #{
            access_key_id => maps:get(access_key_id, Credentials),
            secret_access_key => maps:get(secret_access_key, Credentials),
            region => BucketRegion,
            endpoint => <<"amazonaws.com">>,
            proto => <<"https">>,
            port => <<"443">>,
            service => undefined
        },
        Credentials
    ).

-spec with_token(aws_client:aws_client(), map()) -> aws_client:aws_client().
with_token(Client, Credentials) ->
    case maps:get(token, Credentials, undefined) of
        undefined -> Client;
        Token -> maps:put(token, Token, Client)
    end.

%% Treat an unset endpoint as absent. relx's substitution for sys.config.src
%% leaves `${VAR}` literal when the variable is unset in some versions, which
%% would otherwise be taken as a real host.
-spec normalize_endpoint(binary()) -> binary().
normalize_endpoint(<<>>) ->
    <<>>;
normalize_endpoint(Endpoint) when is_binary(Endpoint) ->
    case binary:match(Endpoint, <<"${">>) of
        nomatch -> Endpoint;
        _ -> <<>>
    end.

%% Split <<"https://host:port">> into {Proto, Host, Port}. The scheme is
%% optional and defaults to https; the port defaults to 443 for https and 80
%% for http.
-spec parse_endpoint(binary()) -> {binary(), binary(), binary()}.
parse_endpoint(Endpoint) ->
    {Proto, Rest} =
        case Endpoint of
            <<"https://", R/binary>> -> {<<"https">>, R};
            <<"http://", R/binary>> -> {<<"http">>, R};
            R -> {<<"https">>, R}
        end,
    DefaultPort =
        case Proto of
            <<"https">> -> <<"443">>;
            <<"http">> -> <<"80">>
        end,
    Trimmed = erlang:iolist_to_binary(string:trim(Rest, trailing, "/")),
    {Host, Port} =
        case binary:split(Trimmed, <<":">>) of
            [H, P] -> {H, P};
            [H] -> {H, DefaultPort}
        end,
    {Proto, Host, Port}.

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
