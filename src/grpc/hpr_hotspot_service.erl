-module(hpr_hotspot_service).

-behaviour(helium_packet_router_hotspot_bhvr).

-include("../grpc/autogen/server/packet_router_pb.hrl").

-export([
    init/1,
    send_packet/2,
    handle_info/2
]).

-export([
    packet_up_to_push_data/2,
    route_to_dest/1,
    txpk_to_packet_down/1
]).

-spec init(Stream :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(Stream) ->
    Stream.

-spec send_packet(hpr_packet_up:packet(), grpcbox_stream:t()) ->
    ok
    | {ok, grpcbox_stream:t()}
    | {ok, packet_router_pb:packet_router_packet_down_v1_pb(), grpcbox_stream:t()}
    | {stop, grpcbox_stream:t()}
    | {stop, packet_router_pb:packet_router_packet_down_v1_pb(), grpcbox_stream:t()}
    | grpcbox_stream:grpc_error_response().
send_packet(PacketUp, Stream) ->
    Route = hpr_route:new(
        1337,
        [{0, 16#FFFF_FFFF}],
        [
            {
                erlang:list_to_integer("1000", 16),
                erlang:list_to_integer("9999", 16)
            }
        ],
        <<"127.0.0.1:1700">>,
        gwmp,
        42
    ),

    Hotspot = hpr_packet_up:hotspot(PacketUp),

    case hpr_gwmp_udp_sup:maybe_start_worker(Hotspot, #{protocol => route_to_dest(Route)}) of
        {error, Reason} ->
            throw({gwmp_sup_err, Reason});
        {ok, Pid} ->
            PushData = ?MODULE:packet_up_to_push_data(PacketUp, erlang:system_time(millisecond)),
            Dest = ?MODULE:route_to_dest(Route),
            try hpr_gwmp_client:push_data(Pid, PushData, Stream, Dest) of
                _ -> ok
            catch
                Type:Err:Stack ->
                    lager:error("sending err: ~p", [{Type, Err, Stack}])
            end
    end,

    {ok, Stream}.

-spec handle_info(Msg :: any(), Stream :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_Msg, Stream) ->
    Stream.

%% ===================================================================

-spec txpk_to_packet_down(TxPk :: map()) -> #packet_router_packet_down_v1_pb{}.
txpk_to_packet_down(Data) ->
    Map = maps:get(<<"txpk">>, semtech_udp:json_data(Data)),
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
    PubKeyBin = hpr_packet_up:hotspot(Up),
    MAC = hpr_gwmp_client:pubkeybin_to_mac(PubKeyBin),

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
                float_to_list(hpr_packet_up:frequency(Up), [{decimals, 4}, compact])
            ),
            rfch => 0,
            modu => <<"LORA">>,
            codr => <<"4/5">>,
            stat => 1,
            chan => 0,

            datr => erlang:list_to_binary(hpr_packet_up:datarate(Up)),
            rssi => erlang:trunc(hpr_packet_up:signal_strength(Up)),
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

-spec route_to_dest(hpr_route:route()) -> {Address :: string(), Port :: non_neg_integer()}.
route_to_dest(Route) ->
    Lns = hpr_route:lns(Route),
    case binary:split(Lns, <<":">>) of
        [Address, Port] ->
            {erlang:binary_to_list(Address), erlang:binary_to_integer(Port)};
        Err ->
            throw({route_to_dest_err, Err})
    end.
