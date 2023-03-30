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
-ifdef(TEST).
-define(CLEANUP_TIME, timer:seconds(1)).
-else.
-define(CLEANUP_TIME, timer:seconds(30)).
-endif.

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
                            ok = gen_server:cast(?MODULE, {monitor, Gateway, LNS}),
                            get_stream(Gateway, LNS, Server)
                    end
            end
    end.

-spec remove_stream(libp2p_crypto:pubkey_bin(), binary()) -> ok.
remove_stream(Gateway, LNS) ->
    case ets:lookup(?STREAM_ETS, {Gateway, LNS}) of
        [{_, Stream}] ->
            ok = grpcbox_client:close_send(Stream),
            true = ets:delete(?STREAM_ETS, {Gateway, LNS}),
            lager:debug("closed stream"),
            ok;
        [] ->
            lager:debug("did not close stream"),
            ok
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    lager:info("~p started", [?MODULE]),
    {ok, #state{}}.

-spec handle_call(Msg, _From, #state{}) -> {stop, {unimplemented_call, Msg}, #state{}}.
handle_call(Msg, _From, State) ->
    lager:warning("unknown call ~p", [Msg]),
    {stop, {unimplemented_call, Msg}, State}.

handle_cast({monitor, Gateway, LNS}, State) ->
    case hpr_packet_router_service:locate(Gateway) of
        {ok, Pid} ->
            _ = erlang:monitor(process, Pid, [{tag, {'DOWN', Gateway, LNS}}]),
            lager:debug("monitoring gateway stream ~p", [Pid]);
        {error, _Reason} ->
            lager:debug("failed to monitor gateway (~s) stream for lns (~s) ~p", [
                hpr_utils:gateway_name(Gateway), LNS, _Reason
            ]),
            %% Instead of doing a remove_stream, we trigger a fake DOWN message so that we dont kill
            %% the stream to Router right away so if a downlink comes back and the gateway reconnected
            %% we can still send that downlink
            self() ! {{'DOWN', Gateway, LNS}, erlang:make_ref(), process, undefined, monitor_failed}
    end,
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:warning("unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {{'DOWN', Gateway, LNS}, _Monitor, process, _Pid, _ExitReason},
    #state{} = State
) ->
    lager:debug("gateway stream ~p went down: ~p waiting ~wms", [_Pid, _ExitReason, ?CLEANUP_TIME]),
    erlang:spawn(fun() ->
        timer:sleep(?CLEANUP_TIME),
        case hpr_packet_router_service:locate(Gateway) of
            {error, _Reason} ->
                lager:debug("connot find a gateway stream: ~p, shutting down", [_Reason]),
                ?MODULE:remove_stream(Gateway, LNS);
            {ok, NewPid} ->
                ok = gen_server:cast(?MODULE, {monitor, Gateway, LNS}),
                lager:debug("monitoring new gateway stream ~p", [NewPid])
        end
    end),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("unknown info ~p", [_Msg]),
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

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        ?_test(test_full()),
        ?_test(test_cannot_locate_stream())
    ]}.

foreach_setup() ->
    application:ensure_all_started(gproc),
    meck:new(grpcbox_channel),
    meck:new(grpcbox_client),
    ?MODULE:init(),
    {ok, Pid} = ?MODULE:start_link(#{}),
    Pid.

foreach_cleanup(Pid) ->
    ok = gen_server:stop(Pid),
    true = ets:delete(?STREAM_ETS),
    meck:unload(grpcbox_channel),
    meck:unload(grpcbox_client),
    application:stop(gproc),
    ok.

test_full() ->
    Route = test_route(),

    meck:expect(grpcbox_channel, pick, fun(_LNS, stream) -> {ok, {undefined, undefined}} end),

    Stream = #{channel => self(), stream_pid => self()},
    meck:expect(grpcbox_client, stream, fun(_Ctx, <<"/helium.packet_router.packet/route">>, _, _) ->
        {ok, Stream}
    end),

    meck:expect(grpcbox_client, send, fun(_, _) -> ok end),

    PubKeyBin = <<"PubKeyBin">>,
    ok = hpr_packet_router_service:register(PubKeyBin),

    HprPacketUp = test_utils:join_packet_up(#{gateway => PubKeyBin}),
    ?assertEqual(ok, ?MODULE:send(HprPacketUp, Route)),

    timer:sleep(?CLEANUP_TIME + 100),
    ok = test_utils:wait_until(
        fun() ->
            1 == ets:info(?STREAM_ETS, size)
        end
    ),
    ?assert(erlang:is_process_alive(erlang:whereis(?MODULE))),
    ok.

%% We do not register a gateway to trigger cleanup
test_cannot_locate_stream() ->
    Route = test_route(),

    meck:expect(grpcbox_channel, pick, fun(_LNS, stream) -> {ok, {undefined, undefined}} end),

    Stream = #{channel => self(), stream_pid => self()},
    meck:expect(grpcbox_client, stream, fun(_Ctx, <<"/helium.packet_router.packet/route">>, _, _) ->
        {ok, Stream}
    end),

    meck:expect(grpcbox_client, send, fun(_, _) -> ok end),
    meck:expect(grpcbox_client, close_send, fun(_) -> ok end),

    PubKeyBin = <<"PubKeyBin">>,
    HprPacketUp = test_utils:join_packet_up(#{gateway => PubKeyBin}),
    ?assertEqual(ok, ?MODULE:send(HprPacketUp, Route)),

    ok = test_utils:wait_until(
        fun() ->
            0 == ets:info(?STREAM_ETS, size)
        end
    ),
    ?assert(erlang:is_process_alive(erlang:whereis(?MODULE))),
    ok.

test_route() ->
    Host = "example-lns.com",
    Port = 4321,
    hpr_route:test_new(#{
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
    }).

-endif.
