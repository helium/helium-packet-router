-module(hpr_routing_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/multi_buy_pb.hrl").
-include("hpr.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    gateway_limit_exceeded_test/1,
    packet_limit_exceeded_test/1,
    invalid_packet_type_test/1,
    wrong_gateway_test/1,
    bad_signature_test/1,
    mic_check_test/1,
    skf_max_copies_test/1,
    multi_buy_without_service_test/1,
    multi_buy_with_service_test/1,
    multi_buy_requests_test/1,
    active_locked_route_test/1,
    in_cooldown_route_test/1,
    success_test/1,
    no_routes_test/1,
    maybe_report_packet_test/1,
    find_route_load_test/1,
    routing_cleanup_test/1
]).

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
        gateway_limit_exceeded_test,
        packet_limit_exceeded_test,
        invalid_packet_type_test,
        wrong_gateway_test,
        bad_signature_test,
        mic_check_test,
        skf_max_copies_test,
        multi_buy_without_service_test,
        multi_buy_with_service_test,
        multi_buy_requests_test,
        active_locked_route_test,
        in_cooldown_route_test,
        success_test,
        no_routes_test,
        maybe_report_packet_test,
        find_route_load_test,
        routing_cleanup_test
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

gateway_limit_exceeded_test(_Config) ->
    %% Limit is DEFAULT_GATEWAY_THROTTLE = 25 per second
    Limit = 25,
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),
    Self = self(),
    lists:foreach(
        fun(I) ->
            erlang:spawn(
                fun() ->
                    PacketUpValid = test_utils:uplink_packet_up(#{
                        gateway => Gateway, sig_fun => SigFun, fcnt => I
                    }),
                    R = hpr_routing:handle_packet(PacketUpValid, #{gateway => Gateway}),
                    Self ! {gateway_limit_exceeded_test, R}
                end
            )
        end,
        lists:seq(1, Limit + 1)
    ),
    ?assertEqual({25, 1}, receive_gateway_limit_exceeded_test({0, 0})),
    ok.

packet_limit_exceeded_test(_Config) ->
    %% Limit is DEFAULT_PACKET_THROTTLE = 1 per second
    Limit = 1,
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),
    PacketUpValid = test_utils:uplink_packet_up(#{
        gateway => Gateway, sig_fun => SigFun, fcnt => 0
    }),
    Self = self(),
    lists:foreach(
        fun(_) ->
            erlang:spawn(
                fun() ->
                    %% We send the same packet
                    R = hpr_routing:handle_packet(PacketUpValid, #{gateway => Gateway}),
                    Self ! {packet_limit_exceeded_test, R}
                end
            )
        end,
        lists:seq(1, Limit + 1)
    ),
    ?assertEqual({1, 1}, receive_packet_limit_exceeded_test({0, 0})),
    ok.

invalid_packet_type_test(_Config) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),
    JoinPacketUpInvalid = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => SigFun, payload => <<>>
    }),
    ?assertEqual(
        {error, invalid_packet_type},
        hpr_routing:handle_packet(JoinPacketUpInvalid, #{gateway => Gateway})
    ),
    ok.

wrong_gateway_test(_Config) ->
    #{public := PubKey1} = libp2p_crypto:generate_keys(ed25519),
    Gateway1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    #{public := PubKey2} = libp2p_crypto:generate_keys(ed25519),
    Gateway2 = libp2p_crypto:pubkey_to_bin(PubKey2),

    JoinPacketBadSig = test_utils:join_packet_up(#{
        gateway => Gateway1, sig_fun => fun(_) -> <<"bad_sig">> end
    }),
    ?assertEqual(
        {error, wrong_gateway}, hpr_routing:handle_packet(JoinPacketBadSig, #{gateway => Gateway2})
    ),
    ok.

bad_signature_test(_Config) ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),

    JoinPacketBadSig = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => fun(_) -> <<"bad_sig">> end
    }),
    ?assertEqual(
        {error, bad_signature}, hpr_routing:handle_packet(JoinPacketBadSig, #{gateway => Gateway})
    ),
    ok.

mic_check_test(_Config) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),
    DevAddr = 16#00000001,

    PacketUp = fun(FCnt) ->
        test_utils:uplink_packet_up(#{
            app_session_key => AppSessionKey,
            nwk_session_key => NwkSessionKey,
            devaddr => DevAddr,
            gateway => Gateway,
            sig_fun => SigFun,
            fcnt => FCnt
        })
    end,

    %% TEST 1: Join always works
    JoinPacketUpValid = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => SigFun
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(JoinPacketUpValid, #{gateway => Gateway})),

    %% TEST 2:  No SFK for devaddr
    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp(0), #{gateway => Gateway})),

    %% TEST 3: Bad key and route exist
    Route = hpr_route:test_new(#{
        id => "11ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 10
    }),
    RouteID = hpr_route:id(Route),
    ?assertEqual(ok, hpr_route_ets:insert_route(Route)),

    DevAddrRange = hpr_devaddr_range:test_new(#{
        route_id => RouteID, start_addr => DevAddr, end_addr => 16#00000010
    }),
    ok = hpr_route_ets:insert_devaddr_range(DevAddrRange),

    BadSessionKey = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SKFBadKeyAndRouteExitst = hpr_skf:new(#{
        route_id => RouteID,
        devaddr => DevAddr,
        session_key => BadSessionKey,
        max_copies => 1
    }),
    hpr_route_ets:insert_skf(SKFBadKeyAndRouteExitst),

    ok = test_utils:wait_until(
        fun() ->
            case hpr_route_ets:lookup_route(RouteID) of
                [RouteETS] ->
                    ETS = hpr_route_ets:skf_ets(RouteETS),
                    1 =:= ets:info(ETS, size);
                _ ->
                    false
            end
        end
    ),

    ?assertEqual(
        {error, invalid_mic}, hpr_routing:handle_packet(PacketUp(1), #{gateway => Gateway})
    ),

    ok = hpr_route_ets:delete_skf(SKFBadKeyAndRouteExitst),

    %% TEST 4: Good key and route exist
    %% We leave old route inserted and do not delete good skf for next test

    SKFGoodKeyAndRouteExitst = hpr_skf:new(#{
        route_id => RouteID,
        devaddr => DevAddr,
        session_key => hpr_utils:bin_to_hex_string(NwkSessionKey),
        max_copies => 1
    }),
    hpr_route_ets:insert_skf(SKFGoodKeyAndRouteExitst),

    ok = test_utils:wait_until(
        fun() ->
            case hpr_route_ets:lookup_route(RouteID) of
                [RouteETS] ->
                    ETS = hpr_route_ets:skf_ets(RouteETS),
                    1 =:= ets:info(ETS, size);
                _ ->
                    false
            end
        end
    ),

    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp(2), #{gateway => Gateway})),

    %% TEST 5:  Good key and route exist
    %% Adding a bad key to make sure it still works

    SKFBadKey = hpr_skf:new(#{
        route_id => RouteID,
        devaddr => DevAddr,
        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
        max_copies => 1
    }),
    hpr_route_ets:insert_skf(SKFBadKey),

    ok = test_utils:wait_until(
        fun() ->
            case hpr_route_ets:lookup_route(RouteID) of
                [RouteETS] ->
                    ETS = hpr_route_ets:skf_ets(RouteETS),
                    2 =:= ets:info(ETS, size);
                _ ->
                    false
            end
        end
    ),

    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp(3), #{gateway => Gateway})),

    ok.

