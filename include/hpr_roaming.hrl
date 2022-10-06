%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 19. Sep 2022 12:50 PM
%%%-------------------------------------------------------------------
-author("jonathanruttenberg").

-type protocol_version() :: pv_1_0 | pv_1_1.

-record(http_protocol, {
    endpoint :: binary(),
    flow_type :: async | sync,
    dedupe_timeout :: non_neg_integer(),
    auth_header :: null | binary(),
    protocol_version :: protocol_version()
}).
