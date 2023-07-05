-module(hpr_router_pool_worker).

-behaviour(gen_server).
-behaviour(poolboy_worker).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    send/2
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

-record(state, {
    route :: hpr_route:route(),
    stream :: grpcbox_client:stream() | undefined
}).

-define(SERVER, ?MODULE).
-define(INIT_STREAM, init_stream).
-define(SEND, send).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(Route :: hpr_route:route()) -> any().
start_link(Route) ->
    gen_server:start_link(?SERVER, Route, []).

send(Worker, PacketUp) ->
    gen_server:call(Worker, {?SEND, PacketUp}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Route) ->
    lager:debug("starting ~p with ~p", [?MODULE, Route]),
    self() ! ?INIT_STREAM,
    {ok, #state{
        route = Route,
        stream = undefined
    }}.

handle_call({?SEND, _PacketUp}, _From, #state{stream = undefined} = State) ->
    lager:debug("got send but stream not started yet"),
    {reply, {error, not_started}, State};
handle_call({?SEND, PacketUp}, _From, #state{stream = #{stream_id := StreamID} = Stream} = State) ->
    EnvUp = hpr_envelope_up:new(PacketUp),
    Reply = grpcbox_client:send(Stream, EnvUp),
    lager:debug("sent envup ~p on ~p ", [Reply, StreamID]),
    {reply, Reply, State};
handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

handle_info(?INIT_STREAM, #state{route = Route} = State) ->
    lager:debug("connecting"),
    case helium_packet_router_packet_client:route(#{channel => hpr_route:id(Route)}) of
        {ok, #{stream_id := StreamID} = Stream} ->
            lager:debug("stream ~w initialized", [StreamID]),
            {noreply, State#state{
                stream = Stream
            }};
        {error, undefined_channel} ->
            lager:error(
                "`iot_config_channel` is not defined, or not started. Not attempting to reconnect."
            ),
            {stop, no_channel, State};
        {error, _E} ->
            lager:error("failed to get stream ~p", [_E]),
            {stop, failed_get_stream, State}
    end;
%% GRPC stream callbacks
handle_info({data, _StreamID, _EnvDown}, State) ->
    lager:notice("got data ~p ~p", [_StreamID, _EnvDown]),
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
            {stop, not_implemented, State};
        {<<"7">>, _, _} ->
            lager:error("UNAUTHORIZED, make sure HPR key is in config service db"),
            {stop, unauthorized, State};
        _ ->
            {noreply, State}
    end;
handle_info(
    {'DOWN', _Ref, process, Pid, Reason},
    #state{stream = #{stream_pid := Pid}} = State
) ->
    %% If a server dies unexpectedly, it may not send an `eos' message to all
    %% it's stream, and we'll only have a `DOWN' to work with.
    lager:debug("stream went down from the other side for ~p", [Reason]),
    {stop, stream_down, State};
handle_info(
    {eos, StreamID},
    #state{stream = #{stream_id := StreamID}} = State
) ->
    %% When streams or channel go down, they first send an `eos' message, then
    %% send a `DOWN' message.
    lager:debug("stream went down", []),
    {stop, eos, State};
handle_info(_Msg, State) ->
    lager:warning("unimplemented_info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    lager:error("terminate ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
