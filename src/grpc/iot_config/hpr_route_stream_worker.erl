%%%-------------------------------------------------------------------
%% @doc
%% === Config Service Stream Worker ===
%%
%% Makes a GRPC stream to the config service to receive route updates
%% and forward them dealt with.
%%
%% A "channel" is created `grpcbox' when the app is started. This
%% channel does not make an actual connection. That happens when a
%% stream is created and a message is sent.
%%
%% If a channel goes down, all the stream will receive a `eos'
%% message, and a `DOWN' message. The channel will clean up the
%% remaining stream pids.
%%
%% If a grpc server goes down, it may not have time to send `eos' to all of it's
%% streams, and we will only get a `DOWN' message.
%%
%% Handling both of these, `eos' will result in an unhandled `DOWN' message, and
%% a `DOWN' message will have no corresponding `eos' message.
%%
%% == Known Failures ==
%%
%%   - unimplemented
%%   - undefined channel
%%   - econnrefused
%%
%% = UNIMPLEMENTED Trailers =
%%
%% If we connect to a valid grpc server, but it does not implement the
%% messages we expect, the stream will be "successfully" created, then
%% immediately torn down. The failure will be relayed in `trailers'.
%% In this care, we log the unimplimented message, but do not attempt
%% to reconnect.
%%
%% = Undefined Channel =
%%
%% All workers that talk to the Config Service use the same client
%% channel, `iot_config_channel'. Channels do not make connections to
%% servers. If this message is received it means the channel was never
%% created, either through configuration, or explicitly with
%% `grpcbox_client:connect/3'.
%%
%% = econnrefused =
%%
%% The `iot_config_channel' has been improperly configured to point at a
%% non-grpc server. Or, the grpc server is down. We fail the backoff
%% and try again later.
%%
%% @end
%%%-------------------------------------------------------------------
-module(hpr_route_stream_worker).

-behaviour(gen_server).

-include("hpr.hrl").
-include("../autogen/iot_config_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    refresh_route/1,
    checkpoint/0,
    schedule_checkpoint/0
]).

-export([
    do_checkpoint/1,
    reset_timestamp/0,
    checkpoint_timer/0,
    print_next_checkpoint/0,
    last_timestamp/0,
    reset_connection/0
]).

-ifdef(TEST).
-export([test_counts/0, test_stream/0]).
-endif.

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
-define(BACKOFF_MIN, timer:seconds(1)).
-else.
-define(BACKOFF_MIN, timer:seconds(10)).
-endif.
-define(BACKOFF_MAX, timer:minutes(5)).

-type refresh_map() :: #{
    eui_before := non_neg_integer(),
    eui_after := non_neg_integer(),
    eui_removed := non_neg_integer(),
    eui_added := non_neg_integer(),
    %%
    skf_before := non_neg_integer(),
    skf_after := non_neg_integer(),
    skf_removed := non_neg_integer(),
    skf_added := non_neg_integer(),
    %%
    devaddr_before := non_neg_integer(),
    devaddr_after := non_neg_integer(),
    devaddr_removed := non_neg_integer(),
    devaddr_added := non_neg_integer()
}.

-type counts_map() :: #{
    route := non_neg_integer(),
    eui_pair := non_neg_integer(),
    skf := non_neg_integer(),
    devaddr_range := non_neg_integer()
}.

-record(state, {
    stream :: grpcbox_client:stream() | undefined,
    conn_backoff :: backoff:backoff(),
    counts :: counts_map(),
    last_timestamp = 0 :: non_neg_integer(),
    checkpoint_timer :: undefined | {TimeScheduled :: non_neg_integer(), timer:tref()}
}).

-define(SERVER, ?MODULE).
-define(INIT_STREAM, init_stream).
-define(DETS, hpr_route_stream_worker_dets).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(map()) -> any().
start_link(Args) ->
    gen_server:start_link(
        {local, ?SERVER}, ?SERVER, Args, []
    ).

