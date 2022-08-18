%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs Inc.
%%% @doc
%%%
%%% @end
%%% Created : 08. Aug 2022 3:24 PM
%%%-------------------------------------------------------------------
-module(hpr_gwmp_worker).
-author("jonathanruttenberg").

-behaviour(gen_server).

-include("../../grpc/autogen/server/packet_router_pb.hrl").

-include("semtech_udp.hrl").

%% API
-export([
    start_link/1,
    push_data/4,
    pubkeybin_to_mac/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

-type pull_data_map() :: #{
    gwmp_udp_socket:socket_dest() => #{timer_ref := reference(), token := binary()}
}.

-record(state, {
    pubkeybin :: libp2p_crypto:pubkey_bin(),
    socket :: gwmp_udp_socket:socket(),
    push_data = #{} :: #{binary() => {binary(), reference()}},
    response_stream :: undefined | tuple(),
    pull_data = #{} :: pull_data_map(),
    pull_data_timer :: non_neg_integer(),
    shutdown_timer :: {Timeout :: non_neg_integer(), Timer :: reference()}
}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Spawns the server and registers the local name (unique)
-spec start_link(Args :: map()) ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).

-spec push_data(
    WorkerPid :: pid(),
    Data :: {Token :: binary(), Payload :: binary()},
    HandlerPid :: pid(),
    SocketDest :: gwmp_udp_socket:socket_dest()
) -> ok | {error, any()}.
push_data(WorkerPid, Data, HandlerPid, SocketDest) ->
    gen_server:call(WorkerPid, {push_data, Data, HandlerPid, SocketDest}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec init(Args :: term()) ->
    {ok, State :: #state{}}
    | {ok, State :: #state{}, timeout() | hibernate}
    | {stop, Reason :: term()}
    | ignore.
init(Args) ->
    process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),

    #{pubkeybin := PubKeyBin, socket_dest := SocketDest} = Args,

    PullDataTimer = maps:get(pull_data_timer, Args, ?PULL_DATA_TIMER),

    lager:md([
        {gateway_mac, pubkeybin_to_mac(PubKeyBin)},
        {pubkey, libp2p_crypto:bin_to_b58(PubKeyBin)}
    ]),

    {ok, Socket} = gwmp_udp_socket:open(SocketDest, undefined),

    %% NOTE: Pull data is sent at the first push_data to
    %% initiate the connection and allow downlinks to start
    %% flowing.

    ShutdownTimeout = maps:get(shutdown_timer, Args, ?SHUTDOWN_TIMER),
    ShutdownRef = schedule_shutdown(ShutdownTimeout),

    {ok, #state{
        pubkeybin = PubKeyBin,
        socket = Socket,
        pull_data_timer = PullDataTimer,
        shutdown_timer = {ShutdownTimeout, ShutdownRef}
    }}.

%% @private
%% @doc Handling call messages
-spec handle_call(
    Request :: term(),
    From :: {pid(), Tag :: term()},
    State :: #state{}
) ->
    {reply, Reply :: term(), NewState :: #state{}}
    | {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate}
    | {noreply, NewState :: #state{}}
    | {noreply, NewState :: #state{}, timeout() | hibernate}
    | {stop, Reason :: term(), Reply :: term(), NewState :: #state{}}
    | {stop, Reason :: term(), NewState :: #state{}}.
handle_call(
    {update_address, Address, Port},
    _From,
    #state{socket = Socket0} = State
) ->
    Socket1 = update_address(Socket0, Address, Port),
    {reply, ok, State#state{socket = Socket1}};
handle_call(
    {push_data, _Data = {Token, Payload}, StreamHandler, SocketDest},
    _From,
    #state{
        push_data = PushData,
        shutdown_timer = {ShutdownTimeout, ShutdownRef},
        socket = Socket0
    } =
        State0
) ->
    _ = erlang:cancel_timer(ShutdownRef),

    State = maybe_send_pull_data(SocketDest, State0),

    {ok, Socket1} = gwmp_udp_socket:update_address(Socket0, SocketDest),
    {Reply, TimerRef} = send_push_data(Token, Payload, Socket1),
    {NewPushData, NewShutdownTimer} = new_push_and_shutdown(
        Token, Payload, TimerRef, PushData, ShutdownTimeout
    ),

    {reply, Reply, State#state{
        socket = Socket1,
        push_data = NewPushData,
        response_stream = StreamHandler,
        shutdown_timer = NewShutdownTimer
    }};
handle_call(Request, From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [Request, From]),
    {reply, ok, State}.

%% @private
%% @doc Handling cast messages
-spec handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}}
    | {noreply, NewState :: #state{}, timeout() | hibernate}
    | {stop, Reason :: term(), NewState :: #state{}}.
handle_cast(Request, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [Request]),
    {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}}
    | {noreply, NewState :: #state{}, timeout() | hibernate}
    | {stop, Reason :: term(), NewState :: #state{}}.
handle_info(
    {udp, Socket, Address, Port, Data},
    #state{
        socket = {socket, Socket, _}
    } = State
) ->
    try handle_udp(Data, {Address, Port}, State) of
        {noreply, _} = NoReply -> NoReply
    catch
        _E:_R ->
            lager:error("failed to handle UDP packet ~p: ~p/~p", [Data, _E, _R]),
            {noreply, State}
    end;
handle_info(
    {?PUSH_DATA_TICK, Token},
    #state{push_data = PushData} = State
) ->
    case maps:get(Token, PushData, undefined) of
        undefined ->
            {noreply, State};
        {_Data, _} ->
            lager:debug("got push data timeout ~p, ignoring lack of ack", [Token]),
            {noreply, State#state{push_data = maps:remove(Token, PushData)}}
    end;
handle_info(
    {?PULL_DATA_TICK, SocketDest},
    #state{
        pubkeybin = PubKeyBin,
        socket = Socket,
        pull_data_timer = PullDataTimer,
        pull_data = PullDataMap0
    } =
        State
) ->
    case
        send_pull_data(#{
            pubkeybin => PubKeyBin,
            socket => Socket,
            dest => SocketDest,
            pull_data_timer => PullDataTimer
        })
    of
        {ok, RefAndToken} ->
            PullDataMap1 = maps:put(SocketDest, RefAndToken, PullDataMap0),
            {noreply, State#state{pull_data = PullDataMap1}};
        {error, Reason} ->
            lager:warning(
                [{error, Reason}, {lns, SocketDest}],
                "could not send pull_data"
            ),
            {noreply, State}
    end;
handle_info(
    {?PULL_DATA_TIMEOUT_TICK, SocketDest},
    #state{pull_data_timer = PullDataTimer} = State
) ->
    handle_pull_data_timeout(PullDataTimer, SocketDest),
    {noreply, State};
handle_info(?SHUTDOWN_TICK, #state{shutdown_timer = {ShutdownTimeout, _}} = State) ->
    lager:info("shutting down, haven't sent data in ~p", [ShutdownTimeout]),
    {stop, normal, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

%% @private
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec terminate(
    Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}
) -> term().
terminate(_Reason, _State = #state{socket = Socket}) ->
    ok = gwmp_udp_socket:close(Socket).

%% @private
%% @doc Convert process state when code is changed
-spec code_change(
    OldVsn :: term() | {down, term()},
    State :: #state{},
    Extra :: term()
) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}.
code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec handle_udp(
    Data :: binary(),
    DataSrc :: gwmp_udp_socket:socket_dest(),
    State :: #state{}
) -> {noreply, #state{}}.
handle_udp(
    Data,
    DataSrc,
    #state{
        push_data = PushData0,
        pull_data_timer = PullDataTimer,
        pull_data = PullDataMap0,
        socket = Socket,
        response_stream = StreamHandler,
        pubkeybin = PubKeyBin
    } = State0
) ->
    State1 =
        case semtech_udp:identifier(Data) of
            ?PUSH_ACK ->
                PushData1 = handle_push_ack(Data, PushData0),
                State0#state{push_data = PushData1};
            ?PULL_ACK ->
                PullDataMap1 = handle_pull_ack(Data, DataSrc, PullDataMap0, PullDataTimer),
                State0#state{pull_data = PullDataMap1};
            ?PULL_RESP ->
                %% FIXME: include data source for socket ack
                ok = handle_pull_resp(Data, DataSrc, PubKeyBin, Socket, StreamHandler),
                State0;
            _Id ->
                lager:warning("got unknown identifier ~p for ~p", [_Id, Data]),
                State0
        end,
    {noreply, State1}.

-spec pubkeybin_to_mac(binary()) -> binary().
pubkeybin_to_mac(PubKeyBin) ->
    <<(xxhash:hash64(PubKeyBin)):64/unsigned-integer>>.

-spec schedule_pull_data(non_neg_integer(), gwmp_udp_socket:socket_dest()) -> reference().
schedule_pull_data(PullDataTimer, SocketDest) ->
    _ = erlang:send_after(PullDataTimer, self(), {?PULL_DATA_TICK, SocketDest}).

-spec schedule_shutdown(non_neg_integer()) -> reference().
schedule_shutdown(ShutdownTimer) ->
    _ = erlang:send_after(ShutdownTimer, self(), ?SHUTDOWN_TICK).

update_address(Socket0, Address, Port) ->
    lager:debug("Updating address and port [old: ~p] [new: ~p]", [
        gwmp_udp_socket:get_address(Socket0),
        {Address, Port}
    ]),
    {ok, Socket1} = gwmp_udp_socket:update_address(Socket0, {Address, Port}),
    Socket1.

-spec send_push_data(binary(), binary(), gwmp_udp_socket:socket()) ->
    {ok | {error, any()}, reference()}.
send_push_data(
    Token,
    Data,
    Socket
) ->
    Reply = gwmp_udp_socket:send(Socket, Data),
    TimerRef = erlang:send_after(?PUSH_DATA_TIMER, self(), {?PUSH_DATA_TICK, Token}),
    lager:debug("sent ~p/~p to ~p replied: ~p", [
        Token,
        Data,
        gwmp_udp_socket:get_address(Socket),
        Reply
    ]),
    {Reply, TimerRef}.

new_push_and_shutdown(Token, Data, TimerRef, PushData, ShutdownTimeout) ->
    NewPushData = maps:put(Token, {Data, TimerRef}, PushData),
    NewShutdownTimer = {ShutdownTimeout, schedule_shutdown(ShutdownTimeout)},
    {NewPushData, NewShutdownTimer}.

-spec send_pull_data(#{
    pubkeybin := libp2p_crypto:pubkey_bin(),
    socket := gwmp_udp_socket:socket(),
    dest := gwmp_udp_socket:socket_dest(),
    pull_data_timer := non_neg_integer()
}) -> {ok, #{timer_ref := reference(), token := binary()}} | {error, any()}.
send_pull_data(
    #{
        pubkeybin := PubKeyBin,
        socket := Socket0,
        dest := SocketDest,
        pull_data_timer := PullDataTimer
    }
) ->
    {ok, Socket} = gwmp_udp_socket:update_address(Socket0, SocketDest),
    Token = semtech_udp:token(),
    Data = semtech_udp:pull_data(Token, pubkeybin_to_mac(PubKeyBin)),
    case gwmp_udp_socket:send(Socket, Data) of
        ok ->
            lager:debug("sent pull data keepalive ~p", [Token]),
            TimerRef = erlang:send_after(
                PullDataTimer, self(), {?PULL_DATA_TIMEOUT_TICK, SocketDest}
            ),
            {ok, #{timer_ref => TimerRef, token => Token}};
        Error ->
            lager:warning("failed to send pull data keepalive ~p: ~p", [Token, Error]),
            Error
    end.

handle_pull_data_timeout(PullDataTimer, SocketDest) ->
    lager:debug("got a pull data timeout, ignoring missed pull_ack [retry: ~p]", [PullDataTimer]),
    _ = schedule_pull_data(PullDataTimer, SocketDest).

handle_push_ack(Data, PushData) ->
    Token = semtech_udp:token(Data),
    case maps:get(Token, PushData, undefined) of
        undefined ->
            lager:debug("got unknown push ack ~p", [Token]),
            PushData;
        {_, TimerRef} ->
            lager:debug("got push ack ~p", [Token]),
            _ = erlang:cancel_timer(TimerRef),
            NewPushData = maps:remove(Token, PushData),
            NewPushData
    end.

-spec handle_pull_ack(
    Data :: binary(),
    DataSrc :: gwmp_udp_socket:socket_dest(),
    PullData :: pull_data_map(),
    PullDataTime :: non_neg_integer()
) -> pull_data_map().
handle_pull_ack(Data, DataSrc, PullDataMap, PullDataTimer) ->
    case {semtech_udp:token(Data), maps:get(DataSrc, PullDataMap, undefined)} of
        {Token, #{token := Token, timer_ref := TimerRef}} ->
            _ = erlang:cancel_timer(TimerRef),
            _ = schedule_pull_data(PullDataTimer, DataSrc),
            maps:remove(DataSrc, PullDataMap);
        {_, undefined} ->
            lager:warning("pull_ack for unknown source"),
            PullDataMap;
        _ ->
            lager:warning("pull_ack with unknown token"),
            PullDataMap
    end.

-spec handle_pull_resp(
    Data :: binary(),
    DataSrc :: gwmp_udp_socket:socket_dest(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Socket :: gwmp_udp_socket:socket(),
    StreamHandler :: tuple()
) ->
    ok.
handle_pull_resp(Data, DataSrc, PubKeyBin, Socket0, StreamHandler) ->
    %% Send downlink to grpc handler
    PacketDown = hpr_gwmp_router:txpk_to_packet_down(Data),
    grpcbox_stream:send(false, PacketDown, StreamHandler),

    %% Ack the downlink
    Token = semtech_udp:token(Data),
    {ok, Socket} = gwmp_udp_socket:update_address(Socket0, DataSrc),
    send_tx_ack(Token, #{pubkeybin => PubKeyBin, socket => Socket}),
    ok.

-spec send_tx_ack(
    binary(),
    #{
        pubkeybin := libp2p_crypto:pubkey_bin(),
        socket := gwmp_udp_socket:socket()
    }
) -> ok | {error, any()}.
send_tx_ack(
    Token,
    #{pubkeybin := PubKeyBin, socket := Socket}
) ->
    Data = semtech_udp:tx_ack(Token, pubkeybin_to_mac(PubKeyBin)),
    Reply = gwmp_udp_socket:send(Socket, Data),
    lager:debug("sent ~p/~p to ~p replied: ~p", [
        Token,
        Data,
        gwmp_udp_socket:get_address(Socket),
        Reply
    ]),
    Reply.

%%%-------------------------------------------------------------------
%% @doc
%% Only send a PULL_DATA if we haven't seen the destination
%% before. If we have, the lifecycle for sending PULL_DATA
%% is already being handled.
%% @end
%%%-------------------------------------------------------------------
-spec maybe_send_pull_data(
    SocketDest :: gwmp_udp_socket:socket_dest(),
    State :: #state{}
) -> #state{}.
maybe_send_pull_data(SocketDest, #state{pull_data = PullDataMap} = State) ->
    case maps:get(SocketDest, PullDataMap, undefined) of
        undefined ->
            #state{
                pubkeybin = PubKeyBin,
                socket = Socket,
                pull_data_timer = PullDataTimer
            } = State,
            case
                send_pull_data(#{
                    pubkeybin => PubKeyBin,
                    socket => Socket,
                    dest => SocketDest,
                    pull_data_timer => PullDataTimer
                })
            of
                {ok, RefAndToken} ->
                    State#state{
                        pull_data = maps:put(SocketDest, RefAndToken, PullDataMap)
                    };
                {error, Reason} ->
                    lager:warning(
                        [{error, Reason}, {lns, SocketDest}],
                        "could not send pull_data"
                    ),
                    State
            end;
        _ ->
            State
    end.
