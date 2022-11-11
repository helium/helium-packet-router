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
    handle_event/3
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
        {join_accept, {PubKeyBin, PacketDown}} ->
            lager:debug("sending downlink [gateway: ~p]", [hpr_utils:gateway_name(PubKeyBin)]),
            case hpr_packet_service:send_packet_down(PubKeyBin, PacketDown) of
                ok ->
                    {200, [], <<"downlink sent: 1">>};
                {error, not_found} ->
                    {404, [], <<"Not Found">>}
            end;
        {downlink, PayloadResponse, {PubKeyBin, PacketDown}, {Endpoint, FlowType}} ->
            lager:debug(
                "sending downlink [gateway: ~p] [response: ~s]",
                [hpr_utils:gateway_name(PubKeyBin), PayloadResponse]
            ),
            case hpr_packet_service:send_packet_down(PubKeyBin, PacketDown) of
                {error, not_found} ->
                    {404, [], <<"Not Found">>};
                ok ->
                    case FlowType of
                        sync ->
                            {200, [], jsx:encode(PayloadResponse)};
                        async ->
                            spawn(fun() ->
                                Res = hackney:post(Endpoint, [], jsx:encode(PayloadResponse), [
                                    with_body
                                ]),
                                lager:debug("async downlink response ~s, Endpoint: ~s", [
                                    Res, Endpoint
                                ])
                            end),
                            {200, [], <<"downlink sent: 2">>}
                    end
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
