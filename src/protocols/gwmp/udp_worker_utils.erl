%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 19. Jul 2022 12:58 PM
%%%-------------------------------------------------------------------
-module(udp_worker_utils).
-author("jonathanruttenberg").

-include("semtech_udp.hrl").

%% API
-export([
    handle_push_data/3,
    pubkeybin_to_mac/1,
    send_tx_ack/2,
    handle_pull_response/3,
    handle_pull_ack/6,
    handle_pull_data_timeout/3,
    send_pull_data/1,
    schedule_pull_data/1,
    handle_push_ack/4,
    new_push_and_shutdown/5,
    update_address/3,
    send_push_data/3,
    update_address/2,
    schedule_shutdown/1,
    handle_pull_ack/5,
    handle_pull_resp/4,
    handle_udp/9
]).

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

-spec pubkeybin_to_mac(binary()) -> binary().
pubkeybin_to_mac(PubKeyBin) ->
    <<(xxhash:hash64(PubKeyBin)):64/unsigned-integer>>.

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

handle_pull_response(Data, PubKeyBin, Socket) ->
    Token = semtech_udp:token(Data),
    send_tx_ack(Token, #{pubkeybin => PubKeyBin, socket => Socket}).

-spec handle_pull_resp(binary(), libp2p_crypto:pubkey_bin(), gwmp_udp_socket:socket(), function()) ->
    any().
handle_pull_resp(Data, PubKeyBin, Socket, PullRespFunction) ->
    _ = PullRespFunction(Data),
    handle_pull_response(Data, PubKeyBin, Socket),
    StateUpdates = #{},
    StateUpdates.

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

-spec schedule_pull_data(non_neg_integer()) -> reference().
schedule_pull_data(PullDataTimer) ->
    _ = erlang:send_after(PullDataTimer, self(), ?PULL_DATA_TICK).

handle_pull_data_timeout(PullDataTimer, NetID, MetricsPrefix) ->
    lager:debug("got a pull data timeout, ignoring missed pull_ack [retry: ~p]", [PullDataTimer]),
    ok = gwmp_metrics:pull_ack_missed(MetricsPrefix, NetID),
    _ = schedule_pull_data(PullDataTimer).

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

new_push_and_shutdown(Token, Data, TimerRef, PushData, ShutdownTimeout) ->
    NewPushData = maps:put(Token, {Data, TimerRef}, PushData),
    NewShutdownTimer = {ShutdownTimeout, schedule_shutdown(ShutdownTimeout)},
    {NewPushData, NewShutdownTimer}.

update_address(Socket0, Address, Port) ->
    lager:debug("Updating address and port [old: ~p] [new: ~p]", [
        gwmp_udp_socket:get_address(Socket0),
        {Address, Port}
    ]),
    {ok, Socket1} = gwmp_udp_socket:update_address(Socket0, {Address, Port}),
    Socket1.

-spec schedule_shutdown(non_neg_integer()) -> reference().
schedule_shutdown(ShutdownTimer) ->
    _ = erlang:send_after(ShutdownTimer, self(), ?SHUTDOWN_TICK).

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

-spec update_address(
    WorkerPid :: pid(),
    Protocol ::
        {Address :: gwmp_udp_socket:socket_address(), Port :: gwmp_udp_socket:socket_port()}
) -> ok.
update_address(WorkerPid, {Address, Port}) ->
    gen_server:call(WorkerPid, {update_address, Address, Port}).
