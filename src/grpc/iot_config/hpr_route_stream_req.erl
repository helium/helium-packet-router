-module(hpr_route_stream_req).

-include("../autogen/iot_config_pb.hrl").

-export([
    new/1, new/2,
    timestamp/1,
    signer/1,
    signature/1,
    sign/2,
    since/1,
    verify/1
]).

-type req() :: #iot_config_route_stream_req_v1_pb{}.

-export_type([req/0]).

-spec new(Signer :: libp2p_crypto:pubkey_bin()) -> req().
new(Signer) ->
    new(Signer, 0).

%% @doc Build a stream request resuming from `Since', given in MILLISECONDS.
%%
%% `since' goes on the wire in SECONDS. The proto comment claims milliseconds,
%% but it is stale: iot-config parses the field with
%% `Utc.timestamp_opt(request.since as i64, 0)', whose first argument is whole
%% seconds, and it has done so deliberately since oracles-iot 26c77a9
%% ("revert/conform iot-config req timestamps to seconds", Jan 2024), which
%% moved every request and response timestamp in that service to seconds at
%% once. The response side was updated to match and its proto comment now says
%% seconds; only this field's comment was left behind.
%%
%% Sending milliseconds meant asking for changes since roughly the year 57000,
%% so a restarting HPR received no backfill at all -- it kept whatever its DETS
%% held and then saw only live updates, with nothing in any log to say so.
%%
%% The argument stays in milliseconds because everything else in HPR does,
%% including the `last_timestamp' this is called with and what that persists to
%% DETS; the conversion belongs here, at the wire, mirroring
%% hpr_route_stream_res:timestamp/1 converting the other way on the way in.
%% Truncating down is the safe direction: at worst it re-requests under a
%% second of changes, and applying an update twice is a no-op.
-spec new(Signer :: libp2p_crypto:pubkey_bin(), SinceMS :: non_neg_integer()) -> req().
new(Signer, SinceMS) ->
    #iot_config_route_stream_req_v1_pb{
        signer = Signer,
        timestamp = erlang:system_time(millisecond),
        since = erlang:convert_time_unit(SinceMS, millisecond, second)
    }.

-spec timestamp(RouteStreamReq :: req()) -> non_neg_integer().
timestamp(RouteStreamReq) ->
    RouteStreamReq#iot_config_route_stream_req_v1_pb.timestamp.

-spec signer(RouteStreamReq :: req()) -> libp2p_crypto:pubkey_bin().
signer(RouteStreamReq) ->
    RouteStreamReq#iot_config_route_stream_req_v1_pb.signer.

-spec signature(RouteStreamReq :: req()) -> binary().
signature(RouteStreamReq) ->
    RouteStreamReq#iot_config_route_stream_req_v1_pb.signature.

-spec sign(RouteStreamReq :: req(), SigFun :: fun()) -> req().
sign(RouteStreamReq, SigFun) ->
    EncodedRouteStreamReq = iot_config_pb:encode_msg(
        RouteStreamReq, iot_config_route_stream_req_v1_pb
    ),
    RouteStreamReq#iot_config_route_stream_req_v1_pb{signature = SigFun(EncodedRouteStreamReq)}.

%% @doc The wire value, in SECONDS -- not the milliseconds new/2 was given.
-spec since(RouteStreamReq :: req()) -> non_neg_integer().
since(RouteStreamReq) ->
    RouteStreamReq#iot_config_route_stream_req_v1_pb.since.

-spec verify(RouteStreamReq :: req()) -> boolean().
verify(RouteStreamReq) ->
    EncodedRouteStreamReq = iot_config_pb:encode_msg(
        RouteStreamReq#iot_config_route_stream_req_v1_pb{
            signature = <<>>
        },
        iot_config_route_stream_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedRouteStreamReq,
        ?MODULE:signature(RouteStreamReq),
        libp2p_crypto:bin_to_pubkey(?MODULE:signer(RouteStreamReq))
    ).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

timestamp_test() ->
    Signer = <<"Signer">>,
    Timestamp = erlang:system_time(millisecond),
    ?assert(Timestamp =< ?MODULE:timestamp(?MODULE:new(Signer))),
    ok.

since_is_seconds_on_the_wire_test() ->
    Signer = <<"Signer">>,
    %% A real resume point: whole seconds, plus a remainder that must not be
    %% allowed to round the request forward past changes HPR has not seen.
    SinceMS = 1_700_000_000_999,
    ?assertEqual(1_700_000_000, ?MODULE:since(?MODULE:new(Signer, SinceMS))),
    ?assertEqual(0, ?MODULE:since(?MODULE:new(Signer))),
    ?assertEqual(0, ?MODULE:since(?MODULE:new(Signer, 999))),
    ok.

signer_test() ->
    Signer = <<"Signer">>,
    ?assertEqual(
        Signer,
        ?MODULE:signer(?MODULE:new(Signer))
    ),
    ok.

signature_test() ->
    Signer = <<"Signer">>,
    ?assertEqual(
        <<>>,
        ?MODULE:signature(?MODULE:new(Signer))
    ),
    ok.

sign_verify_test() ->
    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ed25519),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Signer = libp2p_crypto:pubkey_to_bin(PubKey),
    RouteStreamReq = ?MODULE:new(Signer),

    SignedRouteStreamReq = ?MODULE:sign(RouteStreamReq, SigFun),

    ?assert(?MODULE:verify(SignedRouteStreamReq)),
    ok.

-endif.
