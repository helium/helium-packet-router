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
    refresh_route/1
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

-record(state, {
    stream :: grpcbox_client:stream() | undefined,
    conn_backoff :: backoff:backoff()
}).

-define(SERVER, ?MODULE).
-define(INIT_STREAM, init_stream).

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

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    lager:info("starting ~p with ~p", [?MODULE, Args]),
    self() ! ?INIT_STREAM,
    {ok, #state{
        stream = undefined,
        conn_backoff = Backoff
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
handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

handle_info(?INIT_STREAM, #state{conn_backoff = Backoff0} = State) ->
    lager:info("connecting"),
    SigFun = hpr_utils:sig_fun(),
    PubKeyBin = hpr_utils:pubkey_bin(),
    RouteStreamReq = hpr_route_stream_req:new(PubKeyBin),
    SignedRouteStreamReq = hpr_route_stream_req:sign(RouteStreamReq, SigFun),
    StreamOptions = #{channel => ?IOT_CONFIG_CHANNEL},
    case helium_iot_config_route_client:stream(SignedRouteStreamReq, StreamOptions) of
        {ok, Stream} ->
            lager:info("stream initialized"),
            {_, Backoff1} = backoff:succeed(Backoff0),
            ok = hpr_route_ets:delete_all(),
            {noreply, State#state{
                stream = Stream, conn_backoff = Backoff1
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
handle_info({data, _StreamID, RouteStreamRes}, #state{} = State) ->
    Action = hpr_route_stream_res:action(RouteStreamRes),
    Data = hpr_route_stream_res:data(RouteStreamRes),
    {Type, _} = Data,
    lager:debug([{action, Action}, {type, Type}], "got route stream update"),
    _ = erlang:spawn(
        fun() ->
            ok = process_route_stream_res(Action, Data),
            {Type, _} = Data,
            ok = hpr_metrics:ics_update(Type, Action)
        end
    ),
    {noreply, State};
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
    hpr_route_ets:insert_route(Route);
process_route_stream_res(add, {eui_pair, EUIPair}) ->
    hpr_route_ets:insert_eui_pair(EUIPair);
process_route_stream_res(add, {devaddr_range, DevAddrRange}) ->
    hpr_route_ets:insert_devaddr_range(DevAddrRange);
process_route_stream_res(add, {skf, SKF}) ->
    hpr_route_ets:insert_skf(SKF);
process_route_stream_res(remove, {route, Route}) ->
    hpr_route_ets:delete_route(Route);
process_route_stream_res(remove, {eui_pair, EUIPair}) ->
    hpr_route_ets:delete_eui_pair(EUIPair);
process_route_stream_res(remove, {devaddr_range, DevAddrRange}) ->
    hpr_route_ets:delete_devaddr_range(DevAddrRange);
process_route_stream_res(remove, {skf, SKF}) ->
    hpr_route_ets:delete_skf(SKF).

-spec refresh_skfs(hpr_route:id()) ->
    {ok, {Old :: list(hpr_skf:skf()), Current :: list(hpr_skf:skf())}} | {error, any()}.
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
                    Previous = hpr_route_ets:skfs_for_route(RouteID),
                    PreviousCnt = hpr_route_ets:replace_route_skfs(RouteID, SKFs),
                    lager:info(
                        [{previous, PreviousCnt}, {current, length(SKFs)}],
                        "route refresh skfs"
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
                    Previous = hpr_route_ets:eui_pairs_for_route(RouteID),
                    PreviousCnt = hpr_route_ets:replace_route_euis(RouteID, EUIs),
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
                    Previous = hpr_route_ets:devaddr_ranges_for_route(RouteID),
                    PreviousCnt = hpr_route_ets:replace_route_devaddrs(RouteID, Devaddrs),
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
