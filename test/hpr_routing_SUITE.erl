-module(hpr_routing_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    join_req_test/1
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
        join_req_test
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

join_req_test(_Config) ->
    Self = self(),

    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Hotspot = libp2p_crypto:pubkey_to_bin(PubKey),

    PacketBadSig = test_utils:join_packet_up(#{
        hotspot => Hotspot, sig_fun => fun(_) -> <<"bad_sig">> end
    }),
    ?assertEqual({error, bad_signature}, hpr_routing:handle_packet(PacketBadSig, Self)),
    receive
        {error, bad_signature} -> ok;
        Other0 -> ct:fail(Other0)
    after 100 ->
        ct:fail("bad_signature, timeout")
    end,

    PacketUpInvalid = test_utils:join_packet_up(#{
        hotspot => Hotspot, sig_fun => SigFun, payload => <<>>
    }),
    ?assertEqual(
        {error, invalid_packet_type}, hpr_routing:handle_packet(PacketUpInvalid, Self)
    ),
    receive
        {error, invalid_packet_type} -> ok;
        Other1 -> ct:fail(Other1)
    after 100 ->
        ct:fail("invalid_packet_type, timeout")
    end,

    meck:new(hpr_protocol_router, [passthrough]),
    meck:expect(hpr_protocol_router, send, fun(_, _, _) -> ok end),

    {ok, NetID} = lora_subnet:parse_netid(16#00000000, big),
    Route = hpr_route:new(
        NetID,
        [{16#00000000, 16#0000000A}],
        [{1, 1}, {1, 2}],
        <<"127.0.0.1">>,
        router,
        1
    ),
    ok = hpr_routing_config_worker:insert(Route),

    PacketUpValid = test_utils:join_packet_up(#{
        hotspot => Hotspot, sig_fun => SigFun
    }),
    ?assertEqual(ok, hpr_routing:handle_packet(PacketUpValid, Self)),

    ?assertEqual(
        [
            {Self,
                {hpr_protocol_router, send, [
                    PacketUpValid,
                    Self,
                    Route
                ]},
                ok}
        ],
        meck:history(hpr_protocol_router)
    ),

    ?assert(meck:validate(hpr_protocol_router)),
    meck:unload(hpr_protocol_router),

    ok.