skf_max_copies_test(_Config) ->
    meck:new(hpr_protocol_http_roaming, [passthrough]),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),
    DevAddr = 16#00000001,

    Route = hpr_route:test_new(#{
        id => "11ea6dfd-3dce-4106-8980-d34007ab689b",
        net_id => 0,
        oui => 1,
        server => #{
            host => "lns1.testdomain.com",
            port => 80,
            protocol => {http_roaming, #{}}
        },
        max_copies => 1
    }),
    RouteID = hpr_route:id(Route),
    ?assertEqual(ok, hpr_route_ets:insert_route(Route)),

    DevAddrRange = hpr_devaddr_range:test_new(#{
        route_id => RouteID, start_addr => 16#00000000, end_addr => 16#0000000A
    }),
    ?assertEqual(ok, hpr_route_ets:insert_devaddr_range(DevAddrRange)),

    SKF = hpr_skf:new(#{
        route_id => RouteID,
        devaddr => DevAddr,
        session_key => hpr_utils:bin_to_hex_string(NwkSessionKey),
        max_copies => 3
    }),
    ?assertEqual(ok, hpr_route_ets:insert_skf(SKF)),

    ok = test_utils:wait_until(
        fun() ->
            case hpr_route_ets:lookup_route(RouteID) of
                [RouteETS] ->
                    ETS = hpr_route_ets:skf_ets(RouteETS),
                    1 =:= ets:info(ETS, size);
                _ ->
                    false
            end
        end
    ),

    lists:foreach(
        fun(_) ->
            #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
            SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            Gateway = libp2p_crypto:pubkey_to_bin(PubKey),
            PacketUp = test_utils:uplink_packet_up(#{
                app_session_key => AppSessionKey,
                nwk_session_key => NwkSessionKey,
                devaddr => DevAddr,
                gateway => Gateway,
                sig_fun => SigFun
            }),
            ?assertEqual(ok, hpr_routing:handle_packet(PacketUp, #{gateway => Gateway}))
        end,
        lists:seq(1, 3)
    ),

    ?assertEqual(3, meck:num_calls(hpr_protocol_http_roaming, send, 2)),

    lists:foreach(
        fun(_) ->
            #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
            SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            Gateway = libp2p_crypto:pubkey_to_bin(PubKey),
            PacketUp = test_utils:uplink_packet_up(#{
                app_session_key => AppSessionKey,
                nwk_session_key => NwkSessionKey,
                devaddr => DevAddr,
                gateway => Gateway,
                sig_fun => SigFun
            }),
            ?assertEqual(ok, hpr_routing:handle_packet(PacketUp, #{gateway => Gateway}))
        end,
        lists:seq(1, 3)
    ),

    ?assertEqual(3, meck:num_calls(hpr_protocol_http_roaming, send, 2)),

    meck:unload(hpr_protocol_http_roaming),
    ok.

multi_buy_without_service_test(_Config) ->
    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    meck:new(hpr_packet_reporter, [passthrough]),
    meck:expect(hpr_packet_reporter, report_packet, fun(_, _, _, _) -> ok end),

    application:set_env(
        hpr,
        test_multi_buy_service_inc,
        fun(_Ctx, _Req) ->
            {grpc_error, {<<"12">>, <<"UNIMPLEMENTED">>}}
        end
    ),

    MaxCopies = 2,
    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => MaxCopies
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 1
        }),
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 2
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        })
    ],
    ok = hpr_route_ets:insert_route(Route),
    ok = lists:foreach(fun hpr_route_ets:insert_eui_pair/1, EUIPairs),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, DevAddrRanges),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),

    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ed25519),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),
    Gateway1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    UplinkPacketUp1 = test_utils:uplink_packet_up(#{
        gateway => Gateway1,
        sig_fun => SigFun1,
        devaddr => DevAddr,
        fcnt => 1,
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey
    }),

    #{secret := PrivKey2, public := PubKey2} = libp2p_crypto:generate_keys(ed25519),
    SigFun2 = libp2p_crypto:mk_sig_fun(PrivKey2),
    Gateway2 = libp2p_crypto:pubkey_to_bin(PubKey2),

    UplinkPacketUp2 = test_utils:uplink_packet_up(#{
        gateway => Gateway2,
        sig_fun => SigFun2,
        devaddr => DevAddr,
        fcnt => 1,
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey
    }),

    #{secret := PrivKey3, public := PubKey3} = libp2p_crypto:generate_keys(ed25519),
    SigFun3 = libp2p_crypto:mk_sig_fun(PrivKey3),
    Gateway3 = libp2p_crypto:pubkey_to_bin(PubKey3),

    UplinkPacketUp3 = test_utils:uplink_packet_up(#{
        gateway => Gateway3,
        sig_fun => SigFun3,
        devaddr => DevAddr,
        fcnt => 1,
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey
    }),

    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp1, #{gateway => Gateway1})),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp2, #{gateway => Gateway2})),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp3, #{gateway => Gateway3})),

    Self = self(),
    Received1 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp1,
                Route
            ]},
            ok},
    Received2 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp2,
                Route
            ]},
            ok},

    ?assertEqual([Received1, Received2], meck:history(hpr_protocol_router)),

    UplinkPacketUp4 = test_utils:uplink_packet_up(#{
        gateway => Gateway3,
        sig_fun => SigFun3,
        devaddr => DevAddr,
        fcnt => 2,
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey
    }),

    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp4, #{gateway => Gateway3})),

    Received3 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp4,
                Route
            ]},
            ok},

    ?assertEqual([Received1, Received2, Received3], meck:history(hpr_protocol_router)),

    %% Checking that packet got reported free
    [
        {_, {hpr_packet_reporter, report_packet, [_, _, IsFree1, _]}, _},
        {_, {hpr_packet_reporter, report_packet, [_, _, IsFree2, _]}, _},
        {_, {hpr_packet_reporter, report_packet, [_, _, IsFree3, _]}, _}
    ] = meck:history(
        hpr_packet_reporter
    ),
    ?assert(IsFree1),
    ?assert(IsFree2),
    ?assert(IsFree3),
    %% We sent 2 packets fnt 1 and 2
    ?assertEqual(2, ets:info(hpr_multi_buy_ets, size)),

    application:unset_env(hpr, test_multi_buy_service_inc),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),
    ?assert(meck:validate(hpr_packet_reporter)),
    meck:unload(hpr_packet_reporter),

    ok.

