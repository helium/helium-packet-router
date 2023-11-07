-module(hpr_packet_router_service_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    session_test/1,
    session_timeout_test/1
]).

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
        session_test,
        session_timeout_test
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

session_test(_Config) ->
    meck:new(hpr_routing, [passthrough]),
    meck:expect(hpr_routing, handle_packet, fun(Packet, Opts) ->
        case maps:get(session_key, Opts, undefined) of
            undefined ->
                hpr_packet_up:verify(Packet);
            SessionKey ->
                hpr_packet_up:verify(Packet, SessionKey)
        end
    end),

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

    ok = hpr_test_gateway:send_packet(GatewayPid, #{}),

    %% Waiting session negotiation to complete
    timer:sleep(1000),

    ok = hpr_test_gateway:send_packet(GatewayPid, #{}),

    ok = test_utils:wait_until(
        fun() ->
            2 == erlang:length(meck:history(hpr_routing))
        end
    ),

    Gateway = hpr_test_gateway:pubkey_bin(GatewayPid),

    [
        {_Pid1,
            {hpr_routing, handle_packet, [
                _PacketUp1,
                #{
                    session_key := SessionKey1,
                    gateway := Gateway1,
                    stream_pid := Pid1
                }
            ]},
            Verified1},
        {_Pid2,
            {hpr_routing, handle_packet, [
                _PacketUp2,
                #{
                    session_key := SessionKey2,
                    gateway := Gateway2,
                    stream_pid := Pid2
                }
            ]},
            Verified2}
    ] = meck:history(hpr_routing),

    ?assertEqual(undefined, SessionKey1),
    ?assertEqual(Gateway, Gateway1),
    ?assert(erlang:is_pid(Pid1)),
    ?assert(erlang:is_process_alive(Pid1)),
    ?assert(Verified1),

    ?assert(erlang:is_binary(SessionKey2)),
    ?assertEqual(Gateway, Gateway2),
    ?assert(erlang:is_pid(Pid2)),
    ?assert(erlang:is_process_alive(Pid2)),
    ?assert(Verified2),

    ?assert(meck:validate(hpr_routing)),
    meck:unload(hpr_routing),

    gen_server:stop(GatewayPid),

    ok.

session_timeout_test(_Config) ->
    RouteID = "8d502f32-4d58-4746-965e-8c7dfdcfc625",
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

    %% Normal test with session reset
    {ok, GatewayPid} = hpr_test_gateway:start(#{
        forward => self(),
        route => Route,
        eui_pairs => EUIPairs,
        devaddr_ranges => DevAddrRanges,
        ignore_session_offer => false
    }),

    {ok, _} = hpr_test_gateway:receive_session_init(GatewayPid, timer:seconds(1)),
    {error, timeout} = hpr_test_gateway:receive_stream_down(GatewayPid),

    SessionKey = hpr_test_gateway:session_key(GatewayPid),
    PubKeyBin = hpr_test_gateway:pubkey_bin(GatewayPid),
    {ok, Pid} = hpr_packet_router_service:locate(PubKeyBin),

    %% Checking that session keys are the same
    ?assertEqual(SessionKey, session_key_from_stream(Pid)),
    Pid ! session_kill,

    ok = hpr_test_gateway:receive_stream_down(GatewayPid),

    ok.

%% ===================================================================
%% Helpers
%% ===================================================================

session_key_from_stream(Pid) ->
    State = sys:get_state(Pid),
    StreamState = erlang:element(2, State),
    CallbackState = erlang:element(20, StreamState),
    HandlerState = erlang:element(3, CallbackState),
    erlang:element(5, HandlerState).
