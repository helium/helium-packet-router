-module(hpr_grpc_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    main_test/1,
    single_test/1,
    overload_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("../src/grpc/autogen/multi_buy_pb.hrl").

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
        single_test,
        overload_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

main_test(_Config) ->
    ChannelNameA = <<"A">>,
    {ok, ChannelA} = grpcbox_client:connect(ChannelNameA, [{http, "localhost", 6080, []}], #{
        sync_start => true
    }),
    {links, [_, SubChannelA]} = recon:info(ChannelA, links),
    {ok, ConnA, _} = grpcbox_subchannel:conn(SubChannelA),

    ChannelNameB = <<"B">>,
    {ok, ChannelB} = grpcbox_client:connect(ChannelNameB, [{http, "localhost", 6080, []}], #{
        sync_start => true
    }),
    {links, [_, SubChannelB]} = recon:info(ChannelB, links),
    {ok, ConnB, _} = grpcbox_subchannel:conn(SubChannelB),

    Self = self(),

    erlang:spawn(
        fun() ->
            lists:foreach(
                fun(X) ->
                    case X rem 2 == 0 of
                        true ->
                            erlang:spawn(
                                fun() ->
                                    Req =
                                        #multi_buy_inc_req_v1_pb{
                                            key =
                                                hpr_utils:bin_to_hex_string(
                                                    crypto:strong_rand_bytes(16)
                                                )
                                        },
                                    case
                                        helium_multi_buy_multi_buy_client:inc(Req, #{
                                            channel => ChannelNameA
                                        })
                                    of
                                        {ok, #multi_buy_inc_res_v1_pb{count = Count}, _} ->
                                            {ok, Count};
                                        _Any ->
                                            Self ! {error, _Any},
                                            {error, _Any}
                                    end
                                end
                            );
                        false ->
                            erlang:spawn(
                                fun() ->
                                    Req =
                                        #multi_buy_inc_req_v1_pb{
                                            key =
                                                hpr_utils:bin_to_hex_string(
                                                    crypto:strong_rand_bytes(16)
                                                )
                                        },
                                    case
                                        helium_multi_buy_multi_buy_client:inc(Req, #{
                                            channel => ChannelNameB
                                        })
                                    of
                                        {ok, #multi_buy_inc_res_v1_pb{count = Count}, _} ->
                                            {ok, Count};
                                        _Any ->
                                            Self ! {error, _Any},
                                            {error, _Any}
                                    end
                                end
                            )
                    end
                end,
                lists:seq(1, 10000)
            )
        end
    ),

    lists:foreach(
        fun(_) ->
            ct:pal("Conn A ~p~n", [recon:info(ConnA, message_queue_len)]),
            ct:pal("Conn B ~p~n", [recon:info(ConnB, message_queue_len)]),
            timer:sleep(500)
        end,
        lists:seq(1, 20)
    ),

    receive
        Any ->
            ?assertEqual(none, Any)
    after 1000 ->
        ok
    end,
    ok.

single_test(_Config) ->
    ChannelNameA = <<"C">>,
    {ok, ChannelA} = grpcbox_client:connect(ChannelNameA, [{http, "localhost", 6080, []}], #{
        sync_start => true
    }),
    {links, [_, SubChannelA]} = recon:info(ChannelA, links),
    {ok, ConnA, _} = grpcbox_subchannel:conn(SubChannelA),

    Self = self(),

    erlang:spawn(
        fun() ->
            lists:foreach(
                fun(_X) ->
                    erlang:spawn(
                        fun() ->
                            Req =
                                #multi_buy_inc_req_v1_pb{
                                    key =
                                        hpr_utils:bin_to_hex_string(
                                            crypto:strong_rand_bytes(16)
                                        )
                                },
                            case
                                helium_multi_buy_multi_buy_client:inc(Req, #{
                                    channel => ChannelNameA
                                })
                            of
                                {ok, #multi_buy_inc_res_v1_pb{count = Count}, _} ->
                                    {ok, Count};
                                _Any ->
                                    Self ! {error, _Any},
                                    {error, _Any}
                            end
                        end
                    )
                end,
                lists:seq(1, 10000)
            )
        end
    ),

    lists:foreach(
        fun(_) ->
            ct:pal("Conn A ~p~n", [recon:info(ConnA, message_queue_len)]),
            timer:sleep(100)
        end,
        lists:seq(1, 100)
    ),

    ?assertEqual(0, rcv_error(0)),
    ok.

overload_test(_Config) ->
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_test_packet_router_service}
        },
        listen_opts => #{port => 8082, ip => {0, 0, 0, 0}}
    }),

    %% Interceptor
    Self = self(),
    %% Queue up a downlink from the testing server
    EnvDown = hpr_envelope_down:new(
        hpr_packet_down:new_downlink(
            base64:encode(<<"H3P3N2i9qc4yt7rK7ldqoeCVJGBybzPY5h1Dd7P7p8v">>),
            erlang:system_time(millisecond) band 16#FFFF_FFFF,
            904_100_000,
            'SF11BW125'
        )
    ),
    application:set_env(
        hpr,
        test_packet_router_service_route,
        fun(Env, StreamState) ->
            {packet, Packet} = hpr_envelope_up:data(Env),
            Self ! {packet_up, Packet},
            {ok, EnvDown, StreamState}
        end
    ),

    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ed25519),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),

    LNS = <<"http://localhost:8082">>,
    ChannelName = LNS,
    {ok, Channel} = grpcbox_client:connect(ChannelName, [{http, "localhost", 8082, []}], #{
        sync_start => true
    }),
    {links, [_, SubChannel]} = recon:info(Channel, links),
    {ok, Conn, _} = grpcbox_subchannel:conn(SubChannel),

    {ok, Stream} = helium_packet_router_packet_client:route(#{
        channel => ChannelName
    }),

    erlang:spawn(
        fun() ->
            lists:foreach(
                fun(_X) ->
                    erlang:spawn(fun() ->
                        PacketUp = test_utils:uplink_packet_up(#{
                            gateway => PubKeyBin,
                            sig_fun => SigFun,
                            devaddr => 16#00000000,
                            data => crypto:strong_rand_bytes(16)
                        }),
                        EnvUp = hpr_envelope_up:new(PacketUp),
                        grpcbox_client:send(Stream, EnvUp)
                    end)
                end,
                lists:seq(1, 100000)
            )
        end
    ),

    Self = self(),

    lists:foreach(
        fun(_) ->
            ct:pal("~p~n", [recon:info(Conn, message_queue_len)]),
            case recon:info(Conn, messages) of
                {messages, [M | _]} ->
                    ct:pal("~p~n", [M]);
                _ ->
                    ok
            end,
            timer:sleep(100)
        end,
        lists:seq(1, 100)
    ),

    ok = gen_server:stop(ServerPid),
    ?assert(false),
    ok.

rcv_error(C) ->
    receive
        {error, _Any} ->
            rcv_error(C + 1)
    after 2000 ->
        C
    end.
