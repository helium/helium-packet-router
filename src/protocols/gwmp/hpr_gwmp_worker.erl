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

-include("semtech_udp.hrl").
-include_lib("kernel/include/inet.hrl").

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
    terminate/2
]).

-define(SERVER, ?MODULE).

-type pull_data_map() :: #{
    socket_dest() => acknowledged | #{timer_ref := reference(), token := binary()}
}.

-type socket_address() :: inet:socket_address() | inet:hostname().
-type socket_port() :: inet:port_number().
-type socket_dest() :: {socket_address(), socket_port()}.

-record(state, {
    pubkeybin :: libp2p_crypto:pubkey_bin(),
    socket :: gen_udp:socket(),
    push_data = #{} :: #{binary() => {binary(), reference()}},
    pull_data = #{} :: pull_data_map(),
    pull_data_timer :: non_neg_integer(),
    addr_resolutions = #{} :: #{socket_dest() => socket_dest()}
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec push_data(
    WorkerPid :: pid(),
    PacketUp :: hpr_packet_up:packet(),
    SocketDest :: socket_dest()
) -> ok | {error, any()}.
push_data(WorkerPid, PacketUp, SocketDest) ->
    gen_server:cast(WorkerPid, {push_data, PacketUp, SocketDest, erlang:system_time(millisecond)}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),

    #{pubkeybin := PubKeyBin} = Args,

    PullDataTimer = maps:get(pull_data_timer, Args, ?PULL_DATA_TIMER),

    lager:md([
        {gateway, hpr_utils:gateway_name(PubKeyBin)},
        {gateway_mac, hpr_utils:gateway_mac(PubKeyBin)},
        {pubkey, libp2p_crypto:bin_to_b58(PubKeyBin)}
    ]),

    {ok, Socket} = gen_udp:open(0, [binary, {active, true}]),

    %% NOTE: Pull data is sent at the first push_data to
    %% initiate the connection and allow downlinks to start
    %% flowing.

    {ok, #state{
        pubkeybin = PubKeyBin,
        socket = Socket,
        pull_data_timer = PullDataTimer
    }}.

-spec handle_call(Msg, _From, #state{}) -> {stop, {unimplemented_call, Msg}, #state{}}.
handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

handle_cast(
    {push_data, PacketUp, SocketDest, Timestamp},
    #state{
        push_data = PushData,
        socket = Socket
    } =
        State0
) ->
    ok = hpr_packet_up:md(PacketUp),
    {Token, Payload} = packet_up_to_push_data(PacketUp, Timestamp),
    State = maybe_send_pull_data(SocketDest, State0),
    {_Reply, TimerRef} = send_push_data(Token, Payload, Socket, SocketDest),
    NewPushData = maps:put(Token, {Payload, TimerRef}, PushData),
    {noreply, State#state{
        push_data = NewPushData
    }};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(
    {udp, Socket, Address, Port, Data},
    #state{socket = Socket} = State
) ->
    try handle_udp(Data, {Address, Port}, State) of
        {noreply, _} = NoReply -> NoReply
    catch
        _E:_R ->
            lager:error("failed to handle UDP packet ~p/~p", [_E, _R]),
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
    case send_pull_data(PubKeyBin, Socket, SocketDest, PullDataTimer) of
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
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State = #state{socket = Socket}) ->
    ok = gen_udp:close(Socket).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec packet_up_to_push_data(
    PacketUp :: hpr_packet_up:packet(),
    PacketTime :: non_neg_integer()
) ->
    {Token :: binary(), Payload :: binary()}.
packet_up_to_push_data(Up, GatewayTime) ->
    Token = semtech_udp:token(),
    PubKeyBin = hpr_packet_up:gateway(Up),
    MAC = hpr_utils:pubkeybin_to_mac(PubKeyBin),
    B58 = erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
    Name = erlang:list_to_binary(hpr_utils:gateway_name(PubKeyBin)),

    Data = semtech_udp:push_data(
        Token,
        MAC,
        #{
            time => iso8601:format(
                calendar:system_time_to_universal_time(GatewayTime, millisecond)
            ),
            tmst => hpr_packet_up:timestamp(Up) band 16#FFFF_FFFF,
            freq => hpr_packet_up:frequency_mhz(Up),
            rfch => 0,
            modu => <<"LORA">>,
            codr => <<"4/5">>,
            stat => 1,
            chan => 0,
            datr => erlang:atom_to_binary(hpr_packet_up:datarate(Up)),
            rssi => hpr_packet_up:rssi(Up),
            lsnr => hpr_packet_up:snr(Up),
            size => erlang:byte_size(hpr_packet_up:payload(Up)),
            data => base64:encode(hpr_packet_up:payload(Up)),
            meta => #{
                gateway_id => B58,
                gateway_name => Name
            }
        },
        #{
            regi => hpr_packet_up:region(Up),
            %% TODO: Add back potential geo stuff
            %% CP breaks if {lati, long} are not parseable number
            %% inde => Index,
            %% lati => Lat,
            %% long => Long,
            pubk => B58
        }
    ),
    {Token, Data}.

