-module(hpr_grpc_load_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    main_test/1,
    hpr_protocol_router_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        main_test,
        hpr_protocol_router_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(_TestCase, Config) ->
    FormatStr = [
        "[",
        date,
        " ",
        time,
        "] ",
        pid,
        " [",
        severity,
        "] [",
        {module, ""},
        {function, [":", function], ""},
        {line, [":", line], ""},
        "] ",
        message,
        "\n"
    ],
    ok = application:set_env(
        lager,
        handlers,
        [
            {lager_console_backend, [
                {level, debug},
                {formatter_config, FormatStr}
            ]}
        ]
    ),
    ok = application:set_env(lager, traces, [
        {lager_console_backend, [{application, grpcbox}], debug},
        {lager_console_backend, [{module, ?MODULE}], debug},
        {lager_console_backend, [{module, hpr_test_packet_router_service}], debug}
    ]),
    ok = application:set_env(lager, crash_log, "crash.log"),
    _ = application:ensure_all_started(lager),
    _ = application:ensure_all_started(grpcbox),
    _ = application:ensure_all_started(throttle),
    _ = application:ensure_all_started(backoff),

    Config.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, _Config) ->
    application:stop(lager),
    application:stop(grpcbox),
    application:stop(throttle),
    application:stop(backoff),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

main_test(_Config) ->
    lager:notice("STARTED", []),

    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_test_packet_router_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),

    Self = self(),

    application:set_env(
        hpr,
        packet_service_route_fun,
        fun(_Env, StreamState) ->
            Self ! {packet, _Env},
            {ok, StreamState}
        end
    ),

    application:set_env(
        hpr,
        packet_service_init_fun,
        fun(_Rpc, StreamState) ->
            Self ! init,
            StreamState
        end
    ),

    LNS = <<"stress_test">>,
    ChannelName = LNS,
    {ok, Channel} = grpcbox_client:connect(ChannelName, [{http, "localhost", 8083, []}], #{
        sync_start => true
    }),
    {links, [_, SubChannel]} = recon:info(Channel, links),
    {ok, StreamSet, _Info} = grpcbox_subchannel:conn(SubChannel),
    ConnPid = h2_stream_set:connection(StreamSet),

    timer:sleep(5000),

    % dbg:stop_clear(),
    dbg:start(),
    F = fun(Data, _Name) ->
        io:format("~p~n", [Data])
    end,
    dbg:tracer(process, {F, "Pierre Trace"}),

    dbg:p(ConnPid, [all]),
    _ = erlang:monitor(process, ConnPid, []),

    MaxHotspots = 60000,
    SendPacketSleep = timer:seconds(5),

    % Throttle = hotspot_connect,
    % ok = throttle:setup(Throttle, 1000, per_second),
    % Backoff0 = backoff:type(backoff:init(timer:seconds(1), timer:seconds(10)), normal),

    erlang:spawn(
        fun() ->
            lists:foreach(
                fun(_X) ->
                    erlang:spawn(fun() ->
                        #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(
                            ed25519
                        ),
                        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
                        SigFun = libp2p_crypto:mk_sig_fun(PrivKey),

                        timer:sleep(rand:uniform(2500)),

                        case
                            helium_packet_router_packet_client:route(#{
                                channel => ChannelName
                            })
                        of
                            {ok, Stream} ->
                                send_packet(SendPacketSleep, Stream, PubKeyBin, SigFun);
                            _Err ->
                                lager:error("failed to get a stream ~p", [_Err])
                        end
                    end)
                end,
                lists:seq(1, MaxHotspots)
            )
        end
    ),

    Sleep = 1000,
    erlang:spawn_link(fun() -> print_conn(ConnPid, Sleep) end),

    rcv_loop(0, 0),

    ok = gen_server:stop(ServerPid),
    ok.

