%%%-------------------------------------------------------------------
%% @doc
%% === Config Service Stream Worker ===
%%
%% Makes a GRPC stream to the config service to receive route updates
%% and forward them dealt with.
%%
%% A "channel" is created `grpcbox' when the app is started. This
%% channel does not make an actual connection. That happens when a
%% stream is created and a message is sent.
%%
%% If a channel goes down, all the stream will receive a `eos'
%% message, and a `DOWN' message. The channel will clean up the
%% remaining stream pids.
%%
%% If a grpc server goes down, it may not have time to send `eos' to all of it's
%% streams, and we will only get a `DOWN' message.
%%
%% Handling both of these, `eos' will result in an unhandled `DOWN' message, and
%% a `DOWN' message will have no corresponding `eos' message.
%%
%% == Known Failures ==
%%
%%   - unimplemented
%%   - undefined channel
%%   - econnrefused
%%
%% = UNIMPLEMENTED Trailers =
%%
%% If we connect to a valid grpc server, but it does not implement the
%% messages we expect, the stream will be "successfully" created, then
%% immediately torn down. The failure will be relayed in `trailers'.
%% In this care, we log the unimplimented message, but do not attempt
%% to reconnect.
%%
%% = Undefined Channel =
%%
%% All workers that talk to the Config Service use the same client
%% channel, `iot_config_channel'. Channels do not make connections to
%% servers. If this message is received it means the channel was never
%% created, either through configuration, or explicitly with
%% `grpcbox_client:connect/3'.
%%
%% = econnrefused =
%%
%% The `iot_config_channel' has been improperly configured to point at a
%% non-grpc server. Or, the grpc server is down. We fail the backoff
%% and try again later.
%%
%% @end
%%%-------------------------------------------------------------------
-module(hpr_route_stream_worker).

-behaviour(gen_server).

-include("hpr.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1
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

-ifdef(TEST).
-define(BACKOFF_MIN, timer:seconds(1)).
-else.
-define(BACKOFF_MIN, timer:seconds(10)).
-endif.
-define(BACKOFF_MAX, timer:minutes(5)).

-record(state, {
    stream :: grpcbox_client:stream() | undefined,
    file_backup_path :: path(),
    conn_backoff :: backoff:backoff()
}).

-type path() :: string() | undefined.

-define(SERVER, ?MODULE).
-define(INIT_STREAM, init_stream).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(map()) -> any().
start_link(Args) ->
    gen_server:start_link(
        {local, ?SERVER}, ?SERVER, Args, []
    ).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    Path = maps:get(file_backup_path, Args, undefined),
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    lager:info("starting route worker file=~s", [Path]),
    ok = maybe_init_from_file(Path),
    self() ! ?INIT_STREAM,
    {ok, #state{
        stream = undefined,
        file_backup_path = Path,
        conn_backoff = Backoff
    }}.

handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

