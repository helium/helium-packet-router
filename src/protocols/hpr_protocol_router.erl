-module(hpr_protocol_router).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    init/0,
    send/2,
    get_stream/3,
    remove_stream/2
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
-export([all_streams/0]).
-endif.

-define(SERVER, ?MODULE).
-define(STREAM_ETS, hpr_protocol_router_ets).

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec init() -> ok.
init() ->
    ?STREAM_ETS = ets:new(?STREAM_ETS, [public, named_table, set, {read_concurrency, true}]),
    ok.

-spec send(
    PacketUp :: hpr_packet_up:packet(),
    Route :: hpr_route:route()
) -> ok | {error, any()}.
send(PacketUp, Route) ->
    Gateway = hpr_packet_up:gateway(PacketUp),
    LNS = hpr_route:lns(Route),
    Server = hpr_route:server(Route),
    case get_stream(Gateway, LNS, Server) of
        {ok, RouterStream} ->
            EnvUp = hpr_envelope_up:new(PacketUp),
            ok = grpcbox_client:send(RouterStream, EnvUp);
        {error, _} = Err ->
            Err
    end.

-spec get_stream(
    Gateway :: libp2p_crypto:pubkey_bin(),
    LNS :: binary(),
    Server :: hpr_route:server()
) -> {ok, grpcbox_client:stream()} | {error, any()}.
get_stream(Gateway, LNS, Server) ->
    case ets:lookup(?STREAM_ETS, {Gateway, LNS}) of
        [{_, #{channel := ChannelPid, stream_pid := StreamPid} = Stream}] ->
            case erlang:is_process_alive(ChannelPid) andalso erlang:is_process_alive(StreamPid) of
                true ->
                    {ok, Stream};
                false ->
                    ets:delete(?STREAM_ETS, {Gateway, LNS}),
                    get_stream(Gateway, LNS, Server)
            end;
        [] ->
            case grpcbox_channel:pick(LNS, stream) of
                {error, _} ->
                    %% No connection
                    Host = hpr_route:host(Server),
                    Port = hpr_route:port(Server),
                    case
                        grpcbox_client:connect(LNS, [{http, Host, Port, []}], #{
                            sync_start => true
                        })
                    of
                        {ok, _Conn, _} ->
                            get_stream(Gateway, LNS, Server);
                        {ok, _Conn} ->
                            get_stream(Gateway, LNS, Server);
                        {error, _} = Error ->
                            Error
                    end;
                {ok, {_Conn, _Interceptor}} ->
                    case
                        helium_packet_router_packet_client:route(#{
                            channel => LNS,
                            callback_module => {
                                hpr_packet_router_downlink_handler,
                                hpr_packet_router_downlink_handler:new_state(Gateway, LNS)
                            }
                        })
                    of
                        {error, _} = Error ->
                            Error;
                        {ok, Stream} ->
                            true = ets:insert(?STREAM_ETS, {{Gateway, LNS}, Stream}),
                            get_stream(Gateway, LNS, Server)
                    end
            end
    end.

-spec remove_stream(libp2p_crypto:pubkey_bin(), binary()) -> true.
remove_stream(Gateway, LNS) ->
    ets:delete(?STREAM_ETS, {Gateway, LNS}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    {ok, #state{}}.

-spec handle_call(Msg, _From, #state{}) -> {stop, {unimplemented_call, Msg}, #state{}}.
handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

handle_cast({monitor, Gateway, LNS}, State) ->
    {ok, Pid} = hpr_packet_router_service:locate(Gateway),
    _ = erlang:monitor(process, Pid, [{tag, {'DOWN', Gateway, LNS}}]),
    lager:debug("monitoring gateway stream ~p", [Pid]),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(
    {{'DOWN', Gateway, LNS}, _Monitor, process, _Pid, _ExitReason},
    #state{} = State
) ->
    lager:debug("gateway stream ~p went down: ~p waiting 30s", [_Pid, _ExitReason]),
    erlang:spawn(fun() ->
        timer:sleep(timer:seconds(30)),
        case hpr_packet_router_service:locate(Gateway) of
            {error, _Reason} ->
                lager:debug("connot find a gateway stream: ~p, shutting down", [_Reason]),
                case ets:lookup(?STREAM_ETS, {Gateway, LNS}) of
                    [{_, Stream}] ->
                        ok = grpcbox_client:close_send(Stream),
                        ets:delete(?STREAM_ETS, {Gateway, LNS}),
                        ok;
                    [] ->
                        ok
                end;
            {ok, StreamPid} ->
                lager:debug("found a new gateway stream ~p", [StreamPid])
        end
    end),

    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% Tests Functions
%% ------------------------------------------------------------------
-ifdef(TEST).

-spec all_streams() -> [{{libp2p_crypto:pubkey_bin(), binary()}, map()}].
all_streams() ->
    ets:tab2list(?STREAM_ETS).

-endif.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

% send/3: happy path
send_test() ->
    ?MODULE:init(),
    meck:new(grpcbox_client),

    PubKeyBin = <<"PubKeyBin">>,
    HprPacketUp = test_utils:join_packet_up(#{gateway => PubKeyBin}),
    EnvUp = hpr_envelope_up:new(HprPacketUp),
    Host = "example-lns.com",
    Port = 4321,
    Route = hpr_route:test_new(#{
        id => "7d502f32-4d58-4746-965e-8c7dfdcfc624",
        net_id => 1,
        devaddr_ranges => [],
        euis => [],
        oui => 1,
        server => #{
            host => Host,
            port => Port,
            protocol => {packet_router, #{}}
        },
        max_copies => 1,
        nonce => 1
    }),
    FakeStream = #{channel => self(), stream_pid => self()},

    true = ets:insert(?STREAM_ETS, {{PubKeyBin, hpr_route:lns(Route)}, FakeStream}),
    meck:expect(grpcbox_client, send, [FakeStream, EnvUp], ok),

    ResponseValue = send(HprPacketUp, Route),

    ?assertEqual(ok, ResponseValue),
    ?assertEqual(1, meck:num_calls(grpcbox_client, send, 2)),

    true = ets:delete(?STREAM_ETS),
    meck:unload(grpcbox_client).

-endif.
