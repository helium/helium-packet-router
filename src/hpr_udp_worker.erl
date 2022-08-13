-module(hpr_udp_worker).

-behavior(gen_server).

-include("./grpc/autogen/server/packet_router_pb.hrl").

-define(PUSH_ACK, 1).
-define(PULL_RESP, 3).
-define(PULL_ACK, 4).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    push_data/3
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

-define(PUSH_DATA_TICK, push_data_tick).
-define(PUSH_DATA_TIMER, timer:seconds(2)).

-define(PULL_DATA_TICK, pull_data_tick).
-define(PULL_DATA_TIMEOUT_TICK, pull_data_timeout_tick).
-define(PULL_DATA_TIMER, timer:seconds(10)).

-define(SHUTDOWN_TICK, shutdown_tick).
-define(SHUTDOWN_TIMER, timer:minutes(5)).

-record(state, {
    location :: undefined,
    pubkeybin :: libp2p_crypto:pubkey_bin(),

    socket :: pp_udp_socket:socket(),
    push_data = #{} :: #{binary() => {binary(), reference()}},

    handler_pid :: pid(),
    pull_data :: {reference(), binary()} | undefined,
    pull_data_timer :: non_neg_integer(),
    shutdown_timer :: {Timeout :: non_neg_integer(), Timer :: reference()}
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec push_data(
    SCPacket :: blockchain_state_channel_packet_v1:packet(),
    PacketTime :: pos_integer(),
    HandlerPid :: pid()
) -> ok | {error, any()}.
push_data(SCPacket, PacketTime, HandlerPid) ->
    io:format("pushing data~n"),
    gen_server:call(?SERVER, {push_data, SCPacket, PacketTime, HandlerPid}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),

    PubKeyBin = maps:get(pubkeybin, Args),
    Address = maps:get(address, Args),

    Port = maps:get(port, Args),
    {ok, Socket} = hpr_udp_socket:open({Address, Port}, maps:get(tee, Args, undefined)),

    DisablePullData = maps:get(disable_pull_data, Args, false),
    PullDataTimer = maps:get(pull_data_timer, Args, ?PULL_DATA_TIMER),
    case DisablePullData of
        true ->
            ok;
        false ->
            %% Pull data immediately so we can establish a connection for the first
            %% pull_response.
            self() ! ?PULL_DATA_TICK,
            schedule_pull_data(PullDataTimer)
    end,

    ShutdownTimeout = maps:get(shutdown_timer, Args, ?SHUTDOWN_TIMER),
    ShutdownRef = schedule_shutdown(ShutdownTimeout),

    State = #state{
        pubkeybin = PubKeyBin,

        socket = Socket,
        pull_data_timer = PullDataTimer,
        shutdown_timer = {ShutdownTimeout, ShutdownRef}
    },

    {ok, State}.

handle_call(
    {update_address, Address, Port},
    _From,
    #state{socket = Socket0} = State
) ->
    lager:debug("Updating address and port [old: ~p] [new: ~p]", [
        hpr_udp_socket:get_address(Socket0),
        {Address, Port}
    ]),
    {ok, Socket1} = hpr_udp_socket:update_address(Socket0, {Address, Port}),
    {reply, ok, State#state{socket = Socket1}};
handle_call(
    {push_data, SCPacket, PacketTime, HandlerPid},
    _From,
    #state{
        push_data = PushData,
        location = Loc,
        shutdown_timer = {ShutdownTimeout, ShutdownRef}
    } =
        State
) ->
    _ = erlang:cancel_timer(ShutdownRef),
    io:format("handling data, "),
    {Token, Data} = handle_data(SCPacket, PacketTime, Loc),
    io:format("data handled, sending~n"),
    {Reply, TimerRef} = send_push_data(Token, Data, State),
    {reply, Reply, State#state{
        push_data = maps:put(Token, {Data, TimerRef}, PushData),
        handler_pid = HandlerPid,
        shutdown_timer = {ShutdownTimeout, schedule_shutdown(ShutdownTimeout)}
    }};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(get_hotspot_location, #state{pubkeybin = PubKeyBin} = State) ->
    Location = pp_utils:get_hotspot_location(PubKeyBin),
    lager:info("got location ~p for hotspot", [Location]),
    {noreply, State#state{location = Location}};
handle_info(
    {udp, Socket, _Address, _Port, Data},
    #state{
        socket = {socket, Socket, _, _}
    } = State
) ->
    %% io:format("got udp packet ~p from ~p:~p~n", [Data, _Address, Port]),
    try handle_udp(Data, State) of
        {noreply, _} = NoReply -> NoReply
    catch
        _E:_R:_S ->
            io:format("failed to handle UDP packet ~p: ~p/~p~n~n~p~n~n", [Data, _E, _R, _S]),
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
    ?PULL_DATA_TICK,
    State
) ->
    {ok, RefAndToken} = send_pull_data(State),
    {noreply, State#state{pull_data = RefAndToken}};
handle_info(
    ?PULL_DATA_TIMEOUT_TICK,
    #state{pull_data_timer = PullDataTimer} = State
) ->
    lager:debug("got a pull data timeout, ignoring missed pull_ack [retry: ~p]", [PullDataTimer]),
    _ = schedule_pull_data(PullDataTimer),
    {noreply, State};
handle_info(?SHUTDOWN_TICK, #state{shutdown_timer = {ShutdownTimeout, _}} = State) ->
    lager:info("shutting down, haven't sent data in ~p", [ShutdownTimeout]),
    {stop, normal, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{socket = Socket}) ->
    lager:info("going down ~p", [_Reason]),
    ok = hpr_udp_socket:close(Socket),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec handle_data(
    SCPacket :: blockchain_state_channel_packet_v1:packet(),
    PacketTime :: pos_integer(),
    Location :: {pos_integer(), float(), float()} | no_location | undefined
) -> {binary(), binary()}.
handle_data(Up, PacketTime, _Location) ->
    %% Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    %% PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    %% Region = blockchain_state_channel_packet_v1:region(SCPacket),
    Token = semtech_udp:token(),
    MAC = pubkeybin_to_mac(hpr_packet_up:hotspot(Up)),
    %% Tmst = blockchain_helium_packet_v1:timestamp(Packet),
    %% Payload = blockchain_helium_packet_v1:payload(Packet),
    %% {Index, Lat, Long} =
    %%     case Location of
    %%         undefined -> {undefined, undefined, undefined};
    %%         no_location -> {undefined, undefined, undefined};
    %%         {_, _, _} = L -> L
    %%     end,
    Data = semtech_udp:push_data(
        Token,
        MAC,
        #{
            time => iso8601:format(
                calendar:system_time_to_universal_time(PacketTime, millisecond)
            ),
            tmst => hpr_packet_up:timestamp(Up) band 16#FFFFFFFF,
            freq => list_to_float(
                float_to_list(hpr_packet_up:frequency(Up), [{decimals, 4}, compact])
            ),
            %% freq => io_lib:format("~.4f", [hpr_packet_up:frequency(Up)]),% blockchain_helium_packet_v1:frequency(Packet),
            rfch => 0,
            modu => <<"LORA">>,
            codr => <<"4/5">>,
            stat => 1,
            chan => 0,
            % erlang:list_to_binary(blockchain_helium_packet_v1:datarate(Packet)),
            datr => erlang:list_to_binary(hpr_packet_up:datarate(Up)),
            %erlang:trunc(blockchain_helium_packet_v1:signal_strength(Packet)),
            rssi => erlang:trunc(hpr_packet_up:signal_strength(Up)),
            % blockchain_helium_packet_v1:snr(Packet),
            lsnr => hpr_packet_up:snr(Up),
            % erlang:byte_size(Payload),
            size => erlang:byte_size(hpr_packet_up:payload(Up)),
            % base64:encode(Payload)
            data => base64:encode(hpr_packet_up:payload(Up))
        },
        #{
            %Region,
            regi => hpr_packet_up:region(Up),
            %% inde => Index,
            %% lati => Lat,
            %% long => Long,
            pubk => <<"11rvfjsZvJZGyMBLYjfXezrq3JqAuevsgbforKDzw27eeCKPE5X">>
        }
    ),
    {Token, Data}.