hpr_protocol_router_test(_Config) ->
    lager:notice("STARTED", []),

    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_test_packet_router_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),

    Self = self(),

    application:set_env(
        hpr,
        packet_service_route_fun,
        fun(_Env, StreamState) ->
            Self ! {packet, _Env},
            {ok, StreamState}
        end
    ),

    application:set_env(
        hpr,
        packet_service_init_fun,
        fun(_Rpc, StreamState) ->
            Self ! init,
            StreamState
        end
    ),

    Route = hpr_route:test_new(#{
        id => "7d502f32-4d58-4746-965e-8c7dfdcfc624",
        net_id => 1,
        devaddr_ranges => [],
        euis => [],
        oui => 1,
        server => #{
            host => "localhost",
            port => 8082,
            protocol => {packet_router, #{}}
        },
        max_copies => 1,
        nonce => 1
    }),

    LNS = hpr_route:lns(Route),
    ChannelName = LNS,

    Endpoints = [{http, "localhost", 8082, []}],

    {ok, Channel} = grpcbox_client:connect(ChannelName, Endpoints, #{
        sync_start => true
    }),
    {links, [_, SubChannel | _]} = recon:info(Channel, links),
    {ok, StreamSet, _Info} = grpcbox_subchannel:conn(SubChannel),
    ConnPid = h2_stream_set:connection(StreamSet),

    timer:sleep(5000),

    % dbg:stop_clear(),
    dbg:start(),
    F = fun(Data, _Name) ->
        io:format("~p~n", [Data])
    end,
    dbg:tracer(process, {F, "Pierre Trace"}),

    dbg:p(ConnPid, [all]),
    _ = erlang:monitor(process, ConnPid, []),

    MaxHotspots = 80000,
    SendPacketSleep = timer:seconds(5),

    ok = hpr_protocol_router:init(),
    {ok, _} = hpr_protocol_router:start_link(#{}),

    erlang:spawn(
        fun() ->
            lists:foreach(
                fun(_X) ->
                    erlang:spawn(fun() ->
                        #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(
                            ed25519
                        ),
                        PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
                        SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
                        spawn_hotspot(SendPacketSleep, Route, PubKeyBin, SigFun)
                    end)
                end,
                lists:seq(1, MaxHotspots)
            )
        end
    ),

    Sleep = 1000,
    erlang:spawn_link(fun() -> print_conn(ConnPid, Sleep) end),

    rcv_loop(0, 0),

    ok = gen_server:stop(ServerPid),
    ok.

spawn_hotspot(SendPacketSleep, Route, PubKeyBin, SigFun) ->
    erlang:spawn(fun() ->
        ok = hpr_packet_router_service:register(PubKeyBin),
        % timer:sleep(rand:uniform(2500)),
        timer:sleep(10),
        _ = send_packet_via_protocol(SendPacketSleep, Route, PubKeyBin, SigFun, rand:uniform(250)),
        spawn_hotspot(SendPacketSleep, Route, PubKeyBin, SigFun)
    end).

% create_stream(Throttle, ChannelName, Backoff0) ->
%     case throttle:check(Throttle, ChannelName) of
%         {limit_exceeded, _, _} ->
%             {Delay, Backoff1} = backoff:fail(Backoff0),
%             % lager:error("limit_exceeded ~w", [Delay]),
%             timer:sleep(Delay),
%             create_stream(Throttle, ChannelName, Backoff1);
%         _ ->
%             % timer:sleep(rand:uniform(250)),
%             helium_packet_router_packet_client:route(#{
%                 channel => ChannelName
%             })
%     end.

send_packet(Sleep, Stream, PubKeyBin, SigFun) ->
    PacketUp = test_utils:uplink_packet_up(#{
        gateway => PubKeyBin,
        sig_fun => SigFun,
        devaddr => 16#00000000,
        data => crypto:strong_rand_bytes(16)
    }),
    EnvUp = hpr_envelope_up:new(PacketUp),
    grpcbox_client:send(Stream, EnvUp),
    timer:sleep(Sleep),
    send_packet(Sleep, Stream, PubKeyBin, SigFun).

send_packet_via_protocol(_Sleep, _Route, _PubKeyBin, _SigFun, 0) ->
    ok;
send_packet_via_protocol(Sleep, Route, PubKeyBin, SigFun, X) ->
    PacketUp = test_utils:uplink_packet_up(#{
        gateway => PubKeyBin,
        sig_fun => SigFun,
        devaddr => 16#00000000,
        data => crypto:strong_rand_bytes(16)
    }),

    timer:sleep(rand:uniform(2500)),

    hpr_protocol_router:send(PacketUp, Route),
    timer:sleep(Sleep),
    send_packet_via_protocol(Sleep, Route, PubKeyBin, SigFun, X - 1).

rcv_loop(P, I) ->
    receive
        {'DOWN', _Monitor, process, _Pid, _ExitReason} ->
            ct:fail("connection dead ~p ~p", [_Pid, _ExitReason]);
        init ->
            lager:info("INIT ~w", [I + 1]),
            rcv_loop(P, I + 1);
        {packet, _} ->
            % lager:info("packet ~w", [P + 1]),
            rcv_loop(P + 1, I)
    after 2000 ->
        lager:warning("NO packet", []),
        rcv_loop(P, I)
    end.

print_conn(ConnPid, Sleep) ->
    case erlang:is_process_alive(ConnPid) of
        true ->
            lager:notice("message_queue_len ~p", [
                element(2, recon:info(ConnPid, message_queue_len))
            ]),
            lager:notice("current_stacktrace ~p", [
                element(2, recon:info(ConnPid, current_stacktrace))
            ]),
            L = lists:filter(
                fun(M) ->
                    case M of
                        {'$gen_call', {_, _}, _} -> false;
                        {'$gen_cast', _} -> false;
                        _ -> true
                    end
                end,
                element(2, recon:info(ConnPid, messages))
            ),
            lager:notice("messages ~p~n~n", [L]),
            timer:sleep(Sleep),
            print_conn(ConnPid, Sleep);
        false ->
            ok
    end.