multi_buy_with_service_test(_Config) ->
    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    meck:new(hpr_packet_reporter, [passthrough]),
    meck:expect(hpr_packet_reporter, report_packet, fun(_, _, _, _) -> ok end),

    MaxCopies = 2,
    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => MaxCopies
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 1
        }),
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 2
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        })
    ],
    ok = hpr_route_ets:insert_route(Route),
    ok = lists:foreach(fun hpr_route_ets:insert_eui_pair/1, EUIPairs),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, DevAddrRanges),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),

    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ed25519),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),
    Gateway1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    UplinkPacketUp1 = test_utils:uplink_packet_up(#{
        gateway => Gateway1,
        sig_fun => SigFun1,
        devaddr => DevAddr,
        fcnt => 1,
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey
    }),

    #{secret := PrivKey2, public := PubKey2} = libp2p_crypto:generate_keys(ed25519),
    SigFun2 = libp2p_crypto:mk_sig_fun(PrivKey2),
    Gateway2 = libp2p_crypto:pubkey_to_bin(PubKey2),

    UplinkPacketUp2 = test_utils:uplink_packet_up(#{
        gateway => Gateway2,
        sig_fun => SigFun2,
        devaddr => DevAddr,
        fcnt => 1,
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey
    }),

    #{secret := PrivKey3, public := PubKey3} = libp2p_crypto:generate_keys(ed25519),
    SigFun3 = libp2p_crypto:mk_sig_fun(PrivKey3),
    Gateway3 = libp2p_crypto:pubkey_to_bin(PubKey3),

    UplinkPacketUp3 = test_utils:uplink_packet_up(#{
        gateway => Gateway3,
        sig_fun => SigFun3,
        devaddr => DevAddr,
        fcnt => 1,
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey
    }),

    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp1, #{gateway => Gateway1})),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp2, #{gateway => Gateway2})),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp3, #{gateway => Gateway3})),

    Self = self(),
    Received1 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp1,
                Route
            ]},
            ok},
    Received2 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp2,
                Route
            ]},
            ok},

    ?assertEqual([Received1, Received2], meck:history(hpr_protocol_router)),

    UplinkPacketUp4 = test_utils:uplink_packet_up(#{
        gateway => Gateway3,
        sig_fun => SigFun3,
        devaddr => DevAddr,
        fcnt => 2,
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey
    }),

    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp4, #{gateway => Gateway3})),

    Received3 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp4,
                Route
            ]},
            ok},

    ?assertEqual([Received1, Received2, Received3], meck:history(hpr_protocol_router)),

    %% Checking that packet dit not get reported free
    [
        {_, {hpr_packet_reporter, report_packet, [_, _, IsFree1, _]}, _},
        {_, {hpr_packet_reporter, report_packet, [_, _, IsFree2, _]}, _},
        {_, {hpr_packet_reporter, report_packet, [_, _, IsFree3, _]}, _}
    ] = meck:history(
        hpr_packet_reporter
    ),
    ?assertNot(IsFree1),
    ?assertNot(IsFree2),
    ?assertNot(IsFree3),
    %% We sent 2 packets fnt 1 and 2
    ?assertEqual(2, ets:info(hpr_multi_buy_ets, size)),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),
    ?assert(meck:validate(hpr_packet_reporter)),
    meck:unload(hpr_packet_reporter),
    ok.

