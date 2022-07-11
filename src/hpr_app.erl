%%%-------------------------------------------------------------------
%% @doc helium_packet_router public API
%% @end
%%%-------------------------------------------------------------------

-module(hpr_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    hpr_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
