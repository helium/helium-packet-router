-module(hpr_protocol_gwmp).

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

    case hpr_gwmp_sup:maybe_start_worker(Gateway, #{}) of
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

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec txpk_to_packet_down(TxPkBin :: binary()) -> hpr_packet_down:packet().
txpk_to_packet_down(TxPkBin) ->
    TxPk = semtech_udp:json_data(TxPkBin),
    Map = maps:get(<<"txpk">>, TxPk),
    JSONData0 = base64:decode(maps:get(<<"data">>, Map)),
    hpr_packet_down:to_record(#{
        payload => JSONData0,
        rx1 => #{
            timestamp => maps:get(<<"tmst">>, Map),
            frequency => erlang:round(maps:get(<<"freq">>, Map) * 1_000_000),
            datarate => erlang:binary_to_existing_atom(maps:get(<<"datr">>, Map))
        },
        %% No rx2 windows for udp
        rx2 => undefined
    }).

-spec packet_up_to_push_data(
    PacketUp :: hpr_packet_up:packet(),
    PacketTime :: non_neg_integer()
) ->
    {Token :: binary(), Payload :: binary()}.
packet_up_to_push_data(Up, GatewayTime) ->
    Token = semtech_udp:token(),
    PubKeyBin = hpr_packet_up:gateway(Up),
    MAC = hpr_utils:pubkeybin_to_mac(PubKeyBin),

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

%% ------------------------------------------------------------------
% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

verify_downlink_test() ->
    %% Taken from actual gwmp reply
    TxPkBin =
        <<2, 211, 238, 3, 123, 34, 116, 120, 112, 107, 34, 58, 123, 34, 105, 109, 109, 101, 34, 58,
            102, 97, 108, 115, 101, 44, 34, 114, 102, 99, 104, 34, 58, 48, 44, 34, 112, 111, 119,
            101, 34, 58, 50, 48, 44, 34, 97, 110, 116, 34, 58, 48, 44, 34, 98, 114, 100, 34, 58, 48,
            44, 34, 116, 109, 115, 116, 34, 58, 53, 54, 54, 53, 53, 56, 51, 44, 34, 102, 114, 101,
            113, 34, 58, 57, 50, 55, 46, 53, 44, 34, 109, 111, 100, 117, 34, 58, 34, 76, 79, 82, 65,
            34, 44, 34, 100, 97, 116, 114, 34, 58, 34, 83, 70, 49, 48, 66, 87, 53, 48, 48, 34, 44,
            34, 99, 111, 100, 114, 34, 58, 34, 52, 47, 53, 34, 44, 34, 105, 112, 111, 108, 34, 58,
            116, 114, 117, 101, 44, 34, 115, 105, 122, 101, 34, 58, 51, 51, 44, 34, 100, 97, 116,
            97, 34, 58, 34, 73, 77, 97, 69, 53, 90, 98, 71, 121, 65, 79, 75, 117, 110, 68, 101, 49,
            50, 85, 85, 48, 89, 100, 57, 54, 72, 78, 106, 85, 115, 114, 121, 115, 82, 55, 86, 107,
            69, 118, 75, 70, 86, 88, 79, 34, 125, 125>>,

    Downlink = ?MODULE:txpk_to_packet_down(TxPkBin),
    ?assertEqual(ok, packet_router_pb:verify_msg(Downlink)),

    ok.

-endif.
