%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 19. Sep 2022 12:44 PM
%%%-------------------------------------------------------------------
-module(hpr_roaming_downlink).
-author("jonathanruttenberg").

-include_lib("elli/include/elli.hrl").
-include("hpr_roaming.hrl").

-behaviour(elli_handler).

%% Downlink API
-export([
    handle/2,
    handle_event/3,
    send_response/2
]).

%% State Channel API
-export([
    init_ets/0,
    insert_handler/2,
    delete_handler/1,
    lookup_handler/1
]).

-define(RESPONSE_STREAM_ETS, hpr_http_response_stream_ets).

%% Downlink Handler ==================================================

handle(Req, Args) ->
    Method = elli_request:method(Req),
    Host = elli_request:get_header(<<"Host">>, Req),
    lager:info("request from [host: ~p]", [Host]),

    lager:debug("request: ~p", [{Method, elli_request:path(Req), Req, Args}]),
    Body = elli_request:body(Req),
    Decoded = jsx:decode(Body),

    case hpr_roaming_protocol:handle_message(Decoded) of
        ok ->
            {200, [], <<"OK">>};
        {error, _} = Err ->
            lager:error("dowlink handle message error ~p", [Err]),
            {500, [], <<"An error occurred">>};
        {join_accept, {ResponseStream, DownlinkPacket}} ->
            lager:debug("sending downlink [respnse_stream: ~p]", [ResponseStream]),
            ok = send_response(ResponseStream, DownlinkPacket),
            {200, [], <<"downlink sent: 1">>};
        {downlink, PayloadResponse, {ResponseStream, DownlinkPacket}, {Endpoint, FlowType}} ->
            lager:debug(
                "sending downlink [respnse_stream: ~p] [response: ~p]",
                [ResponseStream, PayloadResponse]
            ),
            ok = send_response(ResponseStream, DownlinkPacket),
            case FlowType of
                sync ->
                    {200, [], jsx:encode(PayloadResponse)};
                async ->
                    spawn(fun() ->
                        Res = hackney:post(Endpoint, [], jsx:encode(PayloadResponse), [with_body]),
                        lager:debug("async downlink repsonse ~p", [?MODULE, Res])
                    end),
                    {200, [], <<"downlink sent: 2">>}
            end
    end.

handle_event(Event, _Data, _Args) ->
    case
        lists:member(Event, [
            bad_request,
            %% chunk_complete,
            %% client_closed,
            %% client_timeout,
            %% file_error,
            invalid_return,
            %% request_closed,
            %% request_complete,
            request_error,
            request_exit,
            request_parse_error,
            request_throw
            %% elli_startup
        ])
    of
        true -> lager:error("~p ~p ~p", [Event, _Data, _Args]);
        false -> lager:debug("~p ~p ~p", [Event, _Data, _Args])
    end,

    ok.

%% Response Stream =====================================================

-spec init_ets() -> ok.
init_ets() ->
    ?RESPONSE_STREAM_ETS = ets:new(?RESPONSE_STREAM_ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    ok.

-spec insert_handler(
    TransactionID :: integer(), ResponseStream :: hpr_router_stream_manager:gateway_stream()
) -> ok.
insert_handler(TransactionID, ResponseStream) ->
    true = ets:insert(?RESPONSE_STREAM_ETS, {TransactionID, ResponseStream}),
    ok.

-spec delete_handler(TransactionID :: integer()) -> ok.
delete_handler(TransactionID) ->
    true = ets:delete(?RESPONSE_STREAM_ETS, TransactionID),
    ok.

-spec lookup_handler(TransactionID :: integer()) ->
    {ok, ResponseStream :: grpcbox_stream:t()} | {error, any()}.
lookup_handler(TransactionID) ->
    case ets:lookup(?RESPONSE_STREAM_ETS, TransactionID) of
        [{_, ResponseStream}] -> {ok, ResponseStream};
        [] -> {error, {not_found, TransactionID}}
    end.

-spec send_response(
    ResponseStream :: grpcbox_stream:t(), DownlinkPacket :: hpr_roaming_protocol:downlink_packet()
) -> ok.
send_response(ResponseStream, DownlinkPacket) ->
    lager:debug("sending response: ~p, pid: ~p", [DownlinkPacket, ResponseStream]),
    grpcbox_stream:send(false, DownlinkPacket, ResponseStream),
    ok.
