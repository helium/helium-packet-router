%%%-------------------------------------------------------------------
%% @doc
%% == HPR Gateway Location ==
%% @end
%%%-------------------------------------------------------------------
-module(hpr_gateway_location).

-behaviour(gen_server).

-include("hpr.hrl").
-include("../autogen/iot_config_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    init/0,
    get/1,
    update_location/1,
    expire_locations/0
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(SERVER, ?MODULE).
-define(ETS, hpr_gateway_location_ets).
-define(DETS, hpr_gateway_location_dets).
-define(DEFAULT_DETS_FILE, "hpr_gateway_location_dets").
-define(CLEANUP_INTERVAL, timer:hours(1)).
-define(CACHE_TIME, timer:hours(24)).
-define(ERROR_CACHE_TIME, timer:hours(1)).
-define(NOT_FOUND, not_found).
-define(REQUESTED, requested).

-record(state, {}).

-record(location, {
    status :: ok | ?NOT_FOUND | error | ?REQUESTED,
    gateway :: libp2p_crypto:pubkey_bin(),
    timestamp :: non_neg_integer(),
    h3_index = undefined :: h3:index() | undefined,
    lat = undefined :: float() | undefined,
    long = undefined :: float() | undefined
}).

-type state() :: #state{}.
-type loc() :: {h3:index(), float(), float()} | undefined.

-export_type([loc/0]).

%% ------------------------------------------------------------------
%%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(map()) -> any().
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

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
    Now = erlang:system_time(millisecond),
    Yesterday = Now - ?CACHE_TIME,
    LastHour = Now - ?ERROR_CACHE_TIME,
    case ets:lookup(?ETS, PubKeyBin) of
        [] ->
            ok = ?MODULE:update_location(PubKeyBin),
            {error, ?NOT_FOUND};
        [#location{status = ok, timestamp = T, h3_index = H3Index, lat = Lat, long = Long}] when
            T < Yesterday
        ->
            ok = ?MODULE:update_location(PubKeyBin),
            {ok, H3Index, Lat, Long};
        [#location{status = _, timestamp = T}] when T < Yesterday ->
            ok = ?MODULE:update_location(PubKeyBin),
            {error, ?NOT_FOUND};
        [#location{status = error, timestamp = T}] when T < LastHour ->
            ok = ?MODULE:update_location(PubKeyBin),
            {error, undefined};
        [#location{status = error}] ->
            {error, undefined};
        [#location{status = requested, timestamp = T, gateway = PubKeyBin}] when T < LastHour ->
            GatewayName = hpr_utils:gateway_name(PubKeyBin),
            lager:warning("got an old request for ~p ~s", [PubKeyBin, GatewayName]),
            ok = ?MODULE:update_location(PubKeyBin),
            {error, ?REQUESTED};
        [#location{status = requested}] ->
            {error, ?REQUESTED};
        [#location{status = ?NOT_FOUND}] ->
            {error, ?NOT_FOUND};
        [#location{status = ok, h3_index = H3Index, lat = Lat, long = Long}] ->
            {ok, H3Index, Lat, Long}
    end.

-spec update_location(libp2p_crypto:pubkey_bin()) -> ok.
update_location(PubKeyBin) ->
    gen_server:cast(?SERVER, {update_location, PubKeyBin}).

-spec expire_locations() -> ok.
expire_locations() ->
    Time = erlang:system_time(millisecond) - ?CACHE_TIME,
    DETSDeleted = dets:select_delete(?DETS, [
        {{'_', '_', '_', '$3', '_', '_', '_'}, [{'<', '$3', Time}], [true]}
    ]),
    lager:info("expiring ~w dets keys", [DETSDeleted]).

% ------------------------------------------------------------------
%%% gen_server Function Definitions
%% ------------------------------------------------------------------
-spec init(map()) -> {ok, state()}.
init(_Args) ->
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast({update_location, PubKeyBin}, State) ->
    NewLoc = #location{
        status = ?REQUESTED,
        gateway = PubKeyBin,
        timestamp = erlang:system_time(millisecond)
    },
    true = ets:insert(?ETS, NewLoc),
    Start = erlang:system_time(millisecond),
    case get_location_from_ics(PubKeyBin) of
        {error, ?NOT_FOUND} ->
            hpr_metrics:observe_gateway_location(Start, ?NOT_FOUND),
            GatewayName = hpr_utils:gateway_name(PubKeyBin),
            lager:info(
                "fail to get_location_from_ics ~p for ~s",
                [?NOT_FOUND, GatewayName]
            ),
            ok = insert(NewLoc#location{status = ?NOT_FOUND});
        {error, Reason} ->
            hpr_metrics:observe_gateway_location(Start, error),
            GatewayName = hpr_utils:gateway_name(PubKeyBin),
            lager:warning(
                "fail to get_location_from_ics ~p for ~s",
                [Reason, GatewayName]
            ),
            ok = insert(NewLoc#location{status = error});
        {ok, H3IndexString} ->
            hpr_metrics:observe_gateway_location(Start, ok),
            H3Index = h3:from_string(H3IndexString),
            {Lat, Long} = h3:to_geo(H3Index),
            ok = insert(NewLoc#location{
                status = ok,
                h3_index = H3Index,
                lat = Lat,
                long = Long
            })
    end,
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _state) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
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
            channel => ?LOCATION_CHANNEL
        })
    of
        {error, {Status, Reason}, _} when is_binary(Status) ->
            StringStatus = grpcbox_utils:status_to_string(Status),
            case StringStatus of
                <<"NOT_FOUND">> ->
                    {error, ?NOT_FOUND};
                _ ->
                    {error, {StringStatus, Reason}}
            end;
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