-spec txpk_to_packet_down(TxPkBin :: binary()) -> hpr_packet_down:packet().
txpk_to_packet_down(TxPkBin) ->
    TxPk = semtech_udp:json_data(TxPkBin),
    Map = maps:get(<<"txpk">>, TxPk),
    JSONData0 = base64:decode(maps:get(<<"data">>, Map)),
    Timestamp =
        case maps:get(<<"imme">>, Map, false) of
            false -> maps:get(<<"tmst">>, Map);
            true -> 0
        end,
    hpr_packet_down:new_downlink(
        JSONData0,
        Timestamp,
        erlang:round(maps:get(<<"freq">>, Map) * 1_000_000),
        erlang:binary_to_existing_atom(maps:get(<<"datr">>, Map))
    ).

-spec handle_udp(
    Data :: binary(),
    DataSrc :: socket_dest(),
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
                ok = handle_pull_resp(Data, DataSrc, PubKeyBin, Socket),
                State0;
            _Id ->
                lager:warning("got unknown identifier ~p for ~p", [_Id, Data]),
                State0
        end,
    {noreply, State1}.

-spec schedule_pull_data(non_neg_integer(), socket_dest()) -> reference().
schedule_pull_data(PullDataTimer, SocketDest) ->
    _ = erlang:send_after(PullDataTimer, self(), {?PULL_DATA_TICK, SocketDest}).

-spec send_push_data(binary(), binary(), gen_udp:socket(), socket_dest()) ->
    {ok | {error, any()}, reference()}.
send_push_data(
    Token,
    Data,
    Socket,
    SocketDest
) ->
    Reply = udp_send(Socket, SocketDest, Data),
    TimerRef = erlang:send_after(?PUSH_DATA_TIMER, self(), {?PUSH_DATA_TICK, Token}),
    lager:debug(
        [{token, Token}, {dest, SocketDest}, {reply, Reply}],
        "sent push_data"
    ),
    {Reply, TimerRef}.

-spec send_pull_data(
    PubKeybin :: libp2p_crypto:pubkey_bin(),
    Socket :: gen_udp:socket(),
    Dest :: socket_dest(),
    PullDataTimer :: non_neg_integer()
) -> {ok, #{timer_ref := reference(), token := binary()}} | {error, any()}.
send_pull_data(PubKeyBin, Socket, SocketDest, PullDataTimer) ->
    Token = semtech_udp:token(),
    Data = semtech_udp:pull_data(Token, hpr_utils:pubkeybin_to_mac(PubKeyBin)),
    case udp_send(Socket, SocketDest, Data) of
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
    DataSrc :: socket_dest(),
    PullData :: pull_data_map(),
    PullDataTime :: non_neg_integer()
) -> pull_data_map().
handle_pull_ack(Data, DataSrc, PullDataMap, PullDataTimer) ->
    case {semtech_udp:token(Data), maps:get(DataSrc, PullDataMap, undefined)} of
        {Token, #{token := Token, timer_ref := TimerRef}} ->
            _ = erlang:cancel_timer(TimerRef),
            _ = schedule_pull_data(PullDataTimer, DataSrc),
            maps:put(DataSrc, acknowledged, PullDataMap);
        {_, undefined} ->
            lager:warning("pull_ack for unknown source"),
            PullDataMap;
        _ ->
            lager:warning("pull_ack with unknown token"),
            PullDataMap
    end.

-spec handle_pull_resp(
    Data :: binary(),
    DataSrc :: socket_dest(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Socket :: gen_udp:socket()
) ->
    ok.
handle_pull_resp(Data, DataSrc, PubKeyBin, Socket) ->
    %% Send downlink to grpc handler
    PacketDown = txpk_to_packet_down(Data),
    lager:debug("sending gwmp downlink to  ~p", [hpr_utils:gateway_name(PubKeyBin)]),
    _ = hpr_packet_router_service:send_packet_down(PubKeyBin, PacketDown),
    %% Ack the downlink
    Token = semtech_udp:token(Data),
    send_tx_ack(Token, PubKeyBin, Socket, DataSrc),
    ok.

-spec send_tx_ack(
    Token :: binary(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Socket :: gen_udp:socket(),
    SocketDest :: socket_dest()
) -> ok | {error, any()}.
send_tx_ack(Token, PubKeyBin, Socket, SocketDest) ->
    Data = semtech_udp:tx_ack(Token, hpr_utils:pubkeybin_to_mac(PubKeyBin)),
    Reply = udp_send(Socket, SocketDest, Data),
    lager:debug(
        "sent ~p/~p to ~p replied: ~p",
        [Token, Data, SocketDest, Reply]
    ),
    Reply.

%%%-------------------------------------------------------------------
%% @doc
%% Only send a PULL_DATA if we haven't seen the destination
%% before. If we have, the lifecycle for sending PULL_DATA
%% is already being handled.
%% @end
%%%-------------------------------------------------------------------
-spec maybe_send_pull_data(
    SocketDest :: socket_dest(),
    State :: #state{}
) -> #state{}.
maybe_send_pull_data(
    SocketDest0,
    #state{pull_data = PullDataMap, addr_resolutions = AddrResolutions0} = State0
) ->
    {SocketDest, AddrResolutions} = maybe_resolve_addr(SocketDest0, AddrResolutions0),
    State = State0#state{addr_resolutions = AddrResolutions},
    case maps:get(SocketDest, PullDataMap, undefined) of
        undefined ->
            #state{
                pubkeybin = PubKeyBin,
                socket = Socket,
                pull_data_timer = PullDataTimer
            } = State,
            case send_pull_data(PubKeyBin, Socket, SocketDest, PullDataTimer) of
                {ok, RefAndToken} ->
                    State#state{
                        pull_data = maps:put(
                            SocketDest,
                            RefAndToken,
                            PullDataMap
                        )
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

-spec udp_send(gen_udp:socket(), socket_dest(), binary()) -> ok | {error, any()}.
udp_send(Socket, {Address, Port}, Data) ->
    gen_udp:send(Socket, Address, Port, Data).

%%%-------------------------------------------------------------------
%% @doc
%%
%% We get Addresses as strings, but they are handled as `inet:ip_address()'
%% which is a tuple of numbers.
%%
%% So we attempt to clean provided Addresses. If we received a hostname, we will
%% try to resolve it 1 time into the IP Address.
%%
%% Otherwise we carry on with the string form, and there will be warnings in the
%% logs.
%% @end
%%%-------------------------------------------------------------------
-spec maybe_resolve_addr({string(), inet:port_number()}, IpResolutions :: map()) ->
    {{string() | inet:ip_address(), inet:port_number()}, map()}.
maybe_resolve_addr({Addr, Port} = Dest, AddrResolutions) ->
    case maps:get(Dest, AddrResolutions, undefined) of
        undefined ->
            New =
                case inet:parse_address(Addr) of
                    {ok, IPAddr} ->
                        {IPAddr, Port};
                    {error, _} ->
                        {resolve_addr(Addr), Port}
                end,
            {New, AddrResolutions#{Dest => New}};
        Resolved ->
            {Resolved, AddrResolutions}
    end.

resolve_addr(Addr) ->
    case inet:gethostbyname(Addr) of
        {ok, #hostent{h_addr_list = [IPAddr]}} ->
            IPAddr;
        {ok, #hostent{h_addr_list = [IPAddr | _]}} ->
            lager:info([{addr, Addr}], "multiple IPs for address, using the first"),
            IPAddr;
        {error, Err} ->
            lager:warning([{err, Err}, {addr, Addr}], "could not resolve hostname"),
            Addr
    end.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

verify_downlink_test() ->
    %% Taken from actual gwmp reply
    TxPkBin =
        <<2, 211, 238, 3, 123, 34, 116, 120, 112, 107, 34, 58, 123, 34, 105, 109, 109, 101, 34, 58,
            102, 97, 108, 115, 101, 44, 34, 114, 102, 99, 104, 34, 58, 48, 44, 34, 112, 111, 119,
            101, 34, 58, 50, 48, 44, 34, 97, 110, 116, 34, 58, 48, 44, 34, 98, 114, 100, 34, 58, 48,
            44, 34, 116, 109, 115, 116, 34, 58, 53, 54, 54, 53, 53, 56, 51, 44, 34, 102, 114, 101,
            113, 34, 58, 57, 50, 55, 46, 53, 44, 34, 109, 111, 100, 117, 34, 58, 34, 76, 79, 82, 65,
            34, 44, 34, 100, 97, 116, 114, 34, 58, 34, 83, 70, 49, 48, 66, 87, 53, 48, 48, 34, 44,
            34, 99, 111, 100, 114, 34, 58, 34, 52, 47, 53, 34, 44, 34, 105, 112, 111, 108, 34, 58,
            116, 114, 117, 101, 44, 34, 115, 105, 122, 101, 34, 58, 51, 51, 44, 34, 100, 97, 116,
            97, 34, 58, 34, 73, 77, 97, 69, 53, 90, 98, 71, 121, 65, 79, 75, 117, 110, 68, 101, 49,
            50, 85, 85, 48, 89, 100, 57, 54, 72, 78, 106, 85, 115, 114, 121, 115, 82, 55, 86, 107,
            69, 118, 75, 70, 86, 88, 79, 34, 125, 125>>,

    Downlink = txpk_to_packet_down(TxPkBin),
    ?assertEqual(ok, packet_router_pb:verify_msg(Downlink)),

    ok.

-endif.
