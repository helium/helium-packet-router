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
    aws :: hpr_s3_client:opts(),
    server_name :: binary(),
    stale_threshold :: non_neg_integer()
}).

-type state() :: #state{}.
-type gateway_liveness_reporter_opts() ::
    #{
        aws_bucket => binary(),
        aws_bucket_region => binary(),
        aws_endpoint => binary(),
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
get_bucket(#state{aws = Aws}) ->
    hpr_s3_client:bucket(Aws).

-spec get_client(state()) -> aws_client:aws_client().
get_client(#state{aws = Aws}) ->
    hpr_s3_client:client(Aws).

-endif.

%% ------------------------------------------------------------------
%%% gen_server Function Definitions
%% ------------------------------------------------------------------
-spec init(gateway_liveness_reporter_opts()) -> {ok, state()}.
init(
    #{
        aws_bucket := _,
        report_interval := ReportCron,
        checkpoint_interval := CheckpointCron,
        stale_threshold := StaleThreshold
    } =
        Args
) ->
    %% Resolved before the log line below: a half-configured credential pair
    %% raises here, and Args must never be logged wholesale.
    Aws = hpr_s3_client:from_config(Args),
    ServerName = server_name(maps:get(server_name, Args, <<>>)),
    lager:info(
        [
            {bucket, hpr_s3_client:bucket(Aws)},
            {endpoint, hpr_s3_client:endpoint(Aws)},
            {credential_source, hpr_s3_client:credential_source(Aws)},
            {server_name, ServerName},
            {report_interval, ReportCron},
            {checkpoint_interval, CheckpointCron},
            {stale_threshold, StaleThreshold}
        ],
        "started"
    ),
    ok =
        ensure_job(?CHECKPOINT_JOB, CheckpointCron, {gen_server, cast, [?SERVER, checkpoint]}),
    ok = ensure_job(?REPORT_JOB, ReportCron, {gen_server, cast, [?SERVER, report]}),
    {ok, #state{
        aws = Aws,
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

-spec report(state()) -> ok.
report(#state{aws = Aws, server_name = ServerName}) ->
    Bucket = hpr_s3_client:bucket(Aws),
    case hpr_gateway_liveness_storage:all() of
        [] ->
            lager:info("nothing to report"),
            ok;
        Entries ->
            StartTime = erlang:system_time(millisecond),

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
            %% Building the client can raise (missing or half-configured
            %% credentials); without the catch those failures would bypass the
            %% error metric entirely and show up only as a daily log line.
            try
                aws_s3:put_object(
                    hpr_s3_client:client(Aws),
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
            catch
                Class:Reason ->
                    lager:error(MD, "upload crashed ~p:~p", [Class, Reason]),
                    ok = hpr_metrics:observe_liveness_report(error, StartTime)
            end
    end.

%% Name this instance reports itself as. Comes from config so deployments where
%% the hostname is meaningless can label their reports.
%% An empty value, or a variable relx left unsubstituted, falls back to the
%% hostname.
-spec server_name(binary()) -> binary().
server_name(<<>>) ->
    default_server_name();
server_name(ServerName) when is_binary(ServerName) ->
    case binary:match(ServerName, <<"${">>) of
        nomatch ->
            ServerName;
        _ ->
            default_server_name()
    end.

-spec default_server_name() -> binary().
default_server_name() ->
    {ok, Hostname} = inet:gethostname(),
    erlang:list_to_binary(Hostname).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

server_name_test() ->
    ?assertEqual(<<"hpr-us-west-1">>, server_name(<<"hpr-us-west-1">>)),
    ?assertEqual(default_server_name(), server_name(<<>>)),
    ?assertEqual(
        default_server_name(),
        server_name(<<"${HPR_LIVENESS_REPORTER_SERVER_NAME}">>)
    ),
    ok.

-endif.
