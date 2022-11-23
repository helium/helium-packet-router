-module(hpr_skf_ets).

-export([
    init/0,
    insert/1,
    delete/1,
    lookup_devaddr/1
]).

-define(ETS, hpr_skf_ets).

-spec init() -> ok.
init() ->
    ?ETS = ets:new(?ETS, [public, named_table, set, {read_concurrency, true}]),
    ok.

-spec insert(SKF :: hpr_skf:skf()) -> ok.
insert(SKF) ->
    DevAddr = hpr_skf:devaddr(SKF),
    Keys = hpr_skf:session_keys(SKF),
    true = ets:insert(?ETS, {DevAddr, Keys}),
    Fields = [
        {devaddr, hpr_utils:int_to_hex(DevAddr)},
        {keys_cnt, erlang:length(Keys)}
    ],
    lager:info(Fields, "inserting SKF"),
    ok.

-spec delete(SKF :: hpr_skf:skf()) -> ok.
delete(SKF) ->
    DevAddr = hpr_skf:devaddr(SKF),
    true = ets:delete(?ETS, DevAddr),
    Fields = [
        {devaddr, hpr_utils:int_to_hex(DevAddr)}
    ],
    lager:info(Fields, "deleted"),
    ok.

-spec lookup_devaddr(Devaddr :: non_neg_integer()) -> {error, not_found} | {ok, list(binary())}.
lookup_devaddr(Devaddr) ->
    case ets:lookup(?ETS, Devaddr) of
        [] -> {error, not_found};
        [{Devaddr, Keys}] -> {ok, Keys}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-endif.
