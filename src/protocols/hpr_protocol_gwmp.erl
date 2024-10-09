-module(hpr_protocol_gwmp).

-export([send/4]).

-spec send(
    Packet :: hpr_packet_up:packet(),
    Route :: hpr_route:route(),
    Timestamp :: non_neg_integer(),
    GatewayLocation :: hpr_gateway_location:loc()
) -> ok | {error, any()}.
send(PacketUp, Route, Timestamp, GatewayLocation) ->
    send(PacketUp, Route, Timestamp, GatewayLocation, 3).

-spec send(
    Packet :: hpr_packet_up:packet(),
    Route :: hpr_route:route(),
    Timestamp :: non_neg_integer(),
    GatewayLocation :: hpr_gateway_location:loc(),
    Retry :: non_neg_integer()
) -> ok | {error, any()}.
send(_PacketUp, _Route, _Timestamp, _GatewayLocation, 0) ->
    {error, {gwmp_sup_err, max_retries}};
send(PacketUp, Route, Timestamp, GatewayLocation, Retry) ->
    Gateway = hpr_packet_up:gateway(PacketUp),
    Key = {?MODULE, Gateway},
    case hpr_gwmp_sup:maybe_start_worker(#{key => Key, pubkeybin => Gateway}) of
        {error, Reason} ->
            {error, {gwmp_sup_err, Reason}};
        % This should only happen when a hotspot connects and spams us with
        % mutliple packets for same LNS
        {ok, undefined} ->
            timer:sleep(2),
            send(PacketUp, Route, Timestamp, GatewayLocation, Retry - 1);
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
