-module(hpr_protocol_gwmp).

-export([send/4]).

-spec send(
    Packet :: hpr_packet_up:packet(),
    Route :: hpr_route:route(),
    Timestamp :: non_neg_integer(),
    GatewayLocation :: hpr_gateway_location:loc()
) -> ok | {error, any()}.
send(PacketUp, Route, Timestamp, GatewayLocation) ->
    Gateway = hpr_packet_up:gateway(PacketUp),
    case hpr_gwmp_sup:maybe_start_worker(Gateway, #{}) of
        {error, Reason} ->
            {error, {gwmp_sup_err, Reason}};
        {ok, Pid} ->
            Region = hpr_packet_up:region(PacketUp),
            Dest = hpr_route:gwmp_region_lns(Region, Route),
            try hpr_gwmp_worker:push_data(Pid, PacketUp, Dest, Timestamp, GatewayLocation) of
                _ -> ok
            catch
                Type:Err:Stack ->
                    lager:error("sending err: ~p", [{Type, Err, Stack}]),
                    {error, {Type, Err}}
            end
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
