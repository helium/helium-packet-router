%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 12. Aug 2022 1:06 PM
%%%-------------------------------------------------------------------
-author("jonathanruttenberg").

-define(WORKER(I), #{
    id => I,
    start => {I, start_link, []},
    restart => temporary,
    shutdown => 1000,
    type => worker,
    modules => [I]
}).