multi_buy_requests_test(_Config) ->
    ETS = ets:new(multi_buy_requests_test, [
        public,
        set,
        {write_concurrency, true}
    ]),

    meck:new(hpr_multi_buy, [passthrough]),
    meck:new(helium_multi_buy_multi_buy_client, [passthrough]),
    %% By adding +2 here we simulate other servers also incrementing
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(#multi_buy_inc_req_v1_pb{key = Key}, _) ->
        Count = ets:update_counter(
            ETS, Key, {2, 2}, {default, 0}
        ),
        {ok, #multi_buy_inc_res_v1_pb{count = Count}, []}
    end),

    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    MaxCopies = 3,
    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => MaxCopies
    }),
    DevAddrRange =
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        }),
    ok = hpr_route_ets:insert_route(Route),
    ok = hpr_route_ets:insert_devaddr_range(DevAddrRange),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),

    Keys = lists:map(
        fun(_) ->
            #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
            {libp2p_crypto:pubkey_to_bin(PubKey), libp2p_crypto:mk_sig_fun(PrivKey)}
        end,
        lists:seq(1, 10)
    ),

    Packets1 = lists:map(
        fun({Gateway, SigFun}) ->
            test_utils:uplink_packet_up(#{
                gateway => Gateway,
                sig_fun => SigFun,
                devaddr => DevAddr,
                fcnt => 1,
                app_session_key => AppSessionKey,
                nwk_session_key => NwkSessionKey
            })
        end,
        Keys
    ),

    lists:foreach(
        fun(Packet) ->
            erlang:spawn(hpr_routing, handle_packet, [
                Packet,
                #{
                    gateway => hpr_packet_up:gateway(Packet)
                }
            ])
        end,
        Packets1
    ),

    MultiBuyKey = hpr_multi_buy:make_key(hd(Packets1), Route),
    %% We should stop making requests when the multi-buy service says it's seen
    %% more than the MaxCopies. When we've sent more update_counter than
    %% MaxCopies, we can check that we haven't exceeded MaxCopies worth of
    %% requests because this tests is simulating other HPR seeing the same packet.
    ok = test_utils:wait_until(fun() ->
        UpdatesRequested = meck:num_calls(hpr_multi_buy, update_counter, [MultiBuyKey, MaxCopies]),
        RequestsSent = meck:num_calls(helium_multi_buy_multi_buy_client, inc, 2),
        Headroom = 2,

        UpdatesRequested > (MaxCopies + Headroom) andalso RequestsSent =< MaxCopies
    end),

    Key = key,
    meck:reset(helium_multi_buy_multi_buy_client),
    meck:expect(helium_multi_buy_multi_buy_client, inc, fun(_, _) ->
        Count = ets:update_counter(
            ETS, Key, {2, 1}, {default, 0}
        ),
        {ok, #multi_buy_inc_res_v1_pb{count = Count}, []}
    end),

    Packets2 = lists:map(
        fun({Gateway, SigFun}) ->
            test_utils:uplink_packet_up(#{
                gateway => Gateway,
                sig_fun => SigFun,
                devaddr => DevAddr,
                fcnt => 2,
                app_session_key => AppSessionKey,
                nwk_session_key => NwkSessionKey
            })
        end,
        Keys
    ),

    ?assertEqual(
        ok,
        hpr_routing:handle_packet(lists:nth(1, Packets2), #{
            gateway => hpr_packet_up:gateway(lists:nth(1, Packets2))
        })
    ),
    %% We update counter (from another LNS)
    ?assertEqual(2, ets:update_counter(ETS, Key, {2, 1}, {default, 0})),
    ?assertEqual(
        ok,
        hpr_routing:handle_packet(lists:nth(2, Packets2), #{
            gateway => hpr_packet_up:gateway(lists:nth(2, Packets2))
        })
    ),
    %% We update counter (from another LNS)
    ?assertEqual(4, ets:update_counter(ETS, Key, {2, 1}, {default, 0})),
    %% This should be the last time we make anothe request to get latest count
    ?assertEqual(
        ok,
        hpr_routing:handle_packet(lists:nth(3, Packets2), #{
            gateway => hpr_packet_up:gateway(lists:nth(3, Packets2))
        })
    ),
    ?assertEqual(
        ok,
        hpr_routing:handle_packet(lists:nth(4, Packets2), #{
            gateway => hpr_packet_up:gateway(lists:nth(4, Packets2))
        })
    ),
    ?assertEqual(
        ok,
        hpr_routing:handle_packet(lists:nth(5, Packets2), #{
            gateway => hpr_packet_up:gateway(lists:nth(5, Packets2))
        })
    ),

    ?assertEqual(3, meck:num_calls(helium_multi_buy_multi_buy_client, inc, 2)),

    ?assert(meck:validate(helium_multi_buy_multi_buy_client)),
    meck:unload(helium_multi_buy_multi_buy_client),
    meck:unload(hpr_protocol_router),
    meck:unload(hpr_multi_buy),
    ets:delete(ETS),
    ok.

