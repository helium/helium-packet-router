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

-include_lib("router_utils/include/semtech_udp.hrl").

%% API
-export([start_link/0, push_data/4]).

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

-record(packet_router_packet_up_v1_pb,
    % = 1, optional
    {
        payload = <<>> :: iodata() | undefined,
        % = 2, optional, 64 bits
        timestamp = 0 :: non_neg_integer() | undefined,
        % = 3, optional
        signal_strength = 0.0 :: float() | integer() | infinity | '-infinity' | nan | undefined,
        % = 4, optional
        frequency = 0.0 :: float() | integer() | infinity | '-infinity' | nan | undefined,
        % = 5, optional
        datarate = [] :: unicode:chardata() | undefined,
        % = 6, optional
        snr = 0.0 :: float() | integer() | infinity | '-infinity' | nan | undefined,
        % = 7, optional, enum region
        region = 'US915' ::
            'US915'
            | 'EU868'
            | 'EU433'
            | 'CN470'
            | 'CN779'
            | 'AU915'
            | 'AS923_1'
            | 'KR920'
            | 'IN865'
            | 'AS923_2'
            | 'AS923_3'
            | 'AS923_4'
            | 'AS923_1B'
            | 'CD900_1A'
            | integer()
            | undefined,
        % = 8, optional, 64 bits
        hold_time = 0 :: non_neg_integer() | undefined,
        % = 9, optional
        hotspot = <<>> :: iodata() | undefined,
        % = 10, optional
        signature = <<>> :: iodata() | undefined
    }
).

