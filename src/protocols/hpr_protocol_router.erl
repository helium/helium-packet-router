-module(hpr_protocol_router).

-export([send/3]).

-spec send(
    PacketUp :: hpr_packet_up:packet(),
    GatewayStream :: hpr_router_stream_manager:gateway_stream(),
    Route :: hpr_route:route()
) -> ok | {error, any()}.
send(PacketUp, GatewayStream, Route) ->
    LNS = hpr_route:lns(Route),
    case hpr_router_stream_manager:get_stream(GatewayStream, LNS) of
        {ok, RouterStream} ->
            Env = hpr_envelope_up:new(PacketUp),
            EnvMap = hpr_envelope_up:to_map(Env),
            ok = grpc_client:send(RouterStream, EnvMap);
        {error, _} = Err ->
            Err
    end.

%% ------------------------------------------------------------------
%% EUnit tests
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
    EnvMap = hpr_envelope_up:to_map(hpr_envelope_up:new(HprPacketUp)),
    Stream = self(),
    GatewayStream = self(),
    Host = <<"example-lns.com">>,
    Port = 4321,
    Route = hpr_route:new(#{
        id => <<"7d502f32-4d58-4746-965e-8c7dfdcfc624">>,
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
    }),

    meck:expect(
        hpr_router_stream_manager,
        get_stream,
        [GatewayStream, <<Host/binary, ":", (integer_to_binary(Port))/binary>>],
        {ok, Stream}
    ),
    meck:expect(grpc_client, send, [Stream, EnvMap], ok),

    ResponseValue = send(HprPacketUp, Stream, Route),

    ?assertEqual(ok, ResponseValue),
    ?assertEqual(1, meck:num_calls(hpr_router_stream_manager, get_stream, 2)),
    ?assertEqual(1, meck:num_calls(grpc_client, send, 2)).

-endif.
