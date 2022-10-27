%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs
%%% @doc
%%%
%%% @end
%%% Created : 18. Sep 2022 12:22 PM
%%%-------------------------------------------------------------------
-module(hpr_lorawan).
-author("jonathanruttenberg").

-export([
    index_to_datarate/2,
    datarate_to_index/2
]).

-type temp_datarate_index() :: non_neg_integer().

-spec index_to_datarate(atom(), temp_datarate_index()) -> atom().
index_to_datarate(Region, DRIndex) ->
    Plan = lora_plan:region_to_plan(Region),
    lora_plan:datarate_to_atom(Plan, DRIndex).

-spec datarate_to_index(atom(), atom()) -> integer().
datarate_to_index(Region, DR) ->
    Plan = lora_plan:region_to_plan(Region),
    lora_plan:datarate_to_index(Plan, erlang:atom_to_list(DR)).