-record(hpr_gwmp_client_state, {
    location :: no_location | {pos_integer(), float(), float()} | undefined,
    pubkeybin :: libp2p_crypto:pubkey_bin(),
    socket :: pp_udp_socket:socket(),
    push_data = #{} :: #{binary() => {binary(), reference()}},
    pull_data :: {reference(), binary()} | undefined,
    pull_data_timer :: non_neg_integer(),
    shutdown_timer :: {Timeout :: non_neg_integer(), Timer :: reference()}
}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Spawns the server and registers the local name (unique)
-spec start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec push_data(
    WorkerPid :: pid(),
    HPRPacketUp :: #packet_router_packet_up_v1_pb{},
    PacketTime :: pos_integer(),
    Protocol :: {udp, string(), integer()}
) -> ok | {error, any()}.

push_data(WorkerPid, HPRPacketUp, PacketTime, Protocol) ->
    ok = udp_worker_utils:update_address(WorkerPid, Protocol),
    gen_server:call(WorkerPid, {push_data, HPRPacketUp, PacketTime}).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec init(Args :: term()) ->
    {ok, State :: #hpr_gwmp_client_state{}}
    | {ok, State :: #hpr_gwmp_client_state{}, timeout() | hibernate}
    | {stop, Reason :: term()}
    | ignore.
init(Args) ->
    _Packet = #packet_router_packet_up_v1_pb{},

    process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),

    PubKeyBin = maps:get(pubkeybin, Args),
    Address = maps:get(address, Args),
    PullDataTimer = maps:get(pull_data_timer, Args, ?PULL_DATA_TIMER),

    lager:md([
        {gateway_mac, udp_worker_utils:pubkeybin_to_mac(PubKeyBin)},
        {address, Address}]),

    Port = maps:get(port, Args),
    {ok, Socket} = pp_udp_socket:open({Address, Port}, undefined),

    %% Pull data immediately so we can establish a connection for the first
    %% pull_response.
    self() ! ?PULL_DATA_TICK,
    udp_worker_utils:schedule_pull_data(PullDataTimer),

    ShutdownTimeout = maps:get(shutdown_timer, Args, ?SHUTDOWN_TIMER),
    ShutdownRef = udp_worker_utils:schedule_shutdown(ShutdownTimeout),

    {ok, #hpr_gwmp_client_state{
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
    State :: #hpr_gwmp_client_state{}
) ->
    {reply, Reply :: term(), NewState :: #hpr_gwmp_client_state{}}
    | {reply, Reply :: term(), NewState :: #hpr_gwmp_client_state{}, timeout() | hibernate}
    | {noreply, NewState :: #hpr_gwmp_client_state{}}
    | {noreply, NewState :: #hpr_gwmp_client_state{}, timeout() | hibernate}
    | {stop, Reason :: term(), Reply :: term(), NewState :: #hpr_gwmp_client_state{}}
    | {stop, Reason :: term(), NewState :: #hpr_gwmp_client_state{}}.
handle_call(
    {update_address, Address, Port},
    _From,
    #hpr_gwmp_client_state{socket = Socket0} = State
) ->
    Socket1 = udp_worker_utils:update_address(Socket0, Address, Port),
    {reply, ok, State#hpr_gwmp_client_state{socket = Socket1}};
handle_call(
    {push_data, HPRPacketUp, PacketTime},
    _From,
    #hpr_gwmp_client_state{
        push_data = PushData,
        location = Loc,
        shutdown_timer = {ShutdownTimeout, ShutdownRef},
        socket = Socket,
        pubkeybin = PubKeyBin} =
        State
) ->
    _ = erlang:cancel_timer(ShutdownRef),
    {Token, Data} = handle_hpr_packet_up_data(HPRPacketUp, PacketTime, Loc, PubKeyBin),

    {Reply, TimerRef} = udp_worker_utils:send_push_data(Token, Data, Socket),
    {NewPushData, NewShutdownTimer} = udp_worker_utils:new_push_and_shutdown(Token, Data, TimerRef, PushData, ShutdownTimeout),

    {reply, Reply, State#hpr_gwmp_client_state{
        push_data = NewPushData,
        shutdown_timer = NewShutdownTimer
    }};
handle_call(Request, From, State)->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [Request, From]),
    {reply, ok, State}.

%% @private
%% @doc Handling cast messages
-spec handle_cast(Request :: term(), State :: #hpr_gwmp_client_state{}) ->
    {noreply, NewState :: #hpr_gwmp_client_state{}}
    | {noreply, NewState :: #hpr_gwmp_client_state{}, timeout() | hibernate}
    | {stop, Reason :: term(), NewState :: #hpr_gwmp_client_state{}}.
handle_cast(Request, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [Request]),
    {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec handle_info(Info :: timeout() | term(), State :: #hpr_gwmp_client_state{}) ->
    {noreply, NewState :: #hpr_gwmp_client_state{}}
    | {noreply, NewState :: #hpr_gwmp_client_state{}, timeout() | hibernate}
    | {stop, Reason :: term(), NewState :: #hpr_gwmp_client_state{}}.
handle_info(_Info, State = #hpr_gwmp_client_state{}) ->
    {noreply, State}.

%% @private
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec terminate(
    Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #hpr_gwmp_client_state{}
) -> term().
terminate(_Reason, _State = #hpr_gwmp_client_state{}) ->
    ok.

%% @private
%% @doc Convert process state when code is changed
-spec code_change(
    OldVsn :: term() | {down, term()},
    State :: #hpr_gwmp_client_state{},
    Extra :: term()
) ->
    {ok, NewState :: #hpr_gwmp_client_state{}} | {error, Reason :: term()}.
code_change(_OldVsn, State = #hpr_gwmp_client_state{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec handle_hpr_packet_up_data(
    HPRPacketUp :: #packet_router_packet_up_v1_pb{},
    PacketTime :: pos_integer(),
    Location :: {pos_integer(), float(), float()} | no_location | undefined,
    PubKeyBin :: libp2p_crypto:pubkey_bin()
) -> {binary(), binary()}.
handle_hpr_packet_up_data(HPRPacketUp, PacketTime, Location, PubKeyBin) ->
    PushDataMap = values_for_push_from(HPRPacketUp, PubKeyBin),
    udp_worker_utils:handle_push_data(PushDataMap, Location, PacketTime).

values_for_push_from(#packet_router_packet_up_v1_pb{
    payload = Payload,
    hotspot = MAC,
    region = Region,
    timestamp = Tmst,
    frequency = Frequency,
    datarate = Datarate,
    signal_strength = SignalStrength,
    snr = Snr} = _HPRPacketUp, PubKeyBin) ->
    #{
        region => Region,
        tmst => Tmst,
        payload => Payload,
        frequency => Frequency,
        datarate => Datarate,
        signal_strength => SignalStrength,
        snr => Snr,
        mac => MAC,
        pub_key_bin => PubKeyBin}.