-spec handle_udp(binary(), #state{}) -> {noreply, #state{}}.
handle_udp(Data, State) ->
    %% Identifier = semtech_udp:identifier(Data),
    %% io:format("got udp ~p / ~p~n", [semtech_udp:identifier_to_atom(Identifier), Data]),
    case semtech_udp:identifier(Data) of
        ?PUSH_ACK ->
            handle_push_ack(Data, State);
        ?PULL_ACK ->
            handle_pull_ack(Data, State);
        ?PULL_RESP ->
            handle_pull_resp(Data, State);
        _Id ->
            lager:warning("got unknown identifier ~p for ~p", [_Id, Data]),
            {noreply, State}
    end.

-spec handle_push_ack(binary(), #state{}) -> {noreply, #state{}}.
handle_push_ack(Data, #state{push_data = PushData} = State) ->
    Token = semtech_udp:token(Data),
    case maps:get(Token, PushData, undefined) of
        undefined ->
            lager:debug("got unkown push ack ~p", [Token]),
            {noreply, State};
        {_, TimerRef} ->
            lager:debug("got push ack ~p", [Token]),
            _ = erlang:cancel_timer(TimerRef),
            {noreply, State#state{push_data = maps:remove(Token, PushData)}}
    end.

-spec handle_pull_ack(binary(), #state{}) -> {noreply, #state{}}.
handle_pull_ack(
    _Data,
    #state{
        pull_data = undefined
    } = State
) ->
    lager:warning("got unknown pull ack for ~p", [_Data]),
    {noreply, State};
handle_pull_ack(
    Data, #state{pull_data = {PullDataRef, PullDataToken}, pull_data_timer = PullDataTimer} = State
) ->
    case semtech_udp:token(Data) of
        PullDataToken ->
            erlang:cancel_timer(PullDataRef),
            lager:debug("got pull ack for ~p", [PullDataToken]),
            _ = schedule_pull_data(PullDataTimer),
            {noreply, State#state{pull_data = undefined}};
        _UnknownToken ->
            lager:warning("got unknown pull ack for ~p", [_UnknownToken]),
            {noreply, State}
    end.

handle_pull_resp(Data, #state{handler_pid = HandlerPid} = State) ->
    %% io:format("hanldling pull resp ~p~n", [State]),
    ok = do_handle_pull_resp(Data, HandlerPid),
    io:format("handled, now making a token~n"),
    Token = semtech_udp:token(Data),
    io:format("sending the tx ack~n"),
    _ = send_tx_ack(Token, State),
    io:format("replying~n"),
    {noreply, State}.

-spec do_handle_pull_resp(binary(), pid()) -> ok.
do_handle_pull_resp(Data, StreamState) ->
    io:format("getting the map:~n~p~n", [semtech_udp:json_data(Data)]),
    Map = maps:get(<<"txpk">>, semtech_udp:json_data(Data)),
    io:format("have the map: ~p~n", [Map]),
    JSONData0 = base64:decode(maps:get(<<"data">>, Map)),
    io:format("some data: ~p~n", [JSONData0]),

    %% -record(window_v1_pb,
    %% {timestamp = 0          :: non_neg_integer() | undefined, % = 1, optional, 64 bits
    %%  frequency = 0.0        :: float() | integer() | infinity | '-infinity' | nan | undefined, % = 2, optional
    %%  datarate = []          :: unicode:chardata() | undefined % = 3, optional
    %% }).

    Down = #packet_router_packet_down_v1_pb{
        payload = JSONData0,
        rx1 = #window_v1_pb{
            timestamp = maps:get(<<"tmst">>, Map),
            frequency = maps:get(<<"freq">>, Map),
            datarate = maps:get(<<"datr">>, Map)
        },
        rx2 = undefined
    },
    %% Down = packet_router_pb:encode_msg(Down0),
    io:format("sending: ~p~n", [Down]),
    grpcbox_stream:send(false, Down, StreamState),

    ok.

-spec schedule_pull_data(non_neg_integer()) -> reference().
schedule_pull_data(PullDataTimer) ->
    _ = erlang:send_after(PullDataTimer, self(), ?PULL_DATA_TICK).

-spec schedule_shutdown(non_neg_integer()) -> reference().
schedule_shutdown(ShutdownTimer) ->
    _ = erlang:send_after(ShutdownTimer, self(), ?SHUTDOWN_TICK).

-spec send_pull_data(#state{}) -> {ok, {reference(), binary()}} | {error, any()}.
send_pull_data(
    #state{
        pubkeybin = PubKeyBin,
        socket = Socket,
        pull_data_timer = PullDataTimer
    }
) ->
    Token = semtech_udp:token(),
    Data = semtech_udp:pull_data(Token, pubkeybin_to_mac(PubKeyBin)),
    case hpr_udp_socket:send(Socket, Data) of
        ok ->
            lager:debug("sent pull data keepalive ~p", [Token]),
            TimerRef = erlang:send_after(PullDataTimer, self(), ?PULL_DATA_TIMEOUT_TICK),
            {ok, {TimerRef, Token}};
        Error ->
            lager:warning("failed to send pull data keepalive ~p: ~p", [Token, Error]),
            Error
    end.

-spec send_push_data(binary(), binary(), #state{}) -> {ok | {error, any()}, reference()}.
send_push_data(
    Token,
    Data,
    #state{socket = Socket}
) ->
    Reply = hpr_udp_socket:send(Socket, Data),
    TimerRef = erlang:send_after(?PUSH_DATA_TIMER, self(), {?PUSH_DATA_TICK, Token}),
    lager:debug("sent ~p/~p to ~p replied: ~p", [
        Token,
        Data,
        hpr_udp_socket:get_address(Socket),
        Reply
    ]),
    {Reply, TimerRef}.

-spec send_tx_ack(binary(), #state{}) -> ok | {error, any()}.
send_tx_ack(
    Token,
    #state{pubkeybin = PubKeyBin, socket = Socket}
) ->
    Data = semtech_udp:tx_ack(Token, pubkeybin_to_mac(PubKeyBin)),
    Reply = hpr_udp_socket:send(Socket, Data),
    lager:debug("sent ~p/~p to ~p replied: ~p", [
        Token,
        Data,
        hpr_udp_socket:get_address(Socket),
        Reply
    ]),
    Reply.

-spec pubkeybin_to_mac(binary()) -> binary().
pubkeybin_to_mac(PubKeyBin) ->
    <<(xxhash:hash64(PubKeyBin)):64/unsigned-integer>>.
