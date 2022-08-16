%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 08. Aug 2022 3:24 PM
%%%-------------------------------------------------------------------
-module(hpr_gwmp_client).
-author("jonathanruttenberg").

-behaviour(gen_server).

-include("../../grpc/autogen/server/packet_router_pb.hrl").

-include("semtech_udp.hrl").

%% API
-export([start_link/1, push_data/4, handle_hpr_packet_up_data/4]).

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
    %% ok = udp_worker_utils:update_address(WorkerPid, Protocol),
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

    #{pubkeybin := PubKeyBin, protocol := Protocol} = Args,

    PullDataTimer = maps:get(pull_data_timer, Args, ?PULL_DATA_TIMER),

    lager:md([
        {gateway_mac, udp_worker_utils:pubkeybin_to_mac(PubKeyBin)},
        {pubkey, libp2p_crypto:bin_to_b58(PubKeyBin)}
    ]),

    {ok, Socket} = gwmp_udp_socket:open(Protocol, undefined),

    %% Pull data immediately so we can establish a connection for the first
    %% pull_response.
    self() ! ?PULL_DATA_TICK,
    udp_worker_utils:schedule_pull_data(PullDataTimer),

    ShutdownTimeout = maps:get(shutdown_timer, Args, ?SHUTDOWN_TIMER),
    ShutdownRef = udp_worker_utils:schedule_shutdown(ShutdownTimeout),

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
    Socket1 = udp_worker_utils:update_address(Socket0, Address, Port),
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
    {Reply, TimerRef} = udp_worker_utils:send_push_data(Token, Payload, Socket1),
    {NewPushData, NewShutdownTimer} = udp_worker_utils:new_push_and_shutdown(
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
    {ok, RefAndToken} = udp_worker_utils:send_pull_data(#{
        pubkeybin => PubKeyBin,
        socket => Socket,
        pull_data_timer => PullDataTimer
    }),

    {noreply, State#hpr_gwmp_worker_state{pull_data = RefAndToken}};
handle_info(
    ?PULL_DATA_TIMEOUT_TICK,
    #hpr_gwmp_worker_state{pull_data_timer = PullDataTimer} = State
) ->
    udp_worker_utils:handle_pull_data_timeout(PullDataTimer, <<"todo">>, ?METRICS_PREFIX),
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
    udp_worker_utils:handle_push_data(PushDataMap, Location, PacketTime).

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
        pull_data = PullDataMap,
        socket = Socket,
        pull_resp_fun = PullRespFunction,
        pubkeybin = PubKeyBin
    } = State
) ->
    ID = todo,
    StateUpdates =
        udp_worker_utils:handle_udp(
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
