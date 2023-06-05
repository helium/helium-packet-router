%%%-------------------------------------------------------------------
%% @doc
%% @end
%%%-------------------------------------------------------------------
-module(hpr_http_roaming_downlink_stream_worker).

-behaviour(gen_server).

-include("hpr.hrl").
-include("../../grpc/autogen/downlink_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1
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

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    lager:info("starting downlink worker"),
    self() ! ?INIT_STREAM,
    {ok, #state{
        stream = undefined,
        conn_backoff = Backoff
    }}.

handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

handle_info(?INIT_STREAM, #state{conn_backoff = Backoff0} = State) ->
    lager:info("connecting"),
    SigFun = hpr_utils:sig_fun(),
    %% TODO: Region hardcoded from now until it is used on server side
    Req = hpr_http_roaming_register:new('US915'),
    SignedReq = hpr_http_roaming_register:sign(Req, SigFun),
    StreamOptions = #{channel => ?DOWNLINK_CHANNEL},

    case helium_downlink_http_roaming_client:stream(SignedReq, StreamOptions) of
        {ok, Stream} ->
            lager:info("stream initialized"),
            {_, Backoff1} = backoff:succeed(Backoff0),
            {noreply, State#state{stream = Stream, conn_backoff = Backoff1}};
        {error, undefined_channel} ->
            lager:error(
                "`downlink_channel` is not defined, or not started. Not attempting to reconnect."
            ),
            {noreply, State};
        {error, _E} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            lager:error("failed to get stream sleeping ~wms", [Delay]),
            _ = erlang:send_after(Delay, self(), ?INIT_STREAM),
            {noreply, State#state{conn_backoff = Backoff1}}
    end;
%% GRPC stream callbacks
handle_info({data, _StreamID, Downlink}, State) ->
    lager:debug("got downlink"),
    _ = erlang:spawn(fun() -> process_downlink(Downlink) end),
    {noreply, State};
handle_info({headers, _StreamID, _Headers}, State) ->
    %% noop on headers
    {noreply, State};
handle_info({trailers, _StreamID, Trailers}, State) ->
    %% IF a stream is closed by the server side, Trailers will be
    %% received before the EOS. Removing the stream from state will
    %% mean none of the other clauses match, and reconnecting will not
    %% be attempted.
    %% ref: https://grpc.github.io/grpc/core/md_doc_statuscodes.html
    case Trailers of
        {<<"12">>, _, _} ->
            lager:error(
                "helium.downlink.http_roaming/stream not implemented. "
                "Make sure you're pointing at the right server."
            ),
            {noreply, State#state{stream = undefined}};
        _ ->
            {noreply, State}
    end;
handle_info(
    {'DOWN', _Ref, process, Pid, Reason},
    #state{stream = #{stream_pid := Pid}, conn_backoff = Backoff0} = State
) ->
    {Delay, Backoff1} = backoff:fail(Backoff0),
    lager:info("stream went down from the other side for ~p, sleeping ~wms", [Reason, Delay]),
    _ = erlang:send_after(Delay, self(), ?INIT_STREAM),
    {noreply, State#state{stream = undefined, conn_backoff = Backoff1}};
handle_info(
    {eos, StreamID},
    #state{stream = #{stream_id := StreamID}, conn_backoff = Backoff0} = State
) ->
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

-spec process_downlink(
    Downlink :: #http_roaming_downlink_v1_pb{}
) -> {integer(), binary()}.
process_downlink(#http_roaming_downlink_v1_pb{data = Data}) ->
    Decoded = jsx:decode(Data),
    case hpr_http_roaming:handle_message(Decoded) of
        ok ->
            {200, <<"OK">>};
        {error, _} = Err ->
            lager:error("dowlink handle message error ~p", [Err]),
            {500, <<"An error occurred">>};
        {join_accept, {PubKeyBin, PacketDown}, {PRStartNotif, Endpoint}} ->
            lager:debug(
                [{gateway, hpr_utils:gateway_name(PubKeyBin)}],
                "sending downlink"
            ),
            case hpr_packet_router_service:send_packet_down(PubKeyBin, PacketDown) of
                ok ->
                    _ = hackney:post(
                        Endpoint,
                        [],
                        jsx:encode(PRStartNotif),
                        [with_body]
                    ),
                    {200, <<"downlink sent: 1">>};
                {error, not_found} ->
                    _ = hackney:post(
                        Endpoint,
                        [],
                        jsx:encode(PRStartNotif#{'Result' => #{'ResultCode' => <<"XmitFailed">>}}),
                        [with_body]
                    ),
                    {404, <<"Not Found">>}
            end;
        {downlink, PayloadResponse, {PubKeyBin, PacketDown}, {Endpoint, FlowType}} ->
            lager:debug(
                [{gateway, hpr_utils:gateway_name(PubKeyBin)}],
                "sending downlink"
            ),
            case hpr_packet_router_service:send_packet_down(PubKeyBin, PacketDown) of
                {error, not_found} ->
                    {404, <<"Not Found">>};
                ok ->
                    case FlowType of
                        sync ->
                            {200, jsx:encode(PayloadResponse)};
                        async ->
                            _ = erlang:spawn(fun() ->
                                case
                                    hackney:post(Endpoint, [], jsx:encode(PayloadResponse), [
                                        with_body
                                    ])
                                of
                                    {ok, Code, _, _} ->
                                        lager:debug(
                                            [{gateway, hpr_utils:gateway_name(PubKeyBin)}],
                                            "async downlink response ~w, Endpoint: ~s",
                                            [Code, Endpoint]
                                        );
                                    {error, Reason} ->
                                        lager:debug(
                                            [{gateway, hpr_utils:gateway_name(PubKeyBin)}],
                                            "async downlink response ~s, Endpoint: ~s",
                                            [Reason, Endpoint]
                                        )
                                end
                            end),
                            {200, <<"downlink sent: 2">>}
                    end
            end
    end.
