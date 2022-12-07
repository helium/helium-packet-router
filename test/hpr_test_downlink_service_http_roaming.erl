-module(hpr_test_downlink_service_http_roaming).

-behaviour(helium_downlink_http_roaming_bhvr).

-export([
    init/2,
    handle_info/2
]).

-export([
    stream/2
]).

-export([
    downlink/1
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    Self = self(),
    true = erlang:register(?MODULE, self()),
    lager:notice("init ~p @ ~p", [?MODULE, Self]),
    StreamState.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({downlink, Resp}, StreamState) ->
    lager:notice("got Resp ~p", [Resp]),
    grpcbox_stream:send(false, Resp, StreamState);
handle_info(_Msg, StreamState) ->
    StreamState.

stream(Req, StreamState) ->
    case hpr_http_roaming_register:verify(Req) of
        false ->
            {grpc_error, {7, <<"PERMISSION_DENIED">>}};
        true ->
            {ok, StreamState}
    end.

-spec downlink(Resp :: hpr_route_stream_res:res()) -> ok.
downlink(Resp) ->
    lager:notice("downlink ~p  @ ~p", [Resp, erlang:whereis(?MODULE)]),
    ?MODULE ! {downlink, Resp},
    ok.