-spec refresh_route(hpr_route:id()) -> {ok, refresh_map()} | {error, any()}.
refresh_route(RouteID) ->
    gen_server:call(?MODULE, {refresh_route, RouteID}, timer:seconds(120)).

-spec checkpoint() -> ok.
checkpoint() ->
    gen_server:call(?MODULE, checkpoint).

-spec last_timestamp() -> non_neg_integer().
last_timestamp() ->
    gen_server:call(?MODULE, last_timetstamp).

-spec do_checkpoint(LastTimestamp :: non_neg_integer()) -> ok.
do_checkpoint(LastTimestamp) ->
    ok = hpr_route_storage:checkpoint(),
    ok = hpr_eui_pair_storage:checkpoint(),
    ok = hpr_devaddr_range_storage:checkpoint(),
    ok = hpr_skf_storage:checkpoint(),
    ok = dets:insert(?DETS, {timestamp, LastTimestamp}).

-spec schedule_checkpoint() -> {TimeScheduled :: non_neg_integer(), timer:tref()}.
schedule_checkpoint() ->
    Delay = hpr_utils:get_env_int(ics_stream_worker_checkpoint_secs, 300),
    lager:info([{timer_secs, Delay}], "scheduling checkpoint"),
    {ok, Timer} = timer:apply_after(timer:seconds(Delay), ?MODULE, checkpoint, []),
    {erlang:system_time(millisecond), Timer}.

-spec reset_timestamp() -> ok.
reset_timestamp() ->
    gen_server:call(?MODULE, reset_timestamp).

-spec checkpoint_timer() -> undefined | {TimeScheduled :: non_neg_integer(), timer:tref()}.
checkpoint_timer() ->
    gen_server:call(?MODULE, checkpoint_timer).

-spec print_next_checkpoint() -> string().
print_next_checkpoint() ->
    Msg =
        case ?MODULE:checkpoint_timer() of
            undefined ->
                "Timer not active";
            {TimeScheduled, _TimerRef} ->
                Now = erlang:system_time(millisecond),
                TimeLeft = Now - TimeScheduled,
                TotalSeconds = erlang:convert_time_unit(TimeLeft, millisecond, second),
                {_Hour, Minute, Seconds} = calendar:seconds_to_time(TotalSeconds),
                io_lib:format("Running again in T- ~pm ~ps", [Minute, Seconds])
        end,
    lager:info(Msg),
    Msg.

-spec reset_connection() -> ok.
reset_connection() ->
    gen_server:call(?MODULE, reset_connection, timer:seconds(30)).

-ifdef(TEST).

-spec test_counts() -> counts_map().
test_counts() ->
    gen_server:call(?MODULE, test_counts).

-spec test_stream() -> undefined | grpcbox_client:stream().
test_stream() ->
    gen_server:call(?MODULE, test_stream).

-endif.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    lager:info("starting ~p with ~p", [?MODULE, Args]),
    self() ! ?INIT_STREAM,

    ok = open_dets(),
    LastTimestamp =
        case dets:lookup(?DETS, timestamp) of
            [{timestamp, T}] -> T;
            _ -> 0
        end,

    {ok, #state{
        stream = undefined,
        conn_backoff = Backoff,
        counts = #{
            route => 0,
            eui_pair => 0,
            skf => 0,
            devaddr_range => 0
        },
        last_timestamp = LastTimestamp
    }}.

