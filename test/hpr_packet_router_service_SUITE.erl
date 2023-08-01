-module(hpr_packet_router_service_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    session_test/1
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
        session_test
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
    meck:expect(hpr_routing, handle_packet, fun(Packet, SessionKey) ->
        case SessionKey of
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

    timer:sleep(1000),

    ok = hpr_test_gateway:send_packet(GatewayPid, #{}),

    ok = test_utils:wait_until(
        fun() ->
            2 == erlang:length(meck:history(hpr_routing))
        end
    ),

    [
        {_Pid1,
            {hpr_routing, handle_packet, [
                _PacketUp1,
                SessionKey1
            ]},
            Verified1},
        {_Pid2,
            {hpr_routing, handle_packet, [
                _PacketUp2,
                SessionKey2
            ]},
            Verified2}
    ] = meck:history(hpr_routing),
    ?assertEqual(undefined, SessionKey1),
    ?assert(Verified1),
    ?assert(erlang:is_binary(SessionKey2)),
    ?assert(Verified2),

    ?assert(meck:validate(hpr_routing)),
    meck:unload(hpr_routing),

    ok.

%% ===================================================================
%% Helpers
%% ===================================================================
