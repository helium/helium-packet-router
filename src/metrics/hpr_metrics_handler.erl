-module(hpr_metrics_handler).

-behaviour(elli_handler).

-include_lib("elli/include/elli.hrl").

-export([
    handle/2,
    handle_event/3
]).

handle(Req, _Args) ->
    handle(Req#req.method, elli_request:path(Req), Req).

%% Expose /metrics for Prometheus to pull
handle('GET', [<<"metrics">>], _Req) ->
    {ok, [], prometheus_text_format:format()};
handle(_Verb, _Path, _Req) ->
    ignore.

handle_event(_Event, _Data, _Args) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
