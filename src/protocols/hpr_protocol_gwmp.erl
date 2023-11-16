-module(hpr_protocol_gwmp).

-export([send/3]).

-spec send(
    Packet :: hpr_packet_up:packet(),
    Route :: hpr_route:route(),
    GatewayLocation :: {h3:index(), float(), float()} | undefined
) -> ok | {error, any()}.
send(PacketUp, Route, _GatewayLocation) ->
    Gateway = hpr_packet_up:gateway(PacketUp),
    case hpr_gwmp_sup:maybe_start_worker(Gateway, #{}) of
        {error, Reason} ->
            {error, {gwmp_sup_err, Reason}};
        {ok, Pid} ->
            Region = hpr_packet_up:region(PacketUp),
            Dest = hpr_route:gwmp_region_lns(Region, Route),
            try hpr_gwmp_worker:push_data(Pid, PacketUp, Dest) of
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