active_locked_route_test(_Config) ->
    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route1 = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 999,
        active => true,
        locked => false
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 1
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        })
    ],
    ok = hpr_route_ets:insert_route(Route1),
    ok = lists:foreach(fun hpr_route_ets:insert_eui_pair/1, EUIPairs),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, DevAddrRanges),

    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),

    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ed25519),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),
    Gateway1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    PacketUp = fun(FCnt) ->
        test_utils:uplink_packet_up(#{
            gateway => Gateway1,
            sig_fun => SigFun1,
            devaddr => DevAddr,
            fcnt => FCnt,
            app_session_key => AppSessionKey,
            nwk_session_key => NwkSessionKey
        })
    end,

    PacketUp0 = PacketUp(0),

    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp0, #{gateway => Gateway1})),

    Self = self(),
    Received1 =
        {Self,
            {hpr_protocol_router, send, [
                PacketUp0,
                Route1
            ]},
            ok},

    ?assertEqual([Received1], meck:history(hpr_protocol_router)),
    ok = meck:reset(hpr_protocol_router),

    Route2 = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 999,
        active => false,
        locked => false
    }),
    ok = hpr_route_ets:insert_route(Route2),
    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp(1), #{gateway => Gateway1})),

    ?assertEqual([], meck:history(hpr_protocol_router)),

    Route3 = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 999,
        active => true,
        locked => true
    }),
    ok = hpr_route_ets:insert_route(Route3),
    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp(2), #{gateway => Gateway1})),

    ?assertEqual([], meck:history(hpr_protocol_router)),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),
    ok.

in_cooldown_route_test(_Config) ->
    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 999,
        active => true,
        locked => false
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 1
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        })
    ],
    ok = hpr_route_ets:insert_route(Route),
    ok = lists:foreach(fun hpr_route_ets:insert_eui_pair/1, EUIPairs),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, DevAddrRanges),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),

    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ed25519),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),
    Gateway1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    PacketUp = fun(FCnt) ->
        test_utils:uplink_packet_up(#{
            gateway => Gateway1,
            sig_fun => SigFun1,
            devaddr => DevAddr,
            fcnt => FCnt,
            app_session_key => AppSessionKey,
            nwk_session_key => NwkSessionKey
        })
    end,

    %% We setup protocol router to fail every call
    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> {error, not_implemented} end),

    %% We send first packet a call should be made to hpr_protocol_router
    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp(0), #{gateway => Gateway1})),
    ?assertEqual(1, meck:num_calls(hpr_protocol_router, send, 2)),
    %% We send second packet NO call should be made to hpr_protocol_router as the route would be in cooldown
    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp(1), #{gateway => Gateway1})),
    ?assertEqual(1, meck:num_calls(hpr_protocol_router, send, 2)),

    %% We wait the initial first timeout 1s
    %% Send another packet and watch another call made to hpr_protocol_router
    timer:sleep(1000),
    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp(2), #{gateway => Gateway1})),
    ?assertEqual(2, meck:num_calls(hpr_protocol_router, send, 2)),

    %% We send couple more packets and check that we still only 2 calls to hpr_protocol_router
    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp(3), #{gateway => Gateway1})),
    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp(4), #{gateway => Gateway1})),
    ?assertEqual(2, meck:num_calls(hpr_protocol_router, send, 2)),

    %% We check the route and make sure that the backoff is setup properly
    [RouteETS1] = hpr_route_ets:lookup_route(RouteID),
    {Timestamp1, Backoff1} = hpr_route_ets:backoff(RouteETS1),
    ?assert(Timestamp1 > erlang:system_time(millisecond)),
    ?assertEqual(2000, backoff:get(Backoff1)),

    %% Wait another time out (2s now) and reset hpr_protocol_router to return ok
    timer:sleep(2000),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),
    %% Sending another packet should trigger a new call to hpr_protocol_router
    ?assertEqual(ok, hpr_routing:handle_packet(PacketUp(5), #{gateway => Gateway1})),
    ?assertEqual(3, meck:num_calls(hpr_protocol_router, send, 2)),

    %% The route backoff should be back to undefined
    [RouteETS2] = hpr_route_ets:lookup_route(RouteID),
    ?assertEqual(undefined, hpr_route_ets:backoff(RouteETS2)),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),
    ok.

success_test(_Config) ->
    Self = self(),
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),

    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 1
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 1
        }),
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 2
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        })
    ],
    ok = hpr_route_ets:insert_route(Route),
    ok = lists:foreach(fun hpr_route_ets:insert_eui_pair/1, EUIPairs),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, DevAddrRanges),

    JoinPacketUpValid = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => SigFun
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(JoinPacketUpValid, #{gateway => Gateway})),

    Received1 =
        {Self,
            {hpr_protocol_router, send, [
                JoinPacketUpValid,
                Route
            ]},
            ok},
    ?assertEqual([Received1], meck:history(hpr_protocol_router)),

    UplinkPacketUp = test_utils:uplink_packet_up(#{
        gateway => Gateway, sig_fun => SigFun, devaddr => DevAddr
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp, #{gateway => Gateway})),

    Received2 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp,
                Route
            ]},
            ok},
    ?assertEqual(
        [
            Received1,
            Received2
        ],
        meck:history(hpr_protocol_router)
    ),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),
    ok.

