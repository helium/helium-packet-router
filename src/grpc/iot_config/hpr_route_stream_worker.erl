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
    StreamOptions = #{channel => iot_config_channel},

    case helium_iot_config_route_client:stream(SignedRouteStreamReq, StreamOptions) of
        {ok, Stream} ->
            lager:info("stream initialized"),
            {_, Backoff1} = backoff:succeed(Backoff0),
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
    lager:debug("route update"),
    ok = process_route_stream_res(RouteStreamRes, Path),
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
    {eos, StreamID},
    #state{stream = #{stream_id := StreamID}, conn_backoff = Backoff0} = State
) ->
    %% When streams or channels go down, they first send an `eos' message, then
    %% send a `DOWN' message. We're choosing not to handle the `DOWN' message,
    %% it behaves as a copy of the `eos' message.
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
    RouteStreamRes :: hpr_route_stream_res:res(), Path :: path()
) -> ok.
process_route_stream_res(RouteStreamRes, State) ->
    Route = hpr_route_stream_res:route(RouteStreamRes),
    case hpr_route_stream_res:action(RouteStreamRes) of
        delete ->
            hpr_route_ets:delete(Route);
        _ ->
            hpr_route_ets:insert(Route)
    end,
    case maybe_cache_response(RouteStreamRes, State) of
        {error, Reason} -> lager:error("failed to write to file ~p", [Reason]);
        ok -> ok
    end.

-spec maybe_cache_response(RouteStreamRes :: hpr_route_stream_res:res(), path()) ->
    ok | {error, any()}.
maybe_cache_response(_RouteStreamRes, undefined) ->
    ok;
maybe_cache_response(RouteStreamRes, Path) ->
    case open_backup_file(Path) of
        {error, _Reason} ->
            lager:error("failed to open backup file (~s) ~p", [Path, _Reason]);
        {ok, Map0} ->
            Route = hpr_route_stream_res:route(RouteStreamRes),
            ID = hpr_route:id(Route),
            Map1 =
                case hpr_route_stream_res:action(RouteStreamRes) of
                    delete ->
                        maps:remove(ID, Map0);
                    _ ->
                        Map0#{ID => Route}
                end,
            Binary = erlang:term_to_binary(Map1),
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
        {ok, Map} ->
            maps:foreach(
                fun(_ID, Route) ->
                    hpr_route_ets:insert(Route)
                end,
                Map
            )
    end.

-spec open_backup_file(Path :: string()) -> {ok, map()} | {error, any()}.
open_backup_file(Path) ->
    case file:read_file(Path) of
        {error, _Reason} = Error ->
            Error;
        {ok, Binary} ->
            try erlang:binary_to_term(Binary) of
                Map when is_map(Map) ->
                    {ok, Map};
                _ ->
                    ok = file:write_file(Path, erlang:term_to_binary(#{})),
                    lager:warning("binary_to_term failed, fixing"),
                    {ok, #{}}
            catch
                _E:_R ->
                    ok = file:write_file(Path, erlang:term_to_binary(#{})),
                    lager:warning("binary_to_term crash ~p ~p, fixing", [_E, _R]),
                    {ok, #{}}
            end
    end.
