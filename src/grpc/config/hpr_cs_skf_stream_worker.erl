-module(hpr_cs_skf_stream_worker).

-behaviour(gen_server).

-include("hpr.hrl").

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
    lager:info("starting session key filter worker"),
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
    {PubKey, SigFun} = persistent_term:get(?HPR_KEY),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    SKFStreamReq = hpr_skf_stream_req:new(PubKeyBin),
    SignedSKFStreamReq = hpr_skf_stream_req:sign(SKFStreamReq, SigFun),
    SignedSKFStreamReqMap = hpr_skf_stream_req:to_map(SignedSKFStreamReq),
    StreamOptions = #{channel => config_channel},

    case helium_config_session_key_filter_client:stream(SignedSKFStreamReqMap, StreamOptions) of
        {ok, Stream} ->
            lager:info("stream initialized"),
            {_, Backoff1} = backoff:succeed(Backoff0),
            {noreply, State#state{stream = Stream, conn_backoff = Backoff1}};
        {error, _E} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            lager:error("failed to get stream sleeping ~wms", [Delay]),
            _ = erlang:send_after(Delay, self(), ?INIT_STREAM),
            {noreply, State#state{conn_backoff = Backoff1}}
    end;
%% GRPC stream callbacks
handle_info({data, _StreamID, SKFStreamRes}, State) ->
    lager:debug("sfk update"),
    ok = process_res(hpr_skf_stream_res:from_map(SKFStreamRes)),
    {noreply, State};
handle_info(
    {'DOWN', Ref, process, Pid, _Reason},
    #state{stream = #{stream_pid := Pid, monitor_ref := Ref}} = State
) ->
    lager:warning("stream closed"),
    self() ! ?INIT_STREAM,
    {noreply, State#state{stream = undefined}};
handle_info({headers, _StreamID, _Headers}, State) ->
    %% noop on headers
    {noreply, State};
handle_info({trailers, _StreamID, _Trailers}, State) ->
    %% noop on trailers
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("unimplemented_info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    lager:error("terminate ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec process_res(
    SKFStreamRes :: hpr_skf_stream_res:res()
) -> ok.
process_res(SKFStreamRes) ->
    SKF = hpr_skf_stream_res:filter(SKFStreamRes),
    case hpr_skf_stream_res:action(SKFStreamRes) of
        delete ->
            hpr_skf_ets:delete(SKF);
        _ ->
            hpr_skf_ets:insert(SKF)
    end.
