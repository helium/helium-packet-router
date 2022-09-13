-module(hpr_router_client_manager).

%% NOTE: this file is for illustrative purposes

init_ets() ->
    client_manager_ets = ets:new(client_manager_ets, [public, named_table, set]),
    ok.

get_stream(IncomingStream, LNS) ->
    case ets:lookup(client_manager_ets, IncomingStream) of
        [] ->
            Connection = grpc_client:connect(Transport, Host, Port, []),
            {ok, OutgoingStream} = grpc_client:new_stream(
                Connection,
                'helium.packet_router.gateway',
                send_packet,
                client_packet_router_pb
            ),
            ets:insert(client_manager_ets, {IncomingStream, OutgoingStream}),
            ListenPid = spawn(
                fun Recur() ->
                    IncomingStream ! {reply, grpc_client:rcv(OutgoingStream)},
                    Recur()
                end
            )
    end,

    ok.
