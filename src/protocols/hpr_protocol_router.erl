-module(hpr_protocol_router).

-export([send/4]).

-spec send(
    PacketUp :: hpr_packet_up:packet(),
    GatewayStream :: hpr_router_stream_manager:gateway_stream(),
    Route :: hpr_route:route(),
    RoutingInfo :: hpr_routing:routing_info()
) -> ok | {error, any()}.
send(PacketUp, GatewayStream, Route, _RoutingInfo) ->
    LNS = hpr_route:lns(Route),
    case hpr_router_stream_manager:get_stream(GatewayStream, LNS) of
        {ok, RouterStream} ->
            PacketUpMap = hpr_packet_up:to_map(PacketUp),
            ok = grpc_client:send(RouterStream, PacketUpMap);
        {error, _} = Err ->
            Err
    end.

%% ------------------------------------------------------------------
% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

basic_test_() ->
    [
        {foreach, fun per_testcase_setup/0, fun per_testcase_cleanup/1, [
            ?_test(test_send())
        ]}
    ].

per_testcase_setup() ->
    meck:new(hpr_router_stream_manager),
    meck:new(grpc_client),
    ok.

per_testcase_cleanup(ok) ->
    meck:unload(hpr_router_stream_manager),
    meck:unload(grpc_client).

% send/3: happy path
test_send() ->
    HprPacketUp = test_utils:join_packet_up(#{}),
    HprPacketUpMap = hpr_packet_up:to_map(HprPacketUp),
    Stream = self(),
    GatewayStream = self(),
    Host = <<"example-lns.com">>,
    Port = 4321,
    Route = hpr_route:new(
        #{
            net_id => 1,
            devaddr_ranges => [],
            euis => [],
            oui => 1,
            server => #{
                host => Host,
                port => Port,
                protocol => {packet_router, #{}}
            }
        }
    ),

    meck:expect(
        hpr_router_stream_manager,
        get_stream,
        [GatewayStream, <<Host/binary, ":", (integer_to_binary(Port))/binary>>],
        {ok, Stream}
    ),
    meck:expect(grpc_client, send, [Stream, HprPacketUpMap], ok),

    ResponseValue = send(HprPacketUp, Stream, Route, ignore),

    ?assertEqual(ok, ResponseValue),
    ?assertEqual(1, meck:num_calls(hpr_router_stream_manager, get_stream, 2)),
    ?assertEqual(1, meck:num_calls(grpc_client, send, 2)).

-endif.
