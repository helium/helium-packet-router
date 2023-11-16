%%%-------------------------------------------------------------------
%% @doc
%% == HPR Gateway Location ==
%% @end
%%%-------------------------------------------------------------------
-module(hpr_gateway_location).

-include("hpr.hrl").
-include("../autogen/iot_config_pb.hrl").

-export([
    init/0,
    get/1,
    expire_locations/0
]).

-define(ETS, hpr_gateway_location_ets).
-define(DETS, hpr_gateway_location_dets).
-define(DEFAULT_DETS_FILE, "hpr_gateway_location_dets").
-define(CLEANUP_INTERVAL, timer:hours(1)).
-define(CACHE_TIME, timer:hours(24)).
-define(NOT_FOUND, not_found).

-record(location, {
    gateway :: libp2p_crypto:pubkey_bin(),
    timestamp :: non_neg_integer(),
    h3_index :: h3:index() | undefined,
    lat :: float() | undefined,
    long :: float() | undefined
}).

-spec init() -> ok.
init() ->
    ?ETS = ets:new(?ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true},
        {keypos, #location.gateway}
    ]),
    ok = open_dets(),
    case dets:to_ets(?DETS, ?ETS) of
        {error, _Reason} ->
            lager:error("failed to hydrate ets ~p", [_Reason]);
        _ ->
            lager:info("ets hydrated")
    end,
    {ok, _} = timer:apply_interval(?CLEANUP_INTERVAL, ?MODULE, expire_locations, []),
    ok.

-spec get(libp2p_crypto:pubkey_bin()) -> {ok, h3:index(), float(), float()} | {error, any()}.
get(PubKeyBin) ->
    Yesterday = erlang:system_time(millisecond) - ?CACHE_TIME,
    case ets:lookup(?ETS, PubKeyBin) of
        [] ->
            update_location(PubKeyBin);
        [#location{timestamp = T}] when T < Yesterday ->
            update_location(PubKeyBin);
        [#location{h3_index = undefined}] ->
            {error, ?NOT_FOUND};
        [#location{h3_index = H3Index, lat = Lat, long = Long}] ->
            {ok, H3Index, Lat, Long}
    end.

-spec expire_locations() -> ok.
expire_locations() ->
    Time = erlang:system_time(millisecond) - ?CACHE_TIME,
    DETSDeleted = dets:select_delete(?DETS, [
        {{'_', '_', '$3', '_', '_', '_'}, [{'<', '$3', Time}], [true]}
    ]),
    lager:info("expiring ~w dets keys", [DETSDeleted]).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec update_location(libp2p_crypto:pubkey_bin()) ->
    {ok, h3:index(), float(), float()} | {error, any()}.
update_location(PubKeyBin) ->
    NewLoc = #location{
        gateway = PubKeyBin,
        timestamp = erlang:system_time(millisecond),
        h3_index = undefined,
        lat = undefined,
        long = undefined
    },
    case get_location_from_ics(PubKeyBin) of
        {error, Reason} ->
            GatewauName = hpr_utils:gateway_name(PubKeyBin),
            lager:warning(
                "fail to get_location_from_ics ~p for ~s",
                [Reason, GatewauName]
            ),
            ok = insert(NewLoc),
            {error, not_found};
        {ok, H3IndexString} ->
            H3Index = h3:from_string(H3IndexString),
            {Lat, Long} = h3:to_geo(H3Index),
            ok = insert(NewLoc#location{
                h3_index = H3Index,
                lat = Lat,
                long = Long
            }),
            {ok, H3Index, Lat, Long}
    end.

-spec insert(Loc :: #location{}) -> ok.
insert(Loc) ->
    true = ets:insert(?ETS, Loc),
    _ = erlang:spawn(dets, insert, [?DETS, Loc]),
    ok.

%% We have to do this because the call to `helium_iot_config_gateway_client:location` can return
%% `{error, {Status, Reason}, _}` but is not in the spec...
-dialyzer({nowarn_function, get_location_from_ics/1}).
-spec get_location_from_ics(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    {ok, string()} | {error, any()}.
get_location_from_ics(PubKeyBin) ->
    SigFun = hpr_utils:sig_fun(),
    Req = #iot_config_gateway_location_req_v1_pb{
        gateway = PubKeyBin,
        signer = hpr_utils:pubkey_bin()
    },
    EncodedReq = iot_config_pb:encode_msg(Req, iot_config_gateway_location_req_v1_pb),
    SignedReq = Req#iot_config_gateway_location_req_v1_pb{signature = SigFun(EncodedReq)},
    case
        helium_iot_config_gateway_client:location(SignedReq, #{
            channel => ?IOT_CONFIG_CHANNEL
        })
    of
        {error, {Status, Reason}, _} when is_binary(Status) ->
            {error, {grpcbox_utils:status_to_string(Status), Reason}};
        {grpc_error, Reason} ->
            {error, Reason};
        {error, Reason} ->
            {error, Reason};
        {ok, #iot_config_gateway_location_res_v1_pb{location = Location}, _Meta} ->
            {ok, Location}
    end.

-spec open_dets() -> ok.
open_dets() ->
    DataDir = hpr_utils:base_data_dir(),
    DETSFile = filename:join(DataDir, ?DEFAULT_DETS_FILE),
    ok = filelib:ensure_dir(DETSFile),
    case dets:open_file(?DETS, [{file, DETSFile}, {keypos, #location.gateway}]) of
        {error, _Reason} ->
            Deleted = file:delete(DETSFile),
            lager:error("failed to open dets ~p deleting file ~p", [_Reason, Deleted]),
            open_dets();
        {ok, _} ->
            ok
    end.
