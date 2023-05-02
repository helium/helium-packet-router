-module(hpr_test_multi_buy_service).

-behaviour(helium_multi_buy_multi_buy_bhvr).

-include("../src/grpc/autogen/multi_buy_pb.hrl").

-export([
    init/2,
    inc/2,
    handle_info/2
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    StreamState.

-spec inc(ctx:ctx(), multi_buy_pb:multi_buy_inc_req_v1_pb()) ->
    {ok, multi_buy_pb:multi_buy_inc_res_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
inc(Ctx, Req) ->
    F = application:get_env(hpr, test_multi_buy_service_inc, fun(
        Ctx0, #multi_buy_inc_req_v1_pb{key = Key}
    ) ->
        Map = persistent_term:get(test_multi_buy_service_inc_map, #{}),
        OldCount = maps:get(Key, Map, 0),
        NewCount = OldCount + 1,
        persistent_term:put(test_multi_buy_service_inc_map, Map#{Key => NewCount}),
        {ok, #multi_buy_inc_res_v1_pb{count = NewCount}, Ctx0}
    end),
    F(Ctx, Req).

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_Msg, StreamState) ->
    StreamState.