no_routes_test(_Config) ->
    ok = meck:new(hpr_packet_reporter, [passthrough]),
    ok = meck:expect(hpr_packet_reporter, report_packet, 4, ok),

    Port1 = 8180,
    Port2 = 8280,
    application:set_env(
        ?APP,
        no_routes,
        [{"localhost", Port1}, {"127.0.0.1", erlang:integer_to_list(Port2)}],
        [{persistent, true}]
    ),
    %% Startup no route servers
    {ok, ServerPid1} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_test_packet_router_service}
        },
        listen_opts => #{port => Port1, ip => {0, 0, 0, 0}}
    }),
    {ok, ServerPid2} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [packet_router_pb],
            services => #{'helium.packet_router.packet' => hpr_test_packet_router_service}
        },
        listen_opts => #{port => Port2, ip => {0, 0, 0, 0}}
    }),

    %% Interceptor
    Self = self(),
    application:set_env(
        hpr,
        test_packet_router_service_route,
        fun(Env, StreamState) ->
            {packet, Packet} = hpr_envelope_up:data(Env),
            Self ! {packet_up, Packet},
            StreamState
        end
    ),

    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => 0,
        oui => 4020,
        server => #{
            host => "127.0.0.1",
            port => 8082,
            protocol => {packet_router, #{}}
        },
        max_copies => 2
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 802041902051071031, dev_eui => 8942655256770396549
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#00000010
        })
    ],
    {ok, GatewayPid} = hpr_test_gateway:start(#{
        forward => self(), route => Route, eui_pairs => EUIPairs, devaddr_ranges => DevAddrRanges
    }),

    %% Send packet and route directly through interface
    ok = hpr_test_gateway:send_packet(GatewayPid, #{devaddr => 16#FFFFFFFF}),

    PacketUp =
        case hpr_test_gateway:receive_send_packet(GatewayPid) of
            {ok, EnvUp} ->
                {packet, PUp} = hpr_envelope_up:data(EnvUp),
                PUp;
            {error, timeout} ->
                ct:fail(receive_send_packet)
        end,

    ok =
        receive
            {packet_up, RvcPacketUp0} -> ?assertEqual(RvcPacketUp0, PacketUp)
        after timer:seconds(2) -> ct:fail(no_msg_rcvd)
        end,

    ok =
        receive
            {packet_up, RvcPacketUp1} -> ?assertEqual(RvcPacketUp1, PacketUp)
        after timer:seconds(2) -> ct:fail(no_msg_rcvd)
        end,

    ok = gen_server:stop(GatewayPid),
    ok = gen_server:stop(ServerPid1),
    ok = gen_server:stop(ServerPid2),

    %% Ensure packets sent to no_routes do not get reported.
    ?assertEqual(0, meck:num_calls(hpr_packet_reporter, report_packet, 4)),
    meck:unload(hpr_packet_reporter),

    application:set_env(
        ?APP,
        no_routes,
        [],
        [{persistent, true}]
    ),
    ok.

maybe_report_packet_test(_Config) ->
    Self = self(),
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),

    meck:new(hpr_protocol_router, [passthrough]),
    meck:new(hpr_packet_reporter, [passthrough]),

    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 1
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 1
        }),
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 2
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        })
    ],
    ok = hpr_route_ets:insert_route(Route),
    ok = lists:foreach(fun hpr_route_ets:insert_eui_pair/1, EUIPairs),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, DevAddrRanges),

    JoinPacketUpValid = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => SigFun
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(JoinPacketUpValid, #{gateway => Gateway})),

    Received1 =
        {Self,
            {hpr_protocol_router, send, [
                JoinPacketUpValid,
                Route
            ]},
            ok},
    ?assertEqual([Received1], meck:history(hpr_protocol_router)),

    UplinkPacketUp1 = test_utils:uplink_packet_up(#{
        gateway => Gateway, sig_fun => SigFun, devaddr => DevAddr, fcnt => 1
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp1, #{gateway => Gateway})),

    Received2 =
        {Self,
            {hpr_protocol_router, send, [
                UplinkPacketUp1,
                Route
            ]},
            ok},
    ?assertEqual(
        [
            Received1,
            Received2
        ],
        meck:history(hpr_protocol_router)
    ),

    ?assertEqual(2, meck:num_calls(hpr_packet_reporter, report_packet, 4)),

    ok = meck:reset(hpr_packet_reporter),

    %% We are adding a route with diff OUI but same dev ranges (This should not be allowed by CS)
    BadRouteID = "11502f32-4d58-4746-965e-8c7dfdcfc624",
    BadRoute = hpr_route:test_new(#{
        id => BadRouteID,
        net_id => NetID,
        oui => 2,
        server => #{
            host => "localhost",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 1
    }),
    BadDevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => BadRouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        })
    ],
    ok = hpr_route_ets:insert_route(BadRoute),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, BadDevAddrRanges),

    UplinkPacketUp2 = test_utils:uplink_packet_up(#{
        gateway => Gateway, sig_fun => SigFun, devaddr => DevAddr, fcnt => 2
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp2, #{gateway => Gateway})),

    CallExpected3 =
        {hpr_protocol_router, send, [
            UplinkPacketUp2,
            BadRoute
        ]},
    CallExpected4 =
        {hpr_protocol_router, send, [
            UplinkPacketUp2,
            Route
        ]},

    %% Packet is still send to both Routes
    [
        History1,
        History2,
        {Pid3, Call3, Result3},
        {Pid4, Call4, Result4}
    ] = meck:history(hpr_protocol_router),

    ?assertEqual(Received1, History1),
    ?assertEqual(Received2, History2),
    ?assert(erlang:is_pid(Pid3)),
    ?assert(erlang:is_pid(Pid4)),
    %% Order can be messed up due to spanwing
    ?assert(CallExpected3 == Call3 orelse CallExpected3 == Call4),
    ?assert(CallExpected4 == Call3 orelse CallExpected4 == Call4),
    ?assertEqual(ok, Result3),
    ?assertEqual(ok, Result4),

    %% But no report is done
    ?assertEqual(0, meck:num_calls(hpr_packet_reporter, report_packet, 4)),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),
    ?assert(meck:validate(hpr_packet_reporter)),
    meck:unload(hpr_packet_reporter),
    ok.