handle_call({refresh_route, RouteID}, _From, State) ->
    DevaddrResponse = refresh_devaddrs(RouteID),
    EUIResponse = refresh_euis(RouteID),
    SKFResponse = refresh_skfs(RouteID),

    Reply =
        case {DevaddrResponse, EUIResponse, SKFResponse} of
            {{ok, {DBefore, DAfter}}, {ok, {EBefore, EAfter}}, {ok, {SBefore, SAfter}}} ->
                {ok, #{
                    eui_before => length(EBefore),
                    eui_after => length(EAfter),
                    eui_removed => length(EBefore -- EAfter),
                    eui_added => length(EAfter -- EBefore),
                    %%
                    skf_before => length(SBefore),
                    skf_after => length(SAfter),
                    skf_removed => length(SBefore -- SAfter),
                    skf_added => length(SAfter -- SBefore),
                    %%
                    devaddr_before => length(DBefore),
                    devaddr_after => length(DAfter),
                    devaddr_removed => length(DBefore -- DAfter),
                    devaddr_added => length(DAfter -- DBefore)
                }};
            {Err, _, _} when element(1, Err) == error -> Err;
            {_, Err, _} when element(1, Err) == error -> Err;
            {_, _, Err} when element(1, Err) == error -> Err;
            Other ->
                {error, {unexpected_response, Other}}
        end,

    {reply, Reply, State};
