-module(hpr_gwmp_router).

-include("../grpc/autogen/server/packet_router_pb.hrl").

-export([send/3]).

-export([
    packet_up_to_push_data/2,
    route_to_dest/1,
    txpk_to_packet_down/1
]).

-spec send(
    Packet :: hpr_packet_up:packet(),
    Stream :: pid(),
    Routes :: hpr_route:route()
) -> ok | {error, any()}.
send(PacketUp, Stream, Route) ->
    Gateway = hpr_packet_up:gateway(PacketUp),

    case hpr_gwmp_udp_sup:maybe_start_worker(Gateway, #{}) of
        {error, Reason} ->
            {error, {gwmp_sup_err, Reason}};
        {ok, Pid} ->
            PushData = ?MODULE:packet_up_to_push_data(PacketUp, erlang:system_time(millisecond)),
            Dest = ?MODULE:route_to_dest(Route),
            try hpr_gwmp_worker:push_data(Pid, PushData, Stream, Dest) of
                _ -> ok
            catch
                Type:Err:Stack ->
                    lager:error("sending err: ~p", [{Type, Err, Stack}]),
                    {error, {Type, Err}}
            end
    end.

%% ===================================================================
%% Internal
%% ===================================================================

-spec txpk_to_packet_down(TxPkBin :: binary()) -> #packet_router_packet_down_v1_pb{}.
txpk_to_packet_down(TxPkBin) ->
    TxPk = semtech_udp:json_data(TxPkBin),
    Map = maps:get(<<"txpk">>, TxPk),
    JSONData0 = base64:decode(maps:get(<<"data">>, Map)),

    Down = #packet_router_packet_down_v1_pb{
        payload = JSONData0,
        rx1 = #window_v1_pb{
            timestamp = maps:get(<<"tmst">>, Map),
            frequency = maps:get(<<"freq">>, Map),
            datarate = maps:get(<<"datr">>, Map)
        },
        %% TODO: rx2 windows
        rx2 = undefined
    },
    Down.

-spec packet_up_to_push_data(
    PacketUp :: hpr_packet_up:packet(),
    PacketTime :: non_neg_integer()
) ->
    {Token :: binary(), Payload :: binary()}.
packet_up_to_push_data(Up, GatewayTime) ->
    Token = semtech_udp:token(),
    PubKeyBin = hpr_packet_up:gateway(Up),
    MAC = hpr_gwmp_worker:pubkeybin_to_mac(PubKeyBin),

    %% TODO: Add back potential geo stuff
    %% CP breaks if {lati, long} are not parseable number

    Data = semtech_udp:push_data(
        Token,
        MAC,
        #{
            time => iso8601:format(
                calendar:system_time_to_universal_time(GatewayTime, millisecond)
            ),
            tmst => hpr_packet_up:timestamp(Up) band 16#FFFF_FFFF,
            freq => list_to_float(
                float_to_list(hpr_packet_up:frequency_mhz(Up), [{decimals, 4}, compact])
            ),
            rfch => 0,
            modu => <<"LORA">>,
            codr => <<"4/5">>,
            stat => 1,
            chan => 0,

            datr => erlang:atom_to_binary(hpr_packet_up:datarate(Up)),
            rssi => hpr_packet_up:rssi(Up),
            lsnr => hpr_packet_up:snr(Up),
            size => erlang:byte_size(hpr_packet_up:payload(Up)),
            data => base64:encode(hpr_packet_up:payload(Up))
        },
        #{
            regi => hpr_packet_up:region(Up),
            %% inde => Index,
            %% lati => Lat,
            %% long => Long,
            pubk => libp2p_crypto:bin_to_b58(PubKeyBin)
        }
    ),
    {Token, Data}.

-spec route_to_dest(binary() | hpr_route:route()) ->
    {Address :: string(), Port :: non_neg_integer()}.
route_to_dest(Route) when erlang:is_binary(Route) ->
    case binary:split(Route, <<":">>) of
        [Address, Port] ->
            {
                erlang:binary_to_list(Address),
                erlang:binary_to_integer(Port)
            };
        Err ->
            throw({route_to_dest_err, Err})
    end;
route_to_dest(Route) ->
    Lns = hpr_route:lns(Route),
    route_to_dest(Lns).