find_route_load_test(_Config) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),

    AppSessionKey = crypto:strong_rand_bytes(16),
    NwkSessionKey = crypto:strong_rand_bytes(16),
    DevAddr = 16#00000001,
    PacketUp = test_utils:uplink_packet_up(#{
        app_session_key => AppSessionKey,
        nwk_session_key => NwkSessionKey,
        devaddr => DevAddr,
        gateway => Gateway,
        sig_fun => SigFun
    }),
    PacketType = hpr_packet_up:type(PacketUp),

    Route1ID = "route_1",
    Route1 = hpr_route:test_new(#{
        id => Route1ID,
        net_id => 1,
        oui => 10,
        server => #{
            host => "lsn.lora.com",
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1,
        active => true,
        locked => false
    }),
    ok = hpr_route_ets:insert_route(Route1),

    DevAddrRange1 = hpr_devaddr_range:test_new(#{
        route_id => Route1ID, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_route_ets:insert_devaddr_range(DevAddrRange1),

    SKF1 = hpr_skf:new(#{
        route_id => Route1ID,
        devaddr => DevAddr,
        session_key => hpr_utils:bin_to_hex_string(NwkSessionKey),
        max_copies => 1
    }),
    hpr_route_ets:insert_skf(SKF1),

    {Time1, Result1} = timer:tc(hpr_routing, find_routes, [PacketType, PacketUp]),
    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, {Time1, Result1}]),

    [RouteETS1] = hpr_route_ets:lookup_route(Route1ID),
    SKFETS1 = hpr_route_ets:skf_ets(RouteETS1),

    timer:sleep(2000),
    Now = erlang:system_time(millisecond),
    lists:foreach(
        fun(_) ->
            erlang:spawn(
                fun() ->
                    TempSKF = hpr_skf:new(#{
                        route_id => Route1ID,
                        devaddr => DevAddr,
                        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
                        max_copies => 1
                    }),
                    hpr_route_ets:insert_skf(TempSKF)
                end
            )
        end,
        lists:seq(1, 9999)
    ),

    ok = test_utils:wait_until(
        fun() ->
            case 10000 =:= ets:info(SKFETS1, size) of
                true ->
                    Then = erlang:system_time(millisecond),
                    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Then - Now]),
                    true;
                _ ->
                    false
            end
        end
    ),

    {Time2, Result2} = timer:tc(hpr_routing, find_routes, [PacketType, PacketUp]),
    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, {Time2, Result2}]),

    timer:sleep(1000),

    {Time3, Result3} = timer:tc(hpr_routing, find_routes, [PacketType, PacketUp]),
    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, {Time3, Result3}]),

    Route2ID = "route_2",
    Route2 = hpr_route:test_new(#{
        id => Route2ID,
        net_id => 1,
        oui => 10,
        server => #{
            host => "lsn.lora.com",
            port => 80,
            protocol => {gwmp, #{mapping => []}}
        },
        max_copies => 1,
        active => true,
        locked => false
    }),
    ok = hpr_route_ets:insert_route(Route2),

    DevAddrRange2 = hpr_devaddr_range:test_new(#{
        route_id => Route2ID, start_addr => 16#00000000, end_addr => 16#00000002
    }),
    ok = hpr_route_ets:insert_devaddr_range(DevAddrRange2),

    SKF2 = hpr_skf:new(#{
        route_id => Route2ID,
        devaddr => DevAddr,
        session_key => hpr_utils:bin_to_hex_string(NwkSessionKey),
        max_copies => 1
    }),
    hpr_route_ets:insert_skf(SKF2),

    [RouteETS2] = hpr_route_ets:lookup_route(Route2ID),
    SKFETS2 = hpr_route_ets:skf_ets(RouteETS2),
    timer:sleep(10),
    lists:foreach(
        fun(_) ->
            erlang:spawn(
                fun() ->
                    TempSKF = hpr_skf:new(#{
                        route_id => Route2ID,
                        devaddr => DevAddr,
                        session_key => hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
                        max_copies => 1
                    }),
                    hpr_route_ets:insert_skf(TempSKF)
                end
            )
        end,
        lists:seq(1, 9999)
    ),

    ok = test_utils:wait_until(
        fun() ->
            10000 =:= ets:info(SKFETS2, size)
        end
    ),

    {Time4, Result4} = timer:tc(hpr_routing, find_routes, [PacketType, PacketUp]),
    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, {Time4, Result4}]),

    ct:pal("[~p:~p:~p] MARKER ~p~n", [
        ?MODULE, ?FUNCTION_NAME, ?LINE, hpr_route_ets:lookup_devaddr_range(DevAddr)
    ]),

    % ?assert(false),
    ok.

