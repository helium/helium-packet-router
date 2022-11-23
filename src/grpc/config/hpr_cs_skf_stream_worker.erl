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
    handle_continue/2,
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
    connection :: grpc_client:connection() | undefined,
    stream :: grpc_client:stream() | undefined,
    conn_backoff :: backoff:backoff()
}).

-define(SERVER, ?MODULE).
-define(CONNECT, connect).
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
    State = #state{
        connection = undefined,
        stream = undefined,
        conn_backoff = Backoff
    },
    lager:info("starting session key filter worker"),
    {ok, State, {continue, ?CONNECT}}.

handle_continue(?CONNECT, #state{conn_backoff = Backoff0} = State) ->
    lager:info("connecting"),
    case hpr_cs_conn_worker:get_connection() of
        undefined ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            lager:error("failed to get connection sleeping ~wms", [Delay]),
            timer:sleep(Delay),
            {noreply, State#state{conn_backoff = Backoff1}, {continue, ?CONNECT}};
        Connection ->
            #{http_connection := Pid} = Connection,
            _Ref = erlang:monitor(process, Pid, [{tag, {'DOWN', ?MODULE}}]),
            lager:info("connected"),
            {_, Backoff1} = backoff:succeed(Backoff0),
            {noreply, State#state{connection = Connection, conn_backoff = Backoff1},
                {continue, ?INIT_STREAM}}
    end;
handle_continue(
    ?INIT_STREAM,
    #state{
        connection = Connection
    } = State
) ->
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
    {noreply, State#state{stream = Stream}, {continue, ?RCV_CFG_UPDATE}};
handle_continue(
    ?RCV_CFG_UPDATE,
    #state{
        connection = Connection, stream = Stream, conn_backoff = Backoff0
    } = State
) ->
    case grpc_client:rcv(Stream, ?RCV_TIMEOUT) of
        {headers, _Headers} ->
            {noreply, State, {continue, ?RCV_CFG_UPDATE}};
        {data, SKFStreamRes} ->
            ok = process_res(hpr_skf_stream_res:from_map(SKFStreamRes)),
            lager:info("got sfk update"),
            {noreply, State, {continue, ?RCV_CFG_UPDATE}};
        eof ->
            lager:warning("got eof"),
            _ = catch grpc_client:stop_connection(Connection),
            {noreply, State, {continue, ?CONNECT}};
        {error, timeout} ->
            lager:debug("rcv timeout"),
            {_, Backoff1} = backoff:succeed(Backoff0),
            {noreply, State#state{conn_backoff = Backoff1}, {continue, ?RCV_CFG_UPDATE}};
        {error, E} ->
            lager:error("failed to rcv ~p", [E]),
            {stop, {error, E}}
    end.

handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

handle_info({{'DOWN', ?MODULE}, _Mon, process, _Pid, _ExitReason}, State) ->
    lager:info("connection ~p went down ~p", [_Pid, _ExitReason]),
    self() ! ?CONNECT,
    {noreply, State#state{connection = undefined}, {continue, ?CONNECT}};
handle_info(_Msg, State) ->
    lager:warning("unimplemented_info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, #state{connection = Connection}) ->
    lager:error("terminate ~p", [_Reason]),
    _ = catch grpc_client:stop_connection(Connection),
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
