%%%-------------------------------------------------------------------
%% @doc
%% == GWMP Redirect Worker ==
%%
%% This worker enables remapping source destinations on the fly. Need
%% to route a packet, but don't know the correct destination until you
%% know the originating region? This worker fills that need.
%%
%% Starts a udp socket with `port'.
%%
%% The worker will acknowledge `pull_data' as a courtesy.
%%
%% Receiving a `push_data' the worker will pull the `regi' key from
%% the `stats' map in the payload and return a special message of
%% where that packet should be sent instead.
%%
%% Unmapped regions will be logged and dropped.
%%
%% Usage:
%% /sys.config.src
%% {hpr, [
%%     {redirect_by_region, #{
%%         port => 1777,
%%         remap => #{
%%             <<"US915">> => <<"127.0.0.1:1778">>,
%%             <<"EU868">> => <<"127.0.0.1:1779">>,
%%             <<"AS923_1">> => <<"127.0.0.1:1780">>
%%         }
%%     }}
%% ]}
%%
%% @end
%%%-------------------------------------------------------------------
-module(hpr_gwmp_redirect_worker).

-behaviour(gen_server).

-include("semtech_udp.hrl").

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

-record(state, {
    port :: non_neg_integer(),
    remap :: map(),
    socket :: gen_udp:socket()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    case maps:size(Args) of
        0 -> ignore;
        _ -> gen_server:start_link({local, ?MODULE}, ?MODULE, Args, [])
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    #{port := Port, remap := Map} = Args,
    {ok, Socket} = gen_udp:open(Port, [binary, {active, true}]),
    {ok, #state{
        port = Port,
        remap = Map,
        socket = Socket
    }}.

-spec handle_call(Msg, _From, #state{}) -> {stop, {unimplemented_call, Msg}, #state{}}.
handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

-spec handle_cast(Msg, #state{}) -> {stop, {unimplemented_cast, Msg}, #state{}}.
handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

handle_info(
    {udp, Socket, Address, Port, IncomingData},
    #state{socket = Socket, remap = ReMap} = State
) ->
    try semtech_udp:identifier(IncomingData) of
        ?PUSH_DATA ->
            TxPk = semtech_udp:json_data(IncomingData),
            Stat = maps:get(<<"stat">>, TxPk),
            Region = maps:get(<<"regi">>, Stat),
            case maps:get(Region, ReMap, undefined) of
                undefined ->
                    lager:warning([{region, Region}], "dropping redirect for unmapped region"),
                    dropped;
                NewDest ->
                    lager:debug([{region, Region}], "redirecting gateway"),
                    NewData = jsx:encode(#{
                        new_dest => NewDest,
                        packet => erlang:binary_to_list(IncomingData)
                    }),
                    OutgoingData = <<"REMAP: ", NewData/binary>>,
                    gen_udp:send(Socket, Address, Port, OutgoingData),
                    redirect
            end;
        ?PULL_DATA ->
            Token = semtech_udp:token(IncomingData),
            OutgoingData = semtech_udp:pull_ack(Token),
            gen_udp:send(Socket, Address, Port, OutgoingData);
        _ ->
            noop
    catch
        _E:_R ->
            lager:error([{type, _E}, {reason, _R}], "could not identify semtech_udp packet")
    end,
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State = #state{socket = Socket}) ->
    ok = gen_udp:close(Socket).
