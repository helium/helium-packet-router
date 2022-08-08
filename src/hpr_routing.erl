-module(hpr_routing).

-export([
    init/0,
    handle_packet/2
]).

-define(HOTSPOT_THROTTLE, hpr_routing_hotspot_throttle).
-define(DEFAULT_HOTSPOT_THROTTLE, 25).

-spec init() -> ok.
init() ->
    HotspotRateLimit = application:get_env(router, hotspot_rate_limit, ?DEFAULT_HOTSPOT_THROTTLE),
    ok = throttle:setup(?HOTSPOT_THROTTLE, HotspotRateLimit, per_second),
    ok.

-spec handle_packet(Packet :: hpr_packet_up:packet(), Pid :: pid()) -> ok | {error, any()}.
handle_packet(Packet, Pid) ->
    Checks = [
        {fun hpr_packet_up:verify/1, bad_signature},
        {fun throttle_check/1, hotspot_limit_exceeded}
    ],
    case execute_checks(Packet, Checks) of
        {error, _} = Error ->
            Pid ! Error,
            Error;
        ok ->
            ok
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec throttle_check(Packet :: hpr_packet_up:packet()) -> boolean().
throttle_check(Packet) ->
    Hotspot = hpr_packet_up:hotspot(Packet),
    case throttle:check(?HOTSPOT_THROTTLE, Hotspot) of
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
