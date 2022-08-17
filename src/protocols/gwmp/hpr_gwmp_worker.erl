%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
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
-export([start_link/1, push_data/4, handle_hpr_packet_up_data/4, pubkeybin_to_mac/1]).

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

-define(METRICS_PREFIX, "helium_packet_router_").

-record(hpr_gwmp_worker_state, {
    location :: no_location | {pos_integer(), float(), float()} | undefined,
    pubkeybin :: libp2p_crypto:pubkey_bin(),
    socket :: gwmp_udp_socket:socket(),
    push_data = #{} :: #{binary() => {binary(), reference()}},
    response_handler_pid :: undefined | pid(),
    pull_resp_fun :: undefined | function(),
    pull_data :: {reference(), binary()} | undefined,
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
    Protocol :: {string(), integer()}
) -> ok | {error, any()}.
push_data(WorkerPid, Data, HandlerPid, Protocol) ->
    gen_server:call(WorkerPid, {push_data, Data, HandlerPid, Protocol}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec init(Args :: term()) ->
    {ok, State :: #hpr_gwmp_worker_state{}}
    | {ok, State :: #hpr_gwmp_worker_state{}, timeout() | hibernate}
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

    {ok, Socket} = gwmp_udp_socket:open(Protocol, undefined),

    %% Pull data immediately so we can establish a connection for the first
    %% pull_response.
    self() ! ?PULL_DATA_TICK,
    schedule_pull_data(PullDataTimer),

    ShutdownTimeout = maps:get(shutdown_timer, Args, ?SHUTDOWN_TIMER),
    ShutdownRef = schedule_shutdown(ShutdownTimeout),

    {ok, #hpr_gwmp_worker_state{
        pubkeybin = PubKeyBin,
        socket = Socket,
        pull_data_timer = PullDataTimer,
        shutdown_timer = {ShutdownTimeout, ShutdownRef},
        location = no_location
    }}.

%% @private
%% @doc Handling call messages
-spec handle_call(
    Request :: term(),
    From :: {pid(), Tag :: term()},
    State :: #hpr_gwmp_worker_state{}
) ->
    {reply, Reply :: term(), NewState :: #hpr_gwmp_worker_state{}}
    | {reply, Reply :: term(), NewState :: #hpr_gwmp_worker_state{}, timeout() | hibernate}
    | {noreply, NewState :: #hpr_gwmp_worker_state{}}
    | {noreply, NewState :: #hpr_gwmp_worker_state{}, timeout() | hibernate}
    | {stop, Reason :: term(), Reply :: term(), NewState :: #hpr_gwmp_worker_state{}}
    | {stop, Reason :: term(), NewState :: #hpr_gwmp_worker_state{}}.
handle_call(
    {update_address, Address, Port},
    _From,
    #hpr_gwmp_worker_state{socket = Socket0} = State
) ->
    Socket1 = update_address(Socket0, Address, Port),
    {reply, ok, State#hpr_gwmp_worker_state{socket = Socket1}};
handle_call(
    {push_data, _Data = {Token, Payload}, StreamHandler, Protocol},
    _From,
    #hpr_gwmp_worker_state{
        push_data = PushData,
        shutdown_timer = {ShutdownTimeout, ShutdownRef},
        socket = Socket0
    } =
        State
) ->
    _ = erlang:cancel_timer(ShutdownRef),

    {ok, Socket1} = gwmp_udp_socket:update_address(Socket0, Protocol),
    {Reply, TimerRef} = send_push_data(Token, Payload, Socket1),
    {NewPushData, NewShutdownTimer} = new_push_and_shutdown(
        Token, Payload, TimerRef, PushData, ShutdownTimeout
    ),

    {reply, Reply, State#hpr_gwmp_worker_state{
        socket = Socket1,
        push_data = NewPushData,
        response_handler_pid = StreamHandler,
        pull_resp_fun = hpr_gwmp_send_response_function(StreamHandler),
        shutdown_timer = NewShutdownTimer
    }};
handle_call(Request, From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [Request, From]),
    {reply, ok, State}.

%% @private
%% @doc Handling cast messages
-spec handle_cast(Request :: term(), State :: #hpr_gwmp_worker_state{}) ->
    {noreply, NewState :: #hpr_gwmp_worker_state{}}
    | {noreply, NewState :: #hpr_gwmp_worker_state{}, timeout() | hibernate}
    | {stop, Reason :: term(), NewState :: #hpr_gwmp_worker_state{}}.
handle_cast(Request, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [Request]),
    {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec handle_info(Info :: timeout() | term(), State :: #hpr_gwmp_worker_state{}) ->
    {noreply, NewState :: #hpr_gwmp_worker_state{}}
    | {noreply, NewState :: #hpr_gwmp_worker_state{}, timeout() | hibernate}
    | {stop, Reason :: term(), NewState :: #hpr_gwmp_worker_state{}}.
handle_info(
    {udp, Socket, _Address, _Port, Data},
    #hpr_gwmp_worker_state{
        socket = {socket, Socket, _}
    } = State
) ->
    try handle_udp(Data, State) of
        {noreply, _} = NoReply -> NoReply
    catch
        _E:_R ->
            lager:error("failed to handle UDP packet ~p: ~p/~p", [Data, _E, _R]),
            {noreply, State}
    end;
handle_info(
    {?PUSH_DATA_TICK, Token},
    #hpr_gwmp_worker_state{push_data = PushData} = State
) ->
    case maps:get(Token, PushData, undefined) of
        undefined ->
            {noreply, State};
        {_Data, _} ->
            lager:debug("got push data timeout ~p, ignoring lack of ack", [Token]),
            ok = gwmp_metrics:push_ack_missed(?METRICS_PREFIX, <<"todo">>),
            {noreply, State#hpr_gwmp_worker_state{push_data = maps:remove(Token, PushData)}}
    end;
handle_info(
    ?PULL_DATA_TICK,
    #hpr_gwmp_worker_state{
        pubkeybin = PubKeyBin,
        socket = Socket,
        pull_data_timer = PullDataTimer
    } =
        State
) ->
    {ok, RefAndToken} = send_pull_data(#{
        pubkeybin => PubKeyBin,
        socket => Socket,
        pull_data_timer => PullDataTimer
    }),

    {noreply, State#hpr_gwmp_worker_state{pull_data = RefAndToken}};
handle_info(
    ?PULL_DATA_TIMEOUT_TICK,
    #hpr_gwmp_worker_state{pull_data_timer = PullDataTimer} = State
) ->
    handle_pull_data_timeout(PullDataTimer, <<"todo">>, ?METRICS_PREFIX),
    {noreply, State};
handle_info(?SHUTDOWN_TICK, #hpr_gwmp_worker_state{shutdown_timer = {ShutdownTimeout, _}} = State) ->
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
    State :: #hpr_gwmp_worker_state{}
) -> term().
terminate(_Reason, _State = #hpr_gwmp_worker_state{socket = Socket}) ->
    ok = gwmp_udp_socket:close(Socket).

%% @private
%% @doc Convert process state when code is changed
-spec code_change(
    OldVsn :: term() | {down, term()},
    State :: #hpr_gwmp_worker_state{},
    Extra :: term()
) ->
    {ok, NewState :: #hpr_gwmp_worker_state{}} | {error, Reason :: term()}.
code_change(_OldVsn, State = #hpr_gwmp_worker_state{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec handle_hpr_packet_up_data(
    HPRPacketUp :: hpr_packet_up:packet(),
    PacketTime :: pos_integer(),
    Location :: {pos_integer(), float(), float()} | no_location | undefined,
    PubKeyBin :: libp2p_crypto:pubkey_bin()
) -> {binary(), binary()}.

handle_hpr_packet_up_data(HPRPacketUp, PacketTime, Location, PubKeyBin) ->
    PushDataMap = values_for_push_from(HPRPacketUp, PubKeyBin),
    handle_push_data(PushDataMap, Location, PacketTime).

values_for_push_from(
    #packet_router_packet_up_v1_pb{} = HPRPacketUp,
    PubKeyBin
) ->
    Payload = hpr_packet_up:payload(HPRPacketUp),
    MAC = hpr_packet_up:hotspot(HPRPacketUp),
    Region = hpr_packet_up:region(HPRPacketUp),
    Tmst = hpr_packet_up:timestamp(HPRPacketUp),
    Frequency = hpr_packet_up:frequency(HPRPacketUp),
    Datarate = hpr_packet_up:datarate(HPRPacketUp),
    SignalStrength = hpr_packet_up:signal_strength(HPRPacketUp),
    Snr = hpr_packet_up:snr(HPRPacketUp),
    #{
        region => Region,
        tmst => Tmst,
        payload => Payload,
        frequency => Frequency,
        datarate => Datarate,
        signal_strength => SignalStrength,
        snr => Snr,
        mac => MAC,
        pub_key_bin => PubKeyBin
    }.

hpr_gwmp_send_response_function(Handler) ->
    fun(Data) ->
        PacketDown = hpr_hotspot_service:txpk_to_packet_down(Data),
        grpcbox_stream:send(false, PacketDown, Handler),
        lager:info("hpr_gwmp_send_response: Data: ~p, Handler: ~p", [Data, Handler])
    end.

update_state(StateUpdates, InitialState) ->
    Fun = fun(Key, Value, State) ->
        case Key of
            push_data -> State#hpr_gwmp_worker_state{push_data = Value};
            pull_data -> State#hpr_gwmp_worker_state{pull_data = Value};
            _ -> State
        end
    end,
    maps:fold(Fun, InitialState, StateUpdates).

-spec handle_udp(binary(), #hpr_gwmp_worker_state{}) -> {noreply, #hpr_gwmp_worker_state{}}.
handle_udp(
    Data,
    #hpr_gwmp_worker_state{
        push_data = PushData,
        pull_data_timer = PullDataTimer,
        pull_data = PullData,
        socket = Socket,
        pull_resp_fun = PullRespFunction,
        pubkeybin = PubKeyBin
    } = State
) ->
    ID = todo,
    StateUpdates =
        handle_udp(
            Data,
            PushData,
            ID,
            PullData,
            PullDataTimer,
            PubKeyBin,
            Socket,
            PullRespFunction,
            ?METRICS_PREFIX
        ),
    {noreply, update_state(StateUpdates, State)}.

-spec pubkeybin_to_mac(binary()) -> binary().
pubkeybin_to_mac(PubKeyBin) ->
    <<(xxhash:hash64(PubKeyBin)):64/unsigned-integer>>.

-spec schedule_pull_data(non_neg_integer()) -> reference().
schedule_pull_data(PullDataTimer) ->
    _ = erlang:send_after(PullDataTimer, self(), ?PULL_DATA_TICK).

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
    pull_data_timer := non_neg_integer()
}) -> {ok, {reference(), binary()}} | {error, any()}.
send_pull_data(
    #{
        pubkeybin := PubKeyBin,
        socket := Socket,
        pull_data_timer := PullDataTimer
    }
) ->
    Token = semtech_udp:token(),
    Data = semtech_udp:pull_data(Token, pubkeybin_to_mac(PubKeyBin)),
    case gwmp_udp_socket:send(Socket, Data) of
        ok ->
            lager:debug("sent pull data keepalive ~p", [Token]),
            TimerRef = erlang:send_after(PullDataTimer, self(), ?PULL_DATA_TIMEOUT_TICK),
            {ok, {TimerRef, Token}};
        Error ->
            lager:warning("failed to send pull data keepalive ~p: ~p", [Token, Error]),
            Error
    end.

handle_pull_data_timeout(PullDataTimer, NetID, MetricsPrefix) ->
    lager:debug("got a pull data timeout, ignoring missed pull_ack [retry: ~p]", [PullDataTimer]),
    ok = gwmp_metrics:pull_ack_missed(MetricsPrefix, NetID),
    _ = schedule_pull_data(PullDataTimer).

handle_push_data(PushDataMap, Location, PacketTime) ->
    #{
        pub_key_bin := PubKeyBin,
        mac := MAC,
        region := Region,
        tmst := Tmst,
        payload := Payload,
        frequency := Frequency,
        datarate := Datarate,
        signal_strength := SignalStrength,
        snr := Snr
    } = PushDataMap,

    Token = semtech_udp:token(),
    {Index, Lat, Long} =
        case Location of
            undefined -> {undefined, undefined, undefined};
            no_location -> {undefined, undefined, undefined};
            {_, _, _} = L -> L
        end,

    Data = semtech_udp:push_data(
        Token,
        MAC,
        #{
            time => iso8601:format(
                calendar:system_time_to_universal_time(PacketTime, millisecond)
            ),
            tmst => Tmst band 16#FFFFFFFF,
            freq => Frequency,
            rfch => 0,
            modu => <<"LORA">>,
            codr => <<"4/5">>,
            stat => 1,
            chan => 0,
            datr => erlang:list_to_binary(Datarate),
            rssi => erlang:trunc(SignalStrength),
            lsnr => Snr,
            size => erlang:byte_size(Payload),
            data => base64:encode(Payload)
        },
        #{
            regi => Region,
            inde => Index,
            lati => Lat,
            long => Long,
            pubk => libp2p_crypto:bin_to_b58(PubKeyBin)
        }
    ),
    {Token, Data}.

handle_udp(
    Data,
    PushData,
    ID,
    PullData,
    PullDataTimer,
    PubKeyBin,
    Socket,
    PullRespFunction,
    MetricsPrefix
) ->
    Identifier = semtech_udp:identifier(Data),
    lager:debug("got udp ~p / ~p", [semtech_udp:identifier_to_atom(Identifier), Data]),
    StateUpdates =
        case semtech_udp:identifier(Data) of
            ?PUSH_ACK ->
                handle_push_ack(Data, PushData, ID, MetricsPrefix);
            ?PULL_ACK ->
                handle_pull_ack(Data, PullData, PullDataTimer, ID, MetricsPrefix);
            ?PULL_RESP ->
                handle_pull_resp(Data, PubKeyBin, Socket, PullRespFunction);
            _Id ->
                lager:warning("got unknown identifier ~p for ~p", [_Id, Data]),
                #{}
        end,
    StateUpdates.

handle_push_ack(Data, PushData, NetID, MetricsPrefix) ->
    Token = semtech_udp:token(Data),
    case maps:get(Token, PushData, undefined) of
        undefined ->
            lager:debug("got unknown push ack ~p", [Token]),
            #{push_data => PushData};
        {_, TimerRef} ->
            lager:debug("got push ack ~p", [Token]),
            _ = erlang:cancel_timer(TimerRef),
            ok = gwmp_metrics:push_ack(MetricsPrefix, NetID),
            NewPushData = maps:remove(Token, PushData),
            #{push_data => NewPushData}
    end.

-spec handle_pull_ack(
    binary(),
    {reference(), binary()} | undefined,
    non_neg_integer(),
    non_neg_integer(),
    string()
) -> map().
handle_pull_ack(Data, undefined, _PullDataTimer, _NetID, _MetricsPrefix) ->
    lager:warning("got unknown pull ack for ~p", [Data]),
    #{};
handle_pull_ack(Data, {PullDataRef, PullDataToken}, PullDataTimer, NetID, MetricsPrefix) ->
    NewPullData =
        handle_pull_ack(Data, PullDataToken, PullDataRef, PullDataTimer, NetID, MetricsPrefix),
    case NewPullData of
        undefined -> #{pull_data => NewPullData};
        _ -> #{pull_data => {PullDataRef, PullDataToken}}
    end.

handle_pull_ack(Data, PullDataToken, PullDataRef, PullDataTimer, NetID, MetricsPrefix) ->
    case semtech_udp:token(Data) of
        PullDataToken ->
            erlang:cancel_timer(PullDataRef),
            lager:debug("got pull ack for ~p", [PullDataToken]),
            _ = schedule_pull_data(PullDataTimer),
            ok = gwmp_metrics:pull_ack(MetricsPrefix, NetID),
            undefined;
        _UnknownToken ->
            lager:warning("got unknown pull ack for ~p", [_UnknownToken]),
            ignore
    end.

-spec handle_pull_resp(binary(), libp2p_crypto:pubkey_bin(), gwmp_udp_socket:socket(), function()) ->
    any().
handle_pull_resp(Data, PubKeyBin, Socket, PullRespFunction) ->
    _ = PullRespFunction(Data),
    handle_pull_response(Data, PubKeyBin, Socket),
    StateUpdates = #{},
    StateUpdates.

handle_pull_response(Data, PubKeyBin, Socket) ->
    Token = semtech_udp:token(Data),
    send_tx_ack(Token, #{pubkeybin => PubKeyBin, socket => Socket}).

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
