-module(hpr_protocol_router_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    grpc_test/1
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
        grpc_test
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

grpc_test(_Config) ->
    _PacketUp =
        {packet_router_packet_up_v1_pb,
            <<0, 55, 148, 187, 74, 220, 108, 33, 11, 133, 65, 148, 104, 147, 177, 26, 124, 43, 169,
                155, 182, 228, 95>>,
            552140, 0, 904.7000122070312, 'SF10BW125', 5.5, 'US915', 0,
            <<1, 131, 45, 83, 233, 204, 91, 71, 221, 213, 157, 129, 213, 219, 31, 62, 233, 186, 49,
                28, 183, 141, 0, 52, 52, 175, 168, 41, 37, 8, 230, 89, 83>>,
            <<192, 249, 98, 190, 86, 74, 255, 124, 33, 190, 95, 141, 9, 173, 111, 180, 97, 42, 203,
                136, 11, 36, 144, 4, 128, 6, 190, 253, 153, 99, 3, 180, 161, 76, 88, 90, 106, 200,
                160, 115, 22, 81, 211, 37, 134, 14, 8, 99, 226, 1, 172, 157, 67, 170, 203, 246, 21,
                250, 191, 236, 93, 230, 221, 9>>},

    _Route =
        {packet_router_route_v1_pb, 12582995,
            [{packet_router_route_devaddr_range_v1_pb, 0, 4294967295}],
            [{packet_router_route_eui_v1_pb, 802041902051071031, 8942655256770396549}],
            <<"127.0.0.1:8082">>, router, 4020},

    ?assertMatch(
        {ok, _ServerPid},
        grpcbox:start_server(#{
            grpc_opts => #{
                service_protos => [packet_router_pb],
                services => #{'helium.packet_router.gateway' => test_hpr_gateway_service}
            },
            listen_opts => #{
                port => 8082,
                ip => {0, 0, 0, 0}
            }
        })
    ),

    Self = self(),
    application:set_env(
        hpr,
        gateway_service_send_packet_fun,
        fun(Packet, Socket) ->
            Self ! {test_send_packet, Packet},
            Socket
        end
    ),

    ok = hpr_protocol_router:send(_PacketUp, self(), _Route),

    ok =
        receive
            {test_send_packet, _Packet} -> ?assertEqual(_Packet, _PacketUp)
        after timer:seconds(2) -> ct:fail(no_msg_rcvd)
        end,

    ok.
