%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs
%%% @doc
%%%
%%% @end
%%% Created : 21. Sep 2022 1:01 PM
%%%-------------------------------------------------------------------
-module(hpr_http_roaming_worker).
-author("jonathanruttenberg").

-behavior(gen_server).

-include("hpr_http_roaming.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    handle_packet/3
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
-define(SEND_DATA, send_data).
-define(SHUTDOWN, shutdown).
-define(SHUTDOWN_TIMEOUT, timer:seconds(5)).

-type address() :: binary().

-record(state, {
    net_id :: hpr_http_roaming:netid_num(),
    address :: address(),
    transaction_id :: integer(),
    packets = [] :: list(hpr_http_roaming:packet()),
    send_data_timer = 200 :: non_neg_integer(),
    send_data_timer_ref :: undefined | reference(),
    flow_type :: async | sync,
    auth_header :: null | binary(),
    receiver_nsid :: binary(),
    should_shutdown = false :: boolean(),
    shutdown_timer_ref :: undefined | reference()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec handle_packet(
    WorkerPid :: pid(),
    PacketUp :: hpr_packet_up:packet(),
    GatewayTime :: hpr_http_roaming:gateway_time()
) -> ok | {error, any()}.
handle_packet(Pid, PacketUp, GatewayTime) ->
    gen_server:cast(Pid, {handle_packet, PacketUp, GatewayTime}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    #{
        protocol := #http_protocol{
            endpoint = Address,
            flow_type = FlowType,
            dedupe_timeout = DedupeTimeout,
            auth_header = Auth,
            receiver_nsid = ReceiverNSID
        },
        net_id := NetID
    } = Args,
    lager:debug("~p init with ~p", [?MODULE, Args]),
    {ok, #state{
        net_id = NetID,
        address = Address,
        transaction_id = next_transaction_id(),
        send_data_timer = DedupeTimeout,
        flow_type = FlowType,
        auth_header = Auth,
        receiver_nsid = ReceiverNSID
    }}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(
    {handle_packet, PacketUp, GatewayTime},
    #state{send_data_timer = 0, shutdown_timer_ref = ShutdownTimerRef0} = State
) ->
    ok = hpr_packet_up:md(PacketUp),
    {ok, StateWithPacket} = do_handle_packet(
        PacketUp, GatewayTime, State
    ),
    ok = send_data(StateWithPacket),
    {ok, ShutdownTimerRef1} = maybe_schedule_shutdown(ShutdownTimerRef0),
    {noreply, State#state{shutdown_timer_ref = ShutdownTimerRef1}};
handle_cast(
    {handle_packet, PacketUp, GatewayTime},
    #state{
        should_shutdown = false,
        send_data_timer = Timeout,
        send_data_timer_ref = TimerRef0
    } = State0
) ->
    ok = hpr_packet_up:md(PacketUp),
    {ok, State1} = do_handle_packet(PacketUp, GatewayTime, State0),
    {ok, TimerRef1} = maybe_schedule_send_data(Timeout, TimerRef0),
    {noreply, State1#state{send_data_timer_ref = TimerRef1}};
handle_cast(
    {handle_packet, PacketUp, _PacketTime},
    #state{
        should_shutdown = true,
        shutdown_timer_ref = ShutdownTimerRef0,
        send_data_timer = DataTimeout
    } = State0
) ->
    ok = hpr_packet_up:md(PacketUp),
    lager:debug("packet delivery after data sent [send_data_timer: ~w]", [DataTimeout]),
    {ok, ShutdownTimerRef1} = maybe_schedule_shutdown(ShutdownTimerRef0),
    {noreply, State0#state{shutdown_timer_ref = ShutdownTimerRef1}};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?SEND_DATA, #state{} = State) ->
    ok = send_data(State),
    {ok, ShutdownTimerRef} = maybe_schedule_shutdown(undefined),
    {noreply, State#state{should_shutdown = true, shutdown_timer_ref = ShutdownTimerRef}};
handle_info(?SHUTDOWN, #state{} = State) ->
    {stop, normal, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

terminate(_Reason, #state{}) ->
    lager:info("going down ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec maybe_schedule_send_data(integer(), undefined | reference()) -> {ok, reference()}.
maybe_schedule_send_data(Timeout, undefined) ->
    {ok, erlang:send_after(Timeout, self(), ?SEND_DATA)};
maybe_schedule_send_data(_, Ref) ->
    {ok, Ref}.

-spec maybe_schedule_shutdown(undefined | reference()) -> {ok, reference()}.
maybe_schedule_shutdown(undefined) ->
    {ok, erlang:send_after(?SHUTDOWN_TIMEOUT, self(), ?SHUTDOWN)};
maybe_schedule_shutdown(CurrTimer) ->
    _ = (catch erlang:cancel_timer(CurrTimer)),
    {ok, erlang:send_after(?SHUTDOWN_TIMEOUT, self(), ?SHUTDOWN)}.

-spec next_transaction_id() -> integer().
next_transaction_id() ->
    rand:uniform(16#7FFFFFFF).

-spec do_handle_packet(
    PacketUp :: hpr_packet_up:packet(),
    GatewayTime :: hpr_http_roaming:gateway_time(),
    State :: #state{}
) -> {ok, #state{}}.
do_handle_packet(
    PacketUp, GatewayTime, #state{packets = Packets} = State
) ->
    State1 = State#state{
        packets = [
            hpr_http_roaming:new_packet(PacketUp, GatewayTime) | Packets
        ]
    },
    {ok, State1}.

-spec send_data(#state{}) -> ok.
send_data(
    #state{
        net_id = NetID,
        address = Address,
        packets = Packets,
        transaction_id = TransactionID,
        flow_type = FlowType,
        auth_header = Auth,
        receiver_nsid = ReceiverNSID,
        send_data_timer = DedupWindow
    }
) ->
    Data = hpr_http_roaming:make_uplink_payload(
        NetID,
        Packets,
        TransactionID,
        DedupWindow,
        Address,
        FlowType,
        ReceiverNSID
    ),
    Data1 = jsx:encode(Data),

    Headers =
        case Auth of
            null -> [{<<"Content-Type">>, <<"application/json">>}];
            _ -> [{<<"Content-Type">>, <<"application/json">>}, {<<"Authorization">>, Auth}]
        end,

    case hackney:post(Address, Headers, Data1, [with_body]) of
        {ok, 200, _Headers, <<>>} ->
            lager:info("~p empty response [flow_type: ~p]", [NetID, FlowType]),
            ok;
        {ok, 200, _Headers, Res} ->
            case FlowType of
                sync ->
                    %% All uplinks are PRStartReq. We will only ever receive a
                    %% PRStartAns from that. XMitDataReq downlinks come out of
                    %% band to the HTTP listener.
                    try jsx:decode(Res) of
                        Decoded ->
                            case hpr_http_roaming:handle_prstart_ans(Decoded) of
                                {error, Err} ->
                                    lager:error("error handling response: ~p", [Err]),
                                    ok;
                                {join_accept, {PubKeyBin, PacketDown},{ PRStartNotif, Endpoint}} ->
                                    case
                                        hpr_packet_router_service:send_packet_down(
                                            PubKeyBin, PacketDown
                                        )
                                    of
                                        ok ->
                                            lager:debug("got join_accept"),
                                            _ = hackney:post(
                                                Endpoint,
                                                Headers,
                                                jsx:encode(PRStartNotif),
                                                [with_body]
                                            ),
                                            ok;
                                        {error, not_found} ->
                                            _ = hackney:post(
                                                Endpoint,
                                                Headers,
                                                jsx:encode(PRStartNotif#{
                                                    'Result' => #{'ResultCode' => <<"XmitFailed">>}
                                                }),
                                                [with_body]
                                            ),
                                            ok
                                    end;
                                ok ->
                                    lager:debug("sent"),
                                    ok
                            end
                    catch
                        Type:Err:Stack ->
                            lager:error("error decoding sync res ~p", [Res]),
                            lager:error("~p", [{Type, Err, Stack}]),
                            ok
                    end;
                async ->
                    ok
            end;
        {ok, Code, _Headers, Resp} ->
            lager:error("bad response: [code: ~p] [res: ~p]", [Code, Resp]),
            ok
    end.