handle_info(?INIT_STREAM, #state{conn_backoff = Backoff0} = State) ->
    lager:info("connecting"),
    {PubKey, SigFun} = persistent_term:get(?HPR_KEY),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    RouteStreamReq = hpr_route_stream_req:new(PubKeyBin),
    SignedRouteStreamReq = hpr_route_stream_req:sign(RouteStreamReq, SigFun),
    StreamOptions = #{channel => ?IOT_CONFIG_CHANNEL},

    case helium_iot_config_route_client:stream(SignedRouteStreamReq, StreamOptions) of
        {ok, Stream} ->
            lager:info("stream initialized"),
            {_, Backoff1} = backoff:succeed(Backoff0),
            ok = hpr_route_ets:delete_all(),
            {noreply, State#state{stream = Stream, conn_backoff = Backoff1}};
        {error, undefined_channel} ->
            lager:error(
                "`iot_config_channel` is not defined, or not started. Not attempting to reconnect."
            ),
            {noreply, State};
        {error, _E} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            lager:error("failed to get stream sleeping ~wms : ~p", [Delay, _E]),
            _ = erlang:send_after(Delay, self(), ?INIT_STREAM),
            {noreply, State#state{conn_backoff = Backoff1}}
    end;
%% GRPC stream callbacks
handle_info({data, _StreamID, RouteStreamRes}, #state{file_backup_path = Path} = State) ->
    Action = hpr_route_stream_res:action(RouteStreamRes),
    Data = hpr_route_stream_res:data(RouteStreamRes),
    {Type, _} = Data,
    lager:debug("got route stream update ~s ~s ", [Action, Type]),
    ok = process_route_stream_res(Action, Data),
    ok = maybe_cache_response(Path, Action, Data),
    {noreply, State};
handle_info({headers, _StreamID, _Headers}, State) ->
    %% noop on headers
    {noreply, State};
handle_info({trailers, _StreamID, Trailers}, State) ->
    %% IF a stream is closed by the server side, Trailers will be
    %% received before the EOS. Removing the stream from state will
    %% mean none of the other clauses match, and reconnecting will not
    %% be attempted.
    %% ref: https://grpc.github.io/grpc/core/md_doc_statuscodes.html
    case Trailers of
        {<<"12">>, _, _} ->
            lager:error(
                "helium.config.route/stream not implemented. "
                "Make sure you're pointing at the right server."
            ),
            {noreply, State#state{stream = undefined}};
        _ ->
            {noreply, State}
    end;
handle_info(
    {'DOWN', _Ref, process, Pid, Reason},
    #state{stream = #{stream_pid := Pid}, conn_backoff = Backoff0} = State
) ->
    %% If a server dies unexpectedly, it may not send an `eos' message to all
    %% it's stream, and we'll only have a `DOWN' to work with.
    {Delay, Backoff1} = backoff:fail(Backoff0),
    lager:info("stream went down from the other side for ~p, sleeping ~wms", [Reason, Delay]),
    _ = erlang:send_after(Delay, self(), ?INIT_STREAM),
    {noreply, State#state{stream = undefined, conn_backoff = Backoff1}};
handle_info(
    {eos, StreamID},
    #state{stream = #{stream_id := StreamID}, conn_backoff = Backoff0} = State
) ->
    %% When streams or channel go down, they first send an `eos' message, then
    %% send a `DOWN' message.
    {Delay, Backoff1} = backoff:fail(Backoff0),
    lager:info("stream went down sleeping ~wms", [Delay]),
    _ = erlang:send_after(Delay, self(), ?INIT_STREAM),
    {noreply, State#state{stream = undefined, conn_backoff = Backoff1}};
handle_info(_Msg, State) ->
    lager:warning("unimplemented_info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    lager:error("terminate ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec process_route_stream_res(
    RouteStreamRes :: hpr_route_stream_res:action(),
    Data ::
        {route, hpr_route:route()}
        | {eui_pair, hpr_eui_pair:eui_pair()}
        | {devaddr_range, hpr_devaddr_range:devaddr_range()}
) -> ok.
process_route_stream_res(add, {route, Route}) ->
    hpr_route_ets:insert_route(Route);
process_route_stream_res(add, {eui_pair, EUIPair}) ->
    hpr_route_ets:insert_eui_pair(EUIPair);
process_route_stream_res(add, {devaddr_range, DevAddrRange}) ->
    hpr_route_ets:insert_devaddr_range(DevAddrRange);
process_route_stream_res(remove, {route, Route}) ->
    hpr_route_ets:delete_route(Route);
process_route_stream_res(remove, {eui_pair, EUIPair}) ->
    hpr_route_ets:delete_eui_pair(EUIPair);
process_route_stream_res(remove, {devaddr_range, DevAddrRange}) ->
    hpr_route_ets:delete_devaddr_range(DevAddrRange).

-spec maybe_cache_response(
    Path :: path(),
    RouteStreamRes :: hpr_route_stream_res:action(),
    Data ::
        {route, hpr_route:route()}
        | {eui_pair, hpr_eui_pair:eui_pair()}
        | {devaddr_range, hpr_devaddr_range:devaddr_range()}
) -> ok.
maybe_cache_response(undefined, _Action, _Data) ->
    ok;
maybe_cache_response(Path, add, {route, Route}) ->
    case open_backup_file(Path) of
        {error, _Reason} ->
            lager:error("failed to open backup file (~s) ~p", [Path, _Reason]);
        {ok, {RoutesMap, EUIPairs, DevAddrRanges}} ->
            RoutesMap1 = maps:put(hpr_route:id(Route), Route, RoutesMap),
            Binary = erlang:term_to_binary({RoutesMap1, EUIPairs, DevAddrRanges}),
            file:write_file(Path, Binary)
    end;
maybe_cache_response(Path, add, {eui_pair, EUIPair}) ->
    case open_backup_file(Path) of
        {error, _Reason} ->
            lager:error("failed to open backup file (~s) ~p", [Path, _Reason]);
        {ok, {RoutesMap, EUIPairs, DevAddrRanges}} ->
            EUIPairs1 = lists:usort([EUIPair | EUIPairs]),
            Binary = erlang:term_to_binary({RoutesMap, EUIPairs1, DevAddrRanges}),
            file:write_file(Path, Binary)
    end;
maybe_cache_response(Path, add, {devaddr_range, DevAddrRange}) ->
    case open_backup_file(Path) of
        {error, _Reason} ->
            lager:error("failed to open backup file (~s) ~p", [Path, _Reason]);
        {ok, {RoutesMap, EUIPairs, DevAddrRanges}} ->
            DevAddrRanges1 = lists:usort([DevAddrRange | DevAddrRanges]),
            Binary = erlang:term_to_binary({RoutesMap, EUIPairs, DevAddrRanges1}),
            file:write_file(Path, Binary)
    end;
maybe_cache_response(Path, remove, {route, Route}) ->
    case open_backup_file(Path) of
        {error, _Reason} ->
            lager:error("failed to open backup file (~s) ~p", [Path, _Reason]);
        {ok, {RoutesMap, EUIPairs, DevAddrRanges}} ->
            RouteID = hpr_route:id(Route),
            RoutesMap1 = maps:remove(RouteID, RoutesMap),
            EUIPairs1 = lists:dropwhile(
                fun(EUIPair) -> hpr_eui_pair:route_id(EUIPair) == RouteID end,
                EUIPairs
            ),
            DevAddrRanges1 = lists:dropwhile(
                fun(DevAddrRange) -> hpr_devaddr_range:route_id(DevAddrRange) == RouteID end,
                DevAddrRanges
            ),
            Binary = erlang:term_to_binary({RoutesMap1, EUIPairs1, DevAddrRanges1}),
            file:write_file(Path, Binary)
    end;
maybe_cache_response(Path, remove, {eui_pair, EUIPair}) ->
    case open_backup_file(Path) of
        {error, _Reason} ->
            lager:error("failed to open backup file (~s) ~p", [Path, _Reason]);
        {ok, {RoutesMap, EUIPairs, DevAddrRanges}} ->
            EUIPair1 = lists:delete(EUIPair, EUIPairs),
            Binary = erlang:term_to_binary({RoutesMap, EUIPair1, DevAddrRanges}),
            file:write_file(Path, Binary)
    end;
maybe_cache_response(Path, remove, {devaddr_range, DevAddrRange}) ->
    case open_backup_file(Path) of
        {error, _Reason} ->
            lager:error("failed to open backup file (~s) ~p", [Path, _Reason]);
        {ok, {RoutesMap, EUIPairs, DevAddrRanges}} ->
            DevAddrRanges1 = lists:delete(DevAddrRange, DevAddrRanges),
            Binary = erlang:term_to_binary({RoutesMap, EUIPairs, DevAddrRanges1}),
            file:write_file(Path, Binary)
    end.

-spec maybe_init_from_file(path()) -> ok.
maybe_init_from_file(undefined) ->
    ok;
maybe_init_from_file(Path) ->
    ok = filelib:ensure_dir(Path),
    case open_backup_file(Path) of
        {error, enoent} ->
            lager:warning("file does not exist creating"),
            ok = file:write_file(Path, erlang:term_to_binary(#{}));
        {error, _Reason} ->
            lager:error("failed to open backup file (~s) ~p", [Path, _Reason]);
        {ok, {RoutesMap, EUIPairs, DevAddrRanges}} ->
            maps:foreach(
                fun(_ID, Route) ->
                    hpr_route_ets:insert_route(Route)
                end,
                RoutesMap
            ),
            lists:foreach(fun hpr_route_ets:insert_eui_pair/1, EUIPairs),
            lists:foreach(fun hpr_route_ets:insert_devaddr_range/1, DevAddrRanges)
    end.

-spec open_backup_file(Path :: string()) -> {ok, {map(), list(), list()}} | {error, any()}.
open_backup_file(Path) ->
    Default = {#{}, [], []},
    case file:read_file(Path) of
        {error, _Reason} = Error ->
            Error;
        {ok, Binary} ->
            try erlang:binary_to_term(Binary) of
                {RoutesMap, EUIPairs, DevAddrRanges} when is_map(RoutesMap) ->
                    case
                        lists:all(fun hpr_route:is_valid_record/1, maps:values(RoutesMap)) andalso
                            lists:all(fun hpr_eui_pair:is_valid_record/1, EUIPairs) andalso
                            lists:all(fun hpr_devaddr_range:is_valid_record/1, DevAddrRanges)
                    of
                        true ->
                            {ok, RoutesMap, EUIPairs, DevAddrRanges};
                        false ->
                            lager:error("could not parse route record, fixing"),
                            ok = file:write_file(Path, erlang:term_to_binary(Default)),
                            {ok, Default}
                    end;
                _ ->
                    ok = file:write_file(Path, erlang:term_to_binary(Default)),
                    lager:warning("binary_to_term failed, fixing"),
                    {ok, Default}
            catch
                _E:_R ->
                    ok = file:write_file(Path, erlang:term_to_binary(Default)),
                    lager:warning("binary_to_term crash ~p ~p, fixing", [_E, _R]),
                    {ok, Default}
            end
    end.
