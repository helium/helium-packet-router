%%%-------------------------------------------------------------------
%% @doc helium_packet_router public API
%% @end
%%%-------------------------------------------------------------------

-module(hpr_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    lager:info("starting app"),
    hpr_sup:start_link().

stop(_State) ->
    lager:info("stopping app"),
    ok.
