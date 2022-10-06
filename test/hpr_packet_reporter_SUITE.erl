-module(hpr_packet_reporter_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    upload_report_test/1,
    upload_window_test/1
]).

-include("hpr.hrl").
-include("../src/grpc/autogen/server/packet_router_pb.hrl").
-include("../src/grpc/autogen/server/config_pb.hrl").

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-record(state, {
    aws_client :: aws_client:aws_client(),
    write_dir :: string(),
    file_path :: string(),
    max_file_size :: non_neg_integer(),
    report_interval :: timer:tref() | undefined,
    interval_duration :: non_neg_integer() | undefined,
    upload_window :: non_neg_integer(),
    upload_window_start_time :: non_neg_integer(),
    bucket :: binary()
}).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        upload_report_test,
        upload_window_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    Config1 = test_utils:init_per_testcase(TestCase, Config),
    meck:new(aws_s3, [passthrough]),
    meck:new(hpr_packet_reporter, [passthrough]),

    Config1.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    ets:delete_all_objects(hpr_packet_report_ets),
    meck:unload(),

    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

upload_report_test(_Config) ->
    State = sys:get_state(hpr_packet_reporter),
    #state{file_path = FilePath, aws_client = AWSClient, bucket = Bucket} = State,

    Packet = test_utils:join_packet_up(#{}),
    Packet2 = test_utils:uplink_packet_up(#{}),
    Route = test_utils:packet_route(#{}),

    %% Reported packets are encoded and saved to ETS
    hpr_packet_reporter:report_packet(Packet, Route),
    hpr_packet_reporter:report_packet(Packet2, Route),

    ETSValues = ets:tab2list(hpr_packet_report_ets),
    ?assertEqual(2, length(ETSValues)),
    [P1, P2] = lists:map(
        fun({_, P}) ->
            P
        end,
        ETSValues
    ),
    verify_packet(Packet, Route, P1),
    verify_packet(Packet2, Route, P2),

    %% Encoded packets are written to a tmp write file
    hpr_packet_reporter:handle_cast(write_packets, State),

    %% Contents of tmp file are uploaded to S3 (localstack)
    hpr_packet_reporter:handle_cast({upload_packets, FilePath}, State),

    UploadedFile = meck:capture(first, aws_s3, put_object, '_', 3),
    {ok, #{<<"Body">> := ResponseBody}, _} = aws_s3:get_object(AWSClient, Bucket, UploadedFile),

    [EncodedPacket, EncodedPacket2] = parse_packet_report(ResponseBody),
    verify_packet(Packet, Route, EncodedPacket),
    verify_packet(Packet2, Route, EncodedPacket2),

    %% Packets are cleared from ETS
    ?assertEqual(0, length(ets:tab2list(hpr_packet_report_ets))),

    ok.

upload_window_test(_Config) ->
    Env = application:get_env(?APP, packet_reporter, #{}),
    UploadWindow = maps:get(upload_window, Env, 900000),
    State = sys:get_state(hpr_packet_reporter),
    #state{upload_window_start_time = WindowStartTime} = State,

    Packet = test_utils:join_packet_up(#{}),
    Route = test_utils:packet_route(#{}),

    %% Reported packets are encoded and saved to ETS
    hpr_packet_reporter:report_packet(Packet, Route),

    %% Encoded packets are written to a tmp write file
    hpr_packet_reporter:handle_cast(write_packets, State),

    ?assertEqual(false, meck:called(hpr_packet_reporter, upload_packets, '_')),

    %% Write packets after upload window has elapsed
    hpr_packet_reporter:handle_cast(write_packets, State#state{
        upload_window_start_time = (WindowStartTime - UploadWindow - 1000)
    }),

    ?assertEqual(true, meck:called(hpr_packet_reporter, upload_packets, '_')),

    ok.

%% ------------------------------------------------------------------
%% Helpers
%% ------------------------------------------------------------------

verify_packet(
    #packet_router_packet_up_v1_pb{
        payload = Payload,
        timestamp = GatewayTimestamp,
        rssi = RSSI,
        frequency = FrequencyMhz,
        datarate = Datarate,
        snr = SNR,
        region = Region,
        gateway = Gateway
    },
    #config_route_v1_pb{
        oui = OUI,
        net_id = NetID
    },
    EncodedPacket
) ->
    PacketReport = packet_router_pb:decode_msg(EncodedPacket, packet_router_packet_report_v1_pb),
    ?assertEqual(
        GatewayTimestamp, PacketReport#packet_router_packet_report_v1_pb.gateway_timestamp_ms
    ),
    ?assertEqual(OUI, PacketReport#packet_router_packet_report_v1_pb.oui),
    ?assertEqual(NetID, PacketReport#packet_router_packet_report_v1_pb.net_id),
    ?assertEqual(RSSI, PacketReport#packet_router_packet_report_v1_pb.rssi),
    ?assertEqual(FrequencyMhz, PacketReport#packet_router_packet_report_v1_pb.frequency),
    ?assertEqual(SNR, PacketReport#packet_router_packet_report_v1_pb.snr),
    ?assertEqual(Datarate, PacketReport#packet_router_packet_report_v1_pb.datarate),
    ?assertEqual(Region, PacketReport#packet_router_packet_report_v1_pb.region),
    ?assertEqual(Gateway, PacketReport#packet_router_packet_report_v1_pb.gateway),
    ?assertEqual(
        crypto:hash(sha256, Payload), PacketReport#packet_router_packet_report_v1_pb.payload_hash
    ).

%% Parse length-delimited protobufs
parse_packet_report(Report) ->
    UncompressedReport = zlib:gunzip(Report),
    parse_packet_report(UncompressedReport, []).

parse_packet_report(<<>>, Acc) ->
    lists:reverse(Acc);
parse_packet_report(<<Size:4/binary, Rest/binary>>, Acc) ->
    DecodedSize = binary:decode_unsigned(Size),
    <<Packet:DecodedSize/binary, Rest2/binary>> = Rest,
    parse_packet_report(Rest2, [Packet | Acc]).
