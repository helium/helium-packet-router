-module(hpr_gateway_liveness_reporter).

-behaviour(gen_server).

-include("hpr.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1]).
%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).

-export([get_bucket/1, get_client/1]).

-endif.

-define(SERVER, ?MODULE).
-define(CHECKPOINT_JOB, hpr_gateway_liveness_checkpoint).
-define(REPORT_JOB, hpr_gateway_liveness_report).
-define(FILE_NAME, "packet_router_liveness_report").

-record(state, {
    bucket :: binary(),
    bucket_region :: binary(),
    server_name :: binary(),
    stale_threshold :: non_neg_integer()
}).

-type state() :: #state{}.
-type gateway_liveness_reporter_opts() ::
    #{
        aws_bucket => binary(),
        aws_bucket_region => binary(),
        report_interval => binary(),
        checkpoint_interval => binary(),
        stale_threshold => non_neg_integer(),
        server_name => binary()
    }.

%% ------------------------------------------------------------------
%%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(gateway_liveness_reporter_opts()) -> any().
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

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
-spec init(gateway_liveness_reporter_opts()) -> {ok, state()}.
init(
    #{
        aws_bucket := Bucket,
        aws_bucket_region := BucketRegion,
        report_interval := ReportCron,
        checkpoint_interval := CheckpointCron,
        stale_threshold := StaleThreshold
    } =
        Args
) ->
    lager:info(
        maps:to_list(Args), "started"
    ),
    ServerName = maps:get(server_name, Args, default_server_name()),
    ok =
        ensure_job(?CHECKPOINT_JOB, CheckpointCron, {gen_server, cast, [?SERVER, checkpoint]}),
    ok = ensure_job(?REPORT_JOB, ReportCron, {gen_server, cast, [?SERVER, report]}),
    {ok, #state{
        bucket = Bucket,
        bucket_region = BucketRegion,
        server_name = ServerName,
        stale_threshold = StaleThreshold
    }}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(checkpoint, State) ->
    lager:info("checkpoint time"),
    ok = hpr_gateway_liveness_storage:checkpoint(),
    {noreply, State};
handle_cast(report, #state{stale_threshold = StaleThreshold} = State) ->
    lager:info("report time"),
    ok = report(State),
    _ = hpr_gateway_liveness_storage:expire(StaleThreshold),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok = ecron:delete(?CHECKPOINT_JOB),
    ok = ecron:delete(?REPORT_JOB),
    ok.

%% ------------------------------------------------------------------
%%% Internal Function Definitions
%% ------------------------------------------------------------------

%% @doc `ecron' jobs are registered VM-wide and outlive this gen_server across
%% crash-restarts, so re-adding a job that's already scheduled (e.g. after a
%% supervisor restart) is expected and not an error.
-spec ensure_job(ecron:name(), ecron:crontab_spec(), ecron:mfargs()) -> ok.
ensure_job(JobName, Spec, MFA) ->
    case ecron:add(JobName, Spec, MFA) of
        {ok, _} ->
            ok;
        {error, already_exist} ->
            ok
    end.

-spec encode_entry(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    LastSeen :: non_neg_integer(),
    ServerName :: binary()
) ->
    binary().
encode_entry(PubKeyBin, LastSeen, ServerName) ->
    EncodedReport =
        hpr_liveness_report:encode(
            hpr_liveness_report:new(PubKeyBin, ServerName, LastSeen)
        ),
    ReportSize = erlang:size(EncodedReport),
    <<ReportSize:32/big-integer-unsigned, EncodedReport/binary>>.

-spec setup_aws(state()) -> aws_client:aws_client().
setup_aws(#state{bucket_region = <<"local">>}) ->
    #{access_key_id := AccessKey, secret_access_key := Secret} =
        aws_credentials:get_credentials(),
    {LocalHost, LocalPort} = get_local_host_port(),
    aws_client:make_local_client(AccessKey, Secret, LocalPort, LocalHost);
setup_aws(#state{bucket_region = BucketRegion}) ->
    #{
        access_key_id := AccessKey,
        secret_access_key := Secret,
        token := Token
    } =
        aws_credentials:get_credentials(),
    aws_client:make_temporary_client(AccessKey, Secret, Token, BucketRegion).

-spec report(state()) -> ok.
report(#state{bucket = Bucket, server_name = ServerName} = State) ->
    case hpr_gateway_liveness_storage:all() of
        [] ->
            lager:info("nothing to report"),
            ok;
        Entries ->
            StartTime = erlang:system_time(millisecond),
            AWSClient = setup_aws(State),

            EncodedEntries =
                [encode_entry(PubKeyBin, LastSeen, ServerName) || {PubKeyBin, LastSeen} <- Entries],
            Body = zlib:gzip(EncodedEntries),

            Timestamp = erlang:system_time(millisecond),
            FileName =
                erlang:list_to_binary(
                    ?FILE_NAME ++
                        "." ++
                        erlang:integer_to_list(Timestamp) ++
                        ".gz"
                ),

            MD = [
                {filename, erlang:binary_to_list(FileName)},
                {bucket, erlang:binary_to_list(Bucket)},
                {entry_cnt, erlang:length(Entries)},
                {gzip_bytes, erlang:byte_size(Body)}
            ],
            lager:info(MD, "uploading report"),
            case
                aws_s3:put_object(
                    AWSClient,
                    Bucket,
                    FileName,
                    #{
                        <<"Body">> => Body,
                        <<"ContentType">> => <<"application/octet-stream">>
                    }
                )
            of
                {ok, _, _Response} ->
                    lager:info(MD, "upload success"),
                    ok = hpr_metrics:observe_liveness_report(ok, StartTime);
                _Error ->
                    lager:error(MD, "upload failed ~p", [_Error]),
                    ok = hpr_metrics:observe_liveness_report(error, StartTime)
            end
    end.

-spec default_server_name() -> binary().
default_server_name() ->
    {ok, Hostname} = inet:gethostname(),
    erlang:list_to_binary(Hostname).

-spec get_local_host_port() -> {binary(), binary()}.
get_local_host_port() ->
    get_local_host_port(
        os:getenv("HPR_LIVENESS_REPORTER_LOCAL_HOST", []),
        os:getenv("HPR_LIVENESS_REPORTER_LOCAL_PORT", [])
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
