-module(hpr_routing).

-export([
    init/0,
    handle_packet/2
]).

-define(GATEWAY_THROTTLE, hpr_routing_gateway_throttle).
-define(DEFAULT_GATEWAY_THROTTLE, 25).

-define(JOIN_REQUEST, 2#000).
-define(UNCONFIRMED_UP, 2#010).
-define(CONFIRMED_UP, 2#100).

-spec init() -> ok.
init() ->
    GatewayRateLimit = application:get_env(router, gateway_rate_limit, ?DEFAULT_GATEWAY_THROTTLE),
    ok = throttle:setup(?GATEWAY_THROTTLE, GatewayRateLimit, per_second),
    ok.

-spec handle_packet(
    Packet :: hpr_packet_up:packet(),
    StreamState :: grpcbox_stream:t()
) -> ok | {error, any()}.
handle_packet(Packet, StreamHandler) ->
    GatewayName = hpr_utils:gateway_name(hpr_packet_up:gateway(Packet)),
    lager:md([{gateway, GatewayName}, {phash, hpr_utils:bin_to_hex(hpr_packet_up:phash(Packet))}]),
    %% TODO: log some identifying information?
    lager:debug("received packet"),
    Checks = [
        {fun hpr_packet_up:verify/1, bad_signature},
        {fun throttle_check/1, gateway_limit_exceeded}
    ],
    case execute_checks(Packet, Checks) of
        {error, _Reason} = Error ->
            lager:error("packet failed verification: ~p", [_Reason]),
            Error;
        ok ->
            case packet_type(Packet) of
                undefined ->
                    lager:error("invalid packet type"),
                    {error, invalid_packet_type};
                {join_req, AppEUI, DevEUI} ->
                    Routes = hpr_routing_config_worker:lookup_eui(AppEUI, DevEUI),
                    lager:debug(
                        [
                            {app_eui, hpr_utils:int_to_hex(AppEUI)},
                            {dev_eui, hpr_utils:int_to_hex(DevEUI)}
                        ],
                        "handling join"
                    ),
                    ok = deliver_packet(Packet, StreamState, Routes);
                {uplink, DevAddr} ->
                    lager:debug(
                        [{devaddr, hpr_utils:int_to_hex(DevAddr)}],
                        "handling uplink"
                    ),
                    Routes = hpr_routing_config_worker:lookup_devaddr(DevAddr),
                    ok = deliver_packet(Packet, StreamState, Routes)
            end
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec deliver_packet(
    Packet :: hpr_packet_up:packet(),
    StreamState :: grpcbox_stream:t(),
    Routes :: [hpr_route:route()]
) -> ok.
deliver_packet(_Packet, _StreamHandler, []) ->
    ok;
deliver_packet(Packet, StreamState, [Route | Routes]) ->
    lager:debug(
        [
            {oui, hpr_route:oui(Route)},
            {protocol, hpr_route:protocol(Route)},
            {net_id, hpr_utils:int_to_hex(hpr_route:net_id(Route))}
        ],
        "delivering packet to ~s",
        [hpr_route:lns(Route)]
    ),
    Protocol = hpr_route:protocol(Route),
    %% FIXME: delivery could be halted to multiple routes if one of the earlier
    %% Protocol:send(...) errors out.
    Resp =
        case Protocol of
            router ->
                hpr_protocol_router:send(Packet, StreamState, Route);
            gwmp ->
                hpr_gwmp_router:send(Packet, StreamState, Route);
            _OtherProtocol ->
                lager:warning([{protocol, _OtherProtocol}], "unimplemented"),
                ok
        end,
    case Resp of
        ok ->
            ok;
        {error, Err} ->
            %% FIXME: might be dangerous to log full `Err` tuple right now
            lager:warning(
                [{protocol, Protocol}, {error, Err}],
                "error sending"
            ),
            ok
    end,
    deliver_packet(Packet, StreamState, Routes).

-spec throttle_check(Packet :: hpr_packet_up:packet()) -> boolean().
throttle_check(Packet) ->
    Gateway = hpr_packet_up:gateway(Packet),
    case throttle:check(?GATEWAY_THROTTLE, Gateway) of
        {limit_exceeded, _, _} -> false;
        _ -> true
    end.

-spec execute_checks(Packet :: hpr_packet_up:packet(), [{fun(), any()}]) -> ok | {error, any()}.
execute_checks(_Packet, []) ->
    ok;
execute_checks(Packet, [{Fun, ErrorReason} | Rest]) ->
    case Fun(Packet) of
        false ->
            {error, ErrorReason};
        true ->
            execute_checks(Packet, Rest)
    end.

-spec packet_type(Packet :: hpr_packet_up:packet()) ->
    {join_req, non_neg_integer(), non_neg_integer()} | {uplink, non_neg_integer()} | undefined.
packet_type(Packet) ->
    case hpr_packet_up:payload(Packet) of
        <<?JOIN_REQUEST:3, _:5, AppEUI:64/integer-unsigned-little,
            DevEUI:64/integer-unsigned-little, _DevNonce:2/binary, _MIC:4/binary>> ->
            {join_req, AppEUI, DevEUI};
        (<<FType:3, _:5, DevAddr:32/integer-unsigned-little, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1,
            FOptsLen:4, _FCnt:16/little-unsigned-integer, _FOpts:FOptsLen/binary,
            PayloadAndMIC/binary>>) when
            (FType == ?UNCONFIRMED_UP orelse FType == ?CONFIRMED_UP) andalso
                %% MIC is 4 bytes, so the binary must be at least that long
                erlang:byte_size(PayloadAndMIC) >= 4
        ->
            Body = binary:part(PayloadAndMIC, {0, byte_size(PayloadAndMIC) - 4}),
            {FPort, _FRMPayload} =
                case Body of
                    <<>> -> {undefined, <<>>};
                    <<Port:8, Payload/binary>> -> {Port, Payload}
                end,
            case FPort of
                0 when FOptsLen /= 0 ->
                    undefined;
                _ ->
                    {uplink, DevAddr}
            end;
        _ ->
            undefined
    end.
