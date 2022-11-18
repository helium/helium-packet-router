-module(hpr_router_relay).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start/2
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2
]).

-record(state, {
    monitor_process :: pid(),
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    router_stream :: grpc_client:client_stream()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start(
    libp2p_crypto:pubkey_bin(),
    grpc_client:client_stream()
) -> {ok, pid()}.
%% @doc Start this service.
start(PubKeyBin, RouterStream) ->
    gen_server:start(?MODULE, [PubKeyBin, RouterStream], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

-spec init(list()) -> {ok, #state{}, {continue, relay}}.
init([PubKeyBin, RouterStream]) ->
    {ok, GatewayStream} = hpr_packet_router_service:locate(PubKeyBin),
    {ok, MonitorPid} =
        hpr_router_relay_monitor:start(
            self(), GatewayStream, RouterStream
        ),
    lager:md([
        {gateway, hpr_utils:gateway_name(PubKeyBin)},
        {router_stream, RouterStream},
        {monitor_pid, MonitorPid}
    ]),
    {
        ok,
        #state{
            monitor_process = MonitorPid,
            pubkey_bin = PubKeyBin,
            router_stream = RouterStream
        },
        {continue, relay}
    }.

-spec handle_continue(relay, #state{}) ->
    {noreply, #state{}, {continue, relay}}
    | {stop, normal, #state{}}
    | {stop, {error, any()}, #state{}}.
handle_continue(relay, #state{router_stream = RouterStream, pubkey_bin = PubKeyBin} = State) ->
    case grpc_client:rcv(RouterStream) of
        {data, Map} ->
            lager:debug("sending router downlink"),
            EnvDown = hpr_envelope_down:to_record(Map),
            {packet, PacketDown} = hpr_envelope_down:data(EnvDown),
            _ = hpr_packet_router_service:send_packet_down(PubKeyBin, PacketDown),
            {noreply, State, {continue, relay}};
        {headers, _} ->
            {noreply, State, {continue, relay}};
        eof ->
            {stop, normal, State};
        {error, _} = Error ->
            {stop, Error, State}
    end.

-spec handle_call(Msg, {pid(), any()}, #state{}) -> {stop, {unimplemented_call, Msg}, #state{}}.
handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

-spec handle_cast(Msg, #state{}) -> {stop, {unimplemented_cast, Msg}, #state{}}.
handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
        ?_test(test_relay_data()),
        ?_test(test_relay_headers()),
        ?_test(test_relay_eof()),
        ?_test(test_relay_error())
    ]}.

foreach_setup() ->
    ok.

foreach_cleanup(ok) ->
    meck:unload().

test_relay_data() ->
    State = state(),
    PacketDownMap = #{payload => <<"data">>},
    EnvDownMap = #{data => {packet, PacketDownMap}},
    Self = self(),
    meck:new(grpc_client),
    meck:expect(grpc_client, rcv, [State#state.router_stream], {data, EnvDownMap}),
    meck:new(hpr_packet_router_service),
    meck:expect(hpr_packet_router_service, send_packet_down, fun(_, _) ->
        Self ! {packet_down, hpr_packet_down:to_record(PacketDownMap)},
        ok
    end),
    Reply = handle_continue(relay, State),
    ?assertEqual({noreply, State, {continue, relay}}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    RelayMessage = receive_relay(),
    ?assertEqual(hpr_packet_down:to_record(PacketDownMap), RelayMessage).

test_relay_headers() ->
    State = state(),
    meck:new(grpc_client),
    meck:expect(grpc_client, rcv, [State#state.router_stream], {headers, #{fake => headers}}),
    Reply = handle_continue(relay, State),
    ?assertEqual({noreply, State, {continue, relay}}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    ?assertEqual(empty, check_messages()).

test_relay_eof() ->
    State = state(),
    meck:new(grpc_client),
    meck:expect(grpc_client, rcv, [State#state.router_stream], eof),
    Reply = handle_continue(relay, State),
    ?assertEqual({stop, normal, State}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    ?assertEqual(empty, check_messages()).

test_relay_error() ->
    State = state(),
    meck:new(grpc_client),
    Error = {error, fake_error},
    meck:expect(grpc_client, rcv, [State#state.router_stream], Error),
    Reply = handle_continue(relay, State),
    ?assertEqual({stop, Error, State}, Reply),
    ?assertEqual(1, meck:num_calls(grpc_client, rcv, 1)),
    ?assertEqual(empty, check_messages()).

% ------------------------------------------------------------------------------
% EUnit test utils
% ------------------------------------------------------------------------------

fake_stream() ->
    Self = self(),
    spawn(
        fun Loop() ->
            monitor(process, Self),
            receive
                {'DOWN', _, process, Self, _} ->
                    ok;
                {packet_down, _} = Reply ->
                    Self ! Reply,
                    Loop();
                Msg ->
                    % sanity check on pattern matches
                    exit({unexpected_message, Msg})
            end
        end
    ).

fake_monitor() ->
    spawn(
        fun() ->
            receive
                stop -> ok
            end
        end
    ).

receive_relay() ->
    receive
        {packet_down, PacketDown} ->
            PacketDown
    after 50 ->
        timeout
    end.

check_messages() ->
    receive
        Msg -> Msg
    after 0 ->
        empty
    end.

state() ->
    #state{
        monitor_process = fake_monitor(),
        pubkey_bin = <<"PubKeyBin">>,
        router_stream = fake_stream()
    }.

-endif.
