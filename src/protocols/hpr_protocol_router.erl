-module(hpr_protocol_router).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    init/0,
    send/2,
    get_stream/1
]).

-ifdef(TEST).
-export([all_streams/0]).
-endif.

-define(STREAM_ETS, hpr_protocol_router_ets).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec init() -> ok.
init() ->
    ?STREAM_ETS = ets:new(?STREAM_ETS, [public, named_table, set, {read_concurrency, true}]),
    ok.

-spec send(
    PacketUp :: hpr_packet_up:packet(),
    Route :: hpr_route:route()
) -> ok | {error, any()}.
send(PacketUp, Route) ->
    case get_stream(Route) of
        {ok, RouterStream} ->
            EnvUp = hpr_envelope_up:new(PacketUp),
            ok = grpcbox_client:send(RouterStream, EnvUp);
        {error, _} = Err ->
            Err
    end.

-spec get_stream(Route :: hpr_route:route()) ->
    {ok, grpcbox_client:stream()} | {error, any()}.
get_stream(Route) ->
    LNS = hpr_route:lns(Route),
    case ets:lookup(?STREAM_ETS, LNS) of
        [{_, #{channel := ChannelPid, stream_pid := StreamPid} = Stream}] ->
            case erlang:is_process_alive(ChannelPid) andalso erlang:is_process_alive(StreamPid) of
                true ->
                    {ok, Stream};
                false ->
                    true = ets:delete(?STREAM_ETS, LNS),
                    get_stream(Route)
            end;
        [] ->
            case grpcbox_channel:pick(LNS, stream) of
                {error, _} ->
                    %% No connection
                    Server = hpr_route:server(Route),
                    Host = hpr_route:host(Server),
                    Port = hpr_route:port(Server),
                    case
                        grpcbox_client:connect(LNS, [{http, Host, Port, []}], #{
                            sync_start => true
                        })
                    of
                        {ok, _Conn, _} ->
                            get_stream(Route);
                        {ok, _Conn} ->
                            get_stream(Route);
                        {error, _} = Error ->
                            Error
                    end;
                {ok, {_Conn, _Interceptor}} ->
                    case
                        helium_packet_router_packet_client:route(#{
                            channel => LNS,
                            callback_module => {
                                hpr_packet_router_downlink_handler,
                                hpr_packet_router_downlink_handler:new_state(LNS)
                            }
                        })
                    of
                        {error, _} = Error ->
                            Error;
                        {ok, Stream} = OK ->
                            true = ets:insert(?STREAM_ETS, {LNS, Stream}),
                            OK
                    end
            end
    end.

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
        ?_test(test_full())
    ]}.

foreach_setup() ->
    meck:new(grpcbox_channel),
    meck:new(grpcbox_client),
    ?MODULE:init(),
    ok.

foreach_cleanup(ok) ->
    true = ets:delete(?STREAM_ETS),
    meck:unload(grpcbox_channel),
    meck:unload(grpcbox_client),
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

    HprPacketUp = test_utils:join_packet_up(#{gateway => PubKeyBin}),
    ?assertEqual(ok, ?MODULE:send(HprPacketUp, Route)),

    LNS = hpr_route:lns(Route),
    ok = test_utils:wait_until(
        fun() ->
            [{LNS, Stream}] == ets:lookup(?STREAM_ETS, LNS)
        end
    ),
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
