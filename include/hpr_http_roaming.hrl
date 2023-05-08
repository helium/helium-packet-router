%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs
%%% @doc
%%%
%%% @end
%%% Created : 19. Sep 2022 12:50 PM
%%%-------------------------------------------------------------------
-author("jonathanruttenberg").

-record(http_protocol, {
    endpoint :: binary(),
    flow_type :: async | sync,
    dedupe_timeout :: non_neg_integer(),
    auth_header :: null | binary(),
    receiver_nsid :: binary()
}).
