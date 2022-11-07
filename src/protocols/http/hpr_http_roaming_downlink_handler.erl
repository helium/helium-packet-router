%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs
%%% @doc
%%%
%%% @end
%%% Created : 19. Sep 2022 12:44 PM
%%%-------------------------------------------------------------------
-module(hpr_http_roaming_downlink_handler).
-author("jonathanruttenberg").

-include_lib("elli/include/elli.hrl").
-include("hpr_http_roaming.hrl").

-behaviour(elli_handler).

%% Downlink API
-export([
    handle/2,
    handle_event/3,
    send_response/2
]).

%% Downlink Handler ==================================================

handle(Req, Args) ->
    Method = elli_request:method(Req),
    Host = elli_request:get_header(<<"Host">>, Req),
    lager:info("request from [host: ~s]", [Host]),

    lager:debug("request: ~p", [{Method, elli_request:path(Req), Req, Args}]),
    Body = elli_request:body(Req),
    Decoded = jsx:decode(Body),

    case hpr_http_roaming:handle_message(Decoded) of
        ok ->
            {200, [], <<"OK">>};
        {error, _} = Err ->
            lager:error("dowlink handle message error ~p", [Err]),
            {500, [], <<"An error occurred">>};
        {join_accept, {ResponseStream, DownlinkPacket}} ->
            lager:debug("sending downlink [response_stream: ~p]", [ResponseStream]),
            ok = send_response(ResponseStream, DownlinkPacket),
            {200, [], <<"downlink sent: 1">>};
        {downlink, PayloadResponse, {ResponseStream, DownlinkPacket}, {Endpoint, FlowType}} ->
            lager:debug(
                "sending downlink [response_stream: ~p] [response: ~s]",
                [ResponseStream, PayloadResponse]
            ),
            ok = send_response(ResponseStream, DownlinkPacket),
            case FlowType of
                sync ->
                    {200, [], jsx:encode(PayloadResponse)};
                async ->
                    spawn(fun() ->
                        Res = hackney:post(Endpoint, [], jsx:encode(PayloadResponse), [with_body]),
                        lager:debug("async downlink response ~s, Endpoint: ~s", [Res, Endpoint])
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

-spec send_response(
    ResponseStream :: hpr_http_roaming:gateway_stream(),
    DownlinkPacket :: hpr_packet_down:downlink_packet()
) -> ok.
send_response(ResponseStream, DownlinkPacket) ->
    lager:debug("sending response: ~p, pid: ~p", [DownlinkPacket, ResponseStream]),
    ResponseStream ! {http_reply, DownlinkPacket},
    ok.