routing_cleanup_test(_Config) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Gateway = libp2p_crypto:pubkey_to_bin(PubKey),

    CleanupPid0 = hpr_routing:get_crawl_routing_pid(),

    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _) -> ok end),

    DevAddr = 16#00000000,
    {ok, NetID} = lora_subnet:parse_netid(DevAddr, big),
    RouteID = "7d502f32-4d58-4746-965e-8c7dfdcfc624",
    Route = hpr_route:test_new(#{
        id => RouteID,
        net_id => NetID,
        oui => 1,
        server => #{
            host => "127.0.0.1",
            port => 80,
            protocol => {packet_router, #{}}
        },
        max_copies => 1
    }),
    EUIPairs = [
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 1
        }),
        hpr_eui_pair:test_new(#{
            route_id => RouteID, app_eui => 1, dev_eui => 2
        })
    ],
    DevAddrRanges = [
        hpr_devaddr_range:test_new(#{
            route_id => RouteID, start_addr => 16#00000000, end_addr => 16#0000000A
        })
    ],
    ok = hpr_route_ets:insert_route(Route),
    ok = lists:foreach(fun hpr_route_ets:insert_eui_pair/1, EUIPairs),
    ok = lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, DevAddrRanges),

    JoinPacketUpValid = test_utils:join_packet_up(#{
        gateway => Gateway, sig_fun => SigFun
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(JoinPacketUpValid, #{gateway => Gateway})),

    UplinkPacketUp = test_utils:uplink_packet_up(#{
        gateway => Gateway, sig_fun => SigFun, devaddr => DevAddr
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(UplinkPacketUp, #{gateway => Gateway})),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),

    %% 2 unique packets sent so far
    ?assertEqual(2, ets:info(hpr_packet_routing_ets, size)),

    %% wait cleanup to happen one last time.
    Waiting = 2 * hpr_utils:get_env_int(routing_cleanup_window_secs, 0),
    timer:sleep(timer:seconds(Waiting)),

    %% Packets have been cleaned out
    ?assertEqual(0, ets:info(hpr_packet_routing_ets, size)),
    CleanupPid1 = hpr_routing:get_crawl_routing_pid(),

    %% Cleanup has been run and different Pid resides.
    ?assertNotEqual(CleanupPid0, CleanupPid1),

    ok.

%% ===================================================================
%% Helpers
%% ===================================================================

-spec receive_gateway_limit_exceeded_test(Acc :: {non_neg_integer(), non_neg_integer()}) ->
    {non_neg_integer(), non_neg_integer()}.
receive_gateway_limit_exceeded_test({OK, Error} = Acc) ->
    receive
        {gateway_limit_exceeded_test, {error, gateway_limit_exceeded}} ->
            receive_gateway_limit_exceeded_test({OK, Error + 1});
        {gateway_limit_exceeded_test, ok} ->
            receive_gateway_limit_exceeded_test({OK + 1, Error})
    after 100 ->
        Acc
    end.

-spec receive_packet_limit_exceeded_test(Acc :: {non_neg_integer(), non_neg_integer()}) ->
    {non_neg_integer(), non_neg_integer()}.
receive_packet_limit_exceeded_test({OK, Error} = Acc) ->
    receive
        {packet_limit_exceeded_test, {error, packet_limit_exceeded}} ->
            receive_packet_limit_exceeded_test({OK, Error + 1});
        {packet_limit_exceeded_test, ok} ->
            receive_packet_limit_exceeded_test({OK + 1, Error})
    after 100 ->
        Acc
    end.
