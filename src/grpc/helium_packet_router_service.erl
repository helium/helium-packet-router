%% Replicated from ~/helium/sibyl/src/grpc/helium_gateway_service.erl
%%%-------------------------------------------------------------------
%% wrapper implementations for the APIs & RPCs for the gateway service
%% basically this module handles various RPC and function calls from grpcbox_stream
%% and routes it to the required application specific handler module
%% due to issues with the rust grpc client, we have amalgamated what were
%% previously distinct grpc services ( such as state channels and routing )
%% which had module specific implementations
%% into a single service as defined in the gateway proto
%% rather than combining the server side implementations into one
%% single module, this top level module was added instead and simply
%% routes incoming RPCs to their service specific module
%% this way we can maintain functional seperation of concerns
%%%-------------------------------------------------------------------

-module(helium_packet_router_service).

-behaviour(helium_gateway_bhvr).

-include_lib("helium_proto/include/packet_pb.hrl").
%% TODO mimicking how sibyl repo includes gateway_pb.hrl because include_lib() fails:
%% -include_lib("helium_proto/include/gateway_pb.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").

%% FIXME this module has only been compiled (without tests via eunit
%% or ct) for purposes of establishing boiler-plate configurations for
%% Helium's use of gRPC and protobufs.  REMOVE THIS INCLUDE:
%% -include("sibyl.hrl").

%% streaming behaviour APIs
-export([
    init/2,
    handle_info/3
]).

%% general unary APIs
-export([
    address_to_public_uri/2,
    config/2,
    validators/2,
    version/2
]).

%% routing unary APIs
-export([]).

%% state channel unary APIs
-export([
    is_active_sc/2,
    is_overpaid_sc/2,
    close_sc/2
]).

%% poc unary PIs
-export([
    check_challenge_target/2,
    send_report/2,
    poc_key_to_public_uri/2
]).

%% streaming APIs
-export([
    follow_sc/2,
    config_update/2,
    routing/2,
    stream_poc/2,
    region_params_update/2
]).

%%%-------------------------------------------------------------------
%% common API implementations
%%%-------------------------------------------------------------------

%%
%% Streaming RPC init grpcbox callback
%%

%% todo update to use stream_ prefix convention, requires gateway rs update
init(follow_sc = RPC, StreamState) ->
    helium_stream_sc_follow_impl:init(RPC, StreamState);
init(routing = RPC, StreamState) ->
    helium_stream_routing_impl:init(RPC, StreamState);
init(stream_poc = RPC, StreamState) ->
    helium_stream_poc_impl:init(RPC, StreamState);
%% todo update to use stream_ prefix convention, requires gateway rs update
init(config_update = RPC, StreamState) ->
    helium_stream_config_update_impl:init(RPC, StreamState);
%% todo update to use stream_ prefix convention, requires gateway rs update
init(region_params_update = RPC, StreamState) ->
    helium_stream_region_params_update_impl:init(RPC, StreamState);
init(_RPC, StreamState) ->
    StreamState.

%%
%% Streaming RPC handle info callback
%% Stream must have been initialized first via call to init above
%%
-spec handle_info(atom(), any(), grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_RPC, Msg, StreamState) ->
    #{mod := Module} = _HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    Module:handle_info(Msg, StreamState).

%%%-------------------------------------------------------------------
%% General Unary RPC callbacks
%%%-------------------------------------------------------------------
-spec address_to_public_uri(
    ctx:ctx(),
    gateway_pb:gateway_address_routing_data_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
address_to_public_uri(Ctx, Message) ->
    helium_unary_general_impl:address_to_public_uri(Ctx, Message).

-spec config(
    ctx:ctx(),
    gateway_pb:gateway_config_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
config(Ctx, Message) -> helium_unary_general_impl:config(Ctx, Message).

-spec validators(
    ctx:ctx(),
    gateway_pb:gateway_validators_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
validators(Ctx, Message) -> helium_unary_general_impl:validators(Ctx, Message).

-spec version(
    ctx:ctx(),
    gateway_pb:gateway_version_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
version(Ctx, Message) -> helium_unary_general_impl:version(Ctx, Message).

%%%-------------------------------------------------------------------
%% Routing Unary RPC callbacks
%%%-------------------------------------------------------------------

%% none

%%%-------------------------------------------------------------------
%% State channel Unary RPC callbacks
%%%-------------------------------------------------------------------
-spec is_active_sc(
    ctx:ctx(),
    gateway_pb:gateway_sc_is_active_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
is_active_sc(Ctx, Message) -> helium_unary_state_channels_impl:is_active_sc(Ctx, Message).

-spec is_overpaid_sc(
    ctx:ctx(),
    gateway_pb:gateway_sc_is_overpaid_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
is_overpaid_sc(Ctx, Message) -> helium_unary_state_channels_impl:is_overpaid_sc(Ctx, Message).

-spec close_sc(
    ctx:ctx(),
    gateway_pb:gateway_sc_close_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()}.
close_sc(Ctx, Message) -> helium_unary_state_channels_impl:close_sc(Ctx, Message).

%%%-------------------------------------------------------------------
%% PoCs Unary RPC callbacks
%%%-------------------------------------------------------------------
-spec check_challenge_target(
    ctx:ctx(),
    gateway_pb:gateway_poc_check_challenge_target_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
check_challenge_target(Ctx, Message) ->
    helium_unary_poc_impl:check_challenge_target(Ctx, Message).

-spec send_report(
    ctx:ctx(),
    gateway_pb:gateway_poc_report_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
send_report(Ctx, Message) ->
    helium_unary_poc_impl:send_report(Ctx, Message).

-spec poc_key_to_public_uri(
    ctx:ctx(),
    gateway_pb:gateway_poc_key_routing_data_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
poc_key_to_public_uri(Ctx, Message) ->
    helium_unary_poc_impl:poc_key_to_public_uri(Ctx, Message).

%%%-------------------------------------------------------------------
%% Streaming RPC callbacks
%%%-------------------------------------------------------------------
-spec follow_sc(
    gateway_pb:gateway_sc_follow_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
follow_sc(Msg, StreamState) -> helium_stream_sc_follow_impl:follow_sc(Msg, StreamState).

-spec routing(
    gateway_pb:gateway_routing_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
routing(Msg, StreamState) -> helium_stream_routing_impl:routing(Msg, StreamState).

-spec stream_poc(
    gateway_pb:gateway_poc_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
stream_poc(Msg, StreamState) -> helium_stream_poc_impl:pocs(Msg, StreamState).

-spec config_update(
    gateway_pb:gateway_config_update_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
config_update(Msg, StreamState) ->
    helium_stream_config_update_impl:config_update(Msg, StreamState).

-spec region_params_update(
    gateway_pb:gateway_region_params_update_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
region_params_update(Msg, StreamState) ->
    helium_stream_region_params_update_impl:region_params_update(Msg, StreamState).
