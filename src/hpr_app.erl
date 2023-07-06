%%%-------------------------------------------------------------------
%% @doc helium_packet_router public API
%% @end
%%%-------------------------------------------------------------------

-module(hpr_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    lager:info("starting app"),
    case hpr_sup:start_link() of
        {error, _} = Error ->
            Error;
        OK ->
            hpr_cli_registry:register_cli(),
            OK
    end.

stop(_State) ->
    lager:info("stopping app"),
    ok.
