-module(hpr_cli_registry).

-define(CLI_MODULES, [
    hpr_cli_config,
    hpr_cli_info
]).

-export([register_cli/0]).

register_cli() ->
    clique:register(?CLI_MODULES).
