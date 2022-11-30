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
    stream :: grpc_client:stream() | undefined,
    conn_backoff :: backoff:backoff()
}).

-define(SERVER, ?MODULE).
-define(INIT_STREAM, init_stream).
-define(RCV_CFG_UPDATE, receive_config_update).
-define(RCV_TIMEOUT, timer:seconds(5)).

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
    case hpr_cs_conn_worker:get_connection() of
        undefined ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            lager:error("failed to get connection sleeping ~wms", [Delay]),
            _ = erlang:send_after(Delay, self(), ?INIT_STREAM),
            {noreply, State#state{conn_backoff = Backoff1}};
        Connection ->
            {_, Backoff1} = backoff:succeed(Backoff0),
            #{http_connection := Pid} = Connection,
            _Ref = erlang:monitor(process, Pid, [{tag, {'DOWN', ?MODULE}}]),
            lager:info("connected"),
            {ok, Stream} = grpc_client:new_stream(
                Connection, 'helium.config.session_key_filter', stream, client_config_pb
            ),
            %% Sending SKF Stream Request
            {PubKey, SigFun} = persistent_term:get(?HPR_KEY),
            PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
            SKFStreamReq = hpr_skf_stream_req:new(PubKeyBin),
            SignedSKFStreamReq = hpr_skf_stream_req:sign(SKFStreamReq, SigFun),
            ok = grpc_client:send_last(
                Stream, hpr_skf_stream_req:to_map(SignedSKFStreamReq)
            ),
            lager:info("stream initialized"),
            self() ! ?RCV_CFG_UPDATE,
            {noreply, State#state{stream = Stream, conn_backoff = Backoff1}}
    end;
handle_info(
    ?RCV_CFG_UPDATE,
    #state{
        stream = Stream, conn_backoff = Backoff0
    } = State
) ->
    case grpc_client:rcv(Stream, ?RCV_TIMEOUT) of
        {headers, _Headers} ->
            self() ! ?RCV_CFG_UPDATE,
            {noreply, State};
        {data, SKFStreamRes} ->
            ok = process_res(hpr_skf_stream_res:from_map(SKFStreamRes)),
            lager:info("got sfk update"),
            self() ! ?RCV_CFG_UPDATE,
            {noreply, State};
        eof ->
            lager:warning("got eof"),
            self() ! ?INIT_STREAM,
            {noreply, State#state{stream = undefined}};
        {error, timeout} ->
            lager:debug("rcv timeout"),
            {_, Backoff1} = backoff:succeed(Backoff0),
            self() ! ?RCV_CFG_UPDATE,
            {noreply, State#state{conn_backoff = Backoff1}};
        {error, E} ->
            lager:error("failed to rcv ~p", [E]),
            self() ! ?INIT_STREAM,
            {noreply, State#state{stream = undefined}}
    end;
handle_info({{'DOWN', ?MODULE}, _Mon, process, _Pid, _ExitReason}, State) ->
    lager:info("connection ~p went down ~p", [_Pid, _ExitReason]),
    self() ! ?INIT_STREAM,
    {noreply, State#state{stream = undefined}};
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