handle_call(reset_timestamp, _From, #state{} = State) ->
    ok = dets:insert(?DETS, {timestamp, 0}),
    {reply, ok, State#state{last_timestamp = 0}};
handle_call(last_timetstamp, _From, #state{last_timestamp = LastTimestamp} = State) ->
    {reply, LastTimestamp, State};
handle_call(checkpoint_timer, _From, #state{checkpoint_timer = CheckpointTimerRef} = State) ->
    {reply, CheckpointTimerRef, State};
handle_call(test_counts, _From, State) ->
    {reply, State#state.counts, State};
handle_call(test_stream, _From, State) ->
    {reply, State#state.stream, State};
handle_call(checkpoint, _From, #state{last_timestamp = LastTimestamp} = State) ->
    lager:info([{timestamp, LastTimestamp}], "checkpointing configuration"),

    %% We don't spawn the checkpoints to reduce the chance of continued updates
    %% causing weirdness in the DB.
    ok = ?MODULE:do_checkpoint(LastTimestamp),
    CheckpointTimerRef = ?MODULE:schedule_checkpoint(),
    lager:info([{timestamp, LastTimestamp}], "checkpoint done"),

    {reply, ok, State#state{checkpoint_timer = CheckpointTimerRef}};
handle_call(reset_connection, _From, State) ->
    {stop, manual_connection_reset, ok, State};
handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

handle_info(checkpoint, #state{} = State) ->
    ok = ?MODULE:checkpoint(),
    {noreply, State};
handle_info(
    ?INIT_STREAM,
    #state{
        conn_backoff = Backoff0,
        last_timestamp = LastTimestamp,
        checkpoint_timer = PreviousCheckpointTimerRef
    } = State
) ->
    lager:info([{from, LastTimestamp}], "connecting"),
    ok = maybe_cancel_timer(PreviousCheckpointTimerRef),
    SigFun = hpr_utils:sig_fun(),
    PubKeyBin = hpr_utils:pubkey_bin(),

    RouteStreamReq = hpr_route_stream_req:new(PubKeyBin, LastTimestamp),
    SignedRouteStreamReq = hpr_route_stream_req:sign(RouteStreamReq, SigFun),
    StreamOptions = #{channel => ?IOT_CONFIG_CHANNEL},

    case helium_iot_config_route_client:stream(SignedRouteStreamReq, StreamOptions) of
        {ok, Stream} ->
            lager:info([{from, LastTimestamp}], "stream initialized"),
            {_, Backoff1} = backoff:succeed(Backoff0),
            Timer = ?MODULE:schedule_checkpoint(),
            {noreply, State#state{
                stream = Stream,
                conn_backoff = Backoff1,
                checkpoint_timer = Timer
            }};
        {error, undefined_channel} ->
            lager:error(
                "`iot_config_channel` is not defined, or not started. Not attempting to reconnect."
            ),
            {noreply, State};
        {error, _E} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            lager:error("failed to get stream sleeping ~wms : ~p", [Delay, _E]),
            _ = erlang:send_after(Delay, self(), ?INIT_STREAM),
            {noreply, State#state{conn_backoff = Backoff1}}
    end;
%% GRPC stream callbacks
handle_info({data, _StreamID, RouteStreamRes}, #state{counts = Counts0} = State) ->
    Action = hpr_route_stream_res:action(RouteStreamRes),
    Data = hpr_route_stream_res:data(RouteStreamRes),
    Timestamp = hpr_route_stream_res:timestamp(RouteStreamRes),
    {Type, _} = Data,
    lager:debug([{action, Action}, {type, Type}], "got route stream update"),
    Counts1 = Counts0#{Type => maps:get(Type, Counts0, 0) + 1},
    case Type of
        %% Routes are required for many updates, we don't spawn them to make
        %% sure everything is setup by the time updates start coming in for the route.
        route ->
            ok = process_route_stream_res(Action, Data),
            ok = hpr_metrics:ics_update(Type, Action);
        _ ->
            _ = erlang:spawn(
                fun() ->
                    ok = process_route_stream_res(Action, Data),
                    ok = hpr_metrics:ics_update(Type, Action)
                end
            )
    end,
    {noreply, State#state{counts = Counts1, last_timestamp = Timestamp}};
handle_info({headers, _StreamID, _Headers}, State) ->
    %% noop on headers
    {noreply, State};
handle_info({trailers, _StreamID, Trailers}, #state{conn_backoff = Backoff0} = State) ->
    %% IF a stream is closed by the server side, Trailers will be
    %% received before the EOS. Removing the stream from state will
    %% mean none of the other clauses match, and reconnecting will not
    %% be attempted.
    %% ref: https://grpc.github.io/grpc/core/md_doc_statuscodes.html
    case Trailers of
        {<<"12">>, _, _} ->
            lager:error(
                "helium.config.route/stream not implemented. "
                "Make sure you're pointing at the right server."
            ),
            {noreply, State#state{stream = undefined}};
        {<<"7">>, _, _} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            lager:error("UNAUTHORIZED, make sure HPR key is in config service db, sleeping ~wms", [
                Delay
            ]),
            _ = erlang:send_after(Delay, self(), ?INIT_STREAM),
            {noreply, State#state{stream = undefined, conn_backoff = Backoff1}};
        _ ->
            {noreply, State}
    end;
handle_info(
    {'DOWN', _Ref, process, Pid, Reason},
    #state{stream = #{stream_pid := Pid}, conn_backoff = Backoff0} = State
) ->
    %% If a server dies unexpectedly, it may not send an `eos' message to all
    %% it's stream, and we'll only have a `DOWN' to work with.
    {Delay, Backoff1} = backoff:fail(Backoff0),
    lager:info("stream went down from the other side for ~p, sleeping ~wms", [Reason, Delay]),
    _ = erlang:send_after(Delay, self(), ?INIT_STREAM),
    {noreply, State#state{stream = undefined, conn_backoff = Backoff1}};
handle_info(
    {eos, StreamID},
    #state{stream = #{stream_id := StreamID}, conn_backoff = Backoff0} = State
) ->
    %% When streams or channel go down, they first send an `eos' message, then
    %% send a `DOWN' message.
    {Delay, Backoff1} = backoff:fail(Backoff0),
    lager:info("stream went down sleeping ~wms", [Delay]),
    _ = erlang:send_after(Delay, self(), ?INIT_STREAM),
    {noreply, State#state{stream = undefined, conn_backoff = Backoff1}};
handle_info(_Msg, State) ->
    lager:warning("unimplemented_info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    lager:error("terminate ~p", [_Reason]),
    dets:close(?DETS),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec process_route_stream_res(
    RouteStreamRes :: hpr_route_stream_res:action(),
    Data ::
        {route, hpr_route:route()}
        | {eui_pair, hpr_eui_pair:eui_pair()}
        | {devaddr_range, hpr_devaddr_range:devaddr_range()}
        | {skf, hpr_skf:skf()}
) -> ok.
process_route_stream_res(add, {route, Route}) ->
    hpr_route_storage:insert(Route);
process_route_stream_res(add, {eui_pair, EUIPair}) ->
    hpr_eui_pair_storage:insert(EUIPair);
process_route_stream_res(add, {devaddr_range, DevAddrRange}) ->
    hpr_devaddr_range_storage:insert(DevAddrRange);
process_route_stream_res(add, {skf, SKF}) ->
    hpr_skf_storage:insert(SKF);
process_route_stream_res(remove, {route, Route}) ->
    hpr_route_storage:delete(Route);
process_route_stream_res(remove, {eui_pair, EUIPair}) ->
    hpr_eui_pair_storage:delete(EUIPair);
process_route_stream_res(remove, {devaddr_range, DevAddrRange}) ->
    hpr_devaddr_range_storage:delete(DevAddrRange);
process_route_stream_res(remove, {skf, SKF}) ->
    hpr_skf_storage:delete(SKF).

-spec refresh_skfs(hpr_route:id()) ->
    {ok, {
        Old :: list({{SessionKey :: binary(), Devaddr :: binary()}, MaxCopies :: non_neg_integer()}),
        Current :: list(hpr_skf:skf())
    }}
    | {error, any()}.
refresh_skfs(RouteID) ->
    SKFReq = #iot_config_route_skf_list_req_v1_pb{
        route_id = RouteID,
        timestamp = erlang:system_time(millisecond),
        signer = hpr_utils:pubkey_bin()
    },
    SigFun = hpr_utils:sig_fun(),
    EncodedReq = iot_config_pb:encode_msg(SKFReq),
    Signed = SKFReq#iot_config_route_skf_list_req_v1_pb{signature = SigFun(EncodedReq)},

    case
        helium_iot_config_route_client:list_skfs(
            Signed,
            #{channel => ?IOT_CONFIG_CHANNEL}
        )
    of
        {ok, Stream} ->
            case recv_from_stream(Stream) of
                SKFs when erlang:is_list(SKFs) ->
                    Previous = hpr_skf_storage:lookup_route(RouteID),
                    PreviousCnt = hpr_skf_storage:replace_route(RouteID, SKFs),
                    lager:info(
                        "route refresh skfs ~p",
                        [{{previous, PreviousCnt}, {current, length(SKFs)}}]
                    ),
                    {ok, {Previous, SKFs}}
            end;
        {error, _} = Err ->
            lager:error([{route_id, RouteID}, Err], "failed to refresh route skfs"),
            Err
    end.

-spec refresh_euis(hpr_route:id()) ->
    {ok, {Old :: list(hpr_eui_pair:eui_pair()), Current :: list(hpr_eui_pair:eui_pair())}}
    | {error, any()}.
refresh_euis(RouteID) ->
    EUIReq = #iot_config_route_get_euis_req_v1_pb{
        route_id = RouteID,
        timestamp = erlang:system_time(millisecond),
        signer = hpr_utils:pubkey_bin()
    },
    SigFun = hpr_utils:sig_fun(),
    EncodedReq = iot_config_pb:encode_msg(EUIReq),
    Signed = EUIReq#iot_config_route_get_euis_req_v1_pb{signature = SigFun(EncodedReq)},

    case
        helium_iot_config_route_client:get_euis(
            Signed,
            #{channel => ?IOT_CONFIG_CHANNEL}
        )
    of
        {ok, Stream} ->
            case recv_from_stream(Stream) of
                EUIs when erlang:is_list(EUIs) ->
                    Previous = hpr_eui_pair_storage:lookup_for_route(RouteID),
                    PreviousCnt = hpr_eui_pair_storage:replace_route(RouteID, EUIs),
                    lager:info(
                        [{previous, PreviousCnt}, {current, length(EUIs)}],
                        "route refresh euis"
                    ),
                    EUIs0 = [{hpr_eui_pair:app_eui(EUI), hpr_eui_pair:dev_eui(EUI)} || EUI <- EUIs],
                    {ok, {Previous, EUIs0}};
                Err ->
                    Err
            end;
        {error, _E} = Err ->
            lager:error([{route_id, RouteID}, Err], "failed to refresh route euis"),
            Err
    end.

-spec refresh_devaddrs(hpr_route:id()) ->
    {ok, {
        Old :: list(hpr_devaddr_range:devaddr_range()),
        Current :: list(hpr_devaddr_range:devaddr_range())
    }}
    | {error, any()}.
refresh_devaddrs(RouteID) ->
    DevaddrReq = #iot_config_route_get_devaddr_ranges_req_v1_pb{
        route_id = RouteID,
        timestamp = erlang:system_time(millisecond),
        signer = hpr_utils:pubkey_bin()
    },
    SigFun = hpr_utils:sig_fun(),
    EncodedReq = iot_config_pb:encode_msg(DevaddrReq),
    Signed = DevaddrReq#iot_config_route_get_devaddr_ranges_req_v1_pb{
        signature = SigFun(EncodedReq)
    },

    case
        helium_iot_config_route_client:get_devaddr_ranges(
            Signed,
            #{channel => ?IOT_CONFIG_CHANNEL}
        )
    of
        {ok, Stream} ->
            case recv_from_stream(Stream) of
                Devaddrs when erlang:is_list(Devaddrs) ->
                    Previous = hpr_devaddr_range_storage:lookup_for_route(RouteID),
                    PreviousCnt = hpr_devaddr_range_storage:replace_route(RouteID, Devaddrs),
                    lager:info(
                        [{previous, PreviousCnt}, {current, length(Devaddrs)}],
                        "route refresh devaddrs"
                    ),
                    Devaddrs1 = [
                        {hpr_devaddr_range:start_addr(Range), hpr_devaddr_range:end_addr(Range)}
                     || Range <- Devaddrs
                    ],
                    {ok, {Previous, Devaddrs1}};
                Err ->
                    Err
            end;
        {error, _E} = Err ->
            lager:error([{route_id, RouteID}, Err], "failed to refresh route devaddrs"),
            Err
    end.

-spec recv_from_stream(grpcbox_client:stream()) -> list(T) | {error, any()} when
    T :: hpr_skf:skf() | hpr_eui_pair:eui_pair() | hpr_devaddr_range:devaddr_range().
recv_from_stream(Stream) ->
    do_recv_from_stream(init, Stream, []).

do_recv_from_stream(init, Stream, Acc) ->
    do_recv_from_stream(grpcbox_client:recv_data(Stream, timer:seconds(2)), Stream, Acc);
do_recv_from_stream({ok, Data}, Stream, Acc) ->
    do_recv_from_stream(grpcbox_client:recv_data(Stream, timer:seconds(2)), Stream, [Data | Acc]);
do_recv_from_stream({error, _, _} = Err, _Stream, _Acc) ->
    Err;
do_recv_from_stream(timeout, _Stream, _Acc) ->
    {error, recv_timeout};
do_recv_from_stream(stream_finished, _Stream, Acc) ->
    lists:reverse(Acc);
do_recv_from_stream(Msg, _Stream, _Acc) ->
    lager:warning("unhandled msg from stream: ~p", [Msg]),
    {error, {unhandled_message, Msg}}.

-spec open_dets() -> ok.
open_dets() ->
    DataDir = hpr_utils:base_data_dir(),
    DETSFile = filename:join(DataDir, "stream_worker.dets"),
    ok = filelib:ensure_dir(DETSFile),
    case dets:open_file(?DETS, [{file, DETSFile}, {type, set}]) of
        {ok, _DETS} ->
            ok;
        {error, _Reason} ->
            Deleted = file:delete(DETSFile),
            lager:error("failed to open dets ~p deleting file ~p", [_Reason, Deleted]),
            open_dets()
    end.

-spec maybe_cancel_timer(undefined | {TimeScheduled :: non_neg_integer(), timer:tref()}) -> ok.
maybe_cancel_timer(undefined) ->
    ok;
maybe_cancel_timer({_TimeScheduled, Timer}) ->
    lager:info([{t, Timer}, {timer, timer:cancel(Timer)}], "maybe cancelling timer"),
    ok.
