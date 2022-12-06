-module(hpr_skf_ets).

-include("../autogen/config_pb.hrl").

-export([
    init/0,
    insert/1,
    delete/1,
    lookup_devaddr/1
]).

-define(ETS, hpr_skf_ets).

-spec init() -> ok.
init() ->
    ?ETS = ets:new(?ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true},
        {keypos, #config_session_key_filter_v1_pb.devaddr}
    ]),
    ok.

-spec insert(SKF :: hpr_skf:skf()) -> ok.
insert(SKF) ->
    true = ets:insert(?ETS, SKF),
    lager:info(
        [
            {devaddr, hpr_utils:int_to_hex(hpr_skf:devaddr(SKF))},
            {keys_cnt, hpr_skf:session_keys(SKF)}
        ],
        "inserting SKF"
    ),
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

-spec lookup_devaddr(DevAddr :: non_neg_integer()) -> {error, not_found} | {ok, hpr_skf:skf()}.
lookup_devaddr(DevAddr) ->
    case ets:lookup(?ETS, DevAddr) of
        [] -> {error, not_found};
        [SKF] -> {ok, SKF}
    end.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {setup, fun setup/0,
        {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
            ?_test(test_insert()),
            ?_test(test_delete()),
            ?_test(test_lookup_devaddr())
        ]}}.

setup() ->
    ok.

foreach_setup() ->
    ?MODULE:init(),
    ok.

foreach_cleanup(ok) ->
    true = ets:delete(?ETS),
    ok.

test_insert() ->
    SKF = new_skf(),
    ?assertEqual(ok, ?MODULE:insert(SKF)),
    DevAddr = hpr_skf:devaddr(SKF),
    ?assertEqual(
        [SKF], ets:lookup(?ETS, DevAddr)
    ),
    ok.

test_delete() ->
    SKF = new_skf(),
    ?assertEqual(ok, ?MODULE:insert(SKF)),
    DevAddr = hpr_skf:devaddr(SKF),
    ?assertEqual(
        [SKF], ets:lookup(?ETS, DevAddr)
    ),
    ?assertEqual(ok, ?MODULE:delete(SKF)),
    ?assertEqual(
        [], ets:lookup(?ETS, DevAddr)
    ),
    ok.

test_lookup_devaddr() ->
    SKF = new_skf(),
    ?assertEqual(ok, ?MODULE:insert(SKF)),
    DevAddr = hpr_skf:devaddr(SKF),
    ?assertEqual(
        {ok, SKF}, ?MODULE:lookup_devaddr(DevAddr)
    ),
    ok.

new_skf() ->
    DevAddr = 16#00000000,
    SessionKeys = [crypto:strong_rand_bytes(16)],
    SKFMap = #{
        devaddr => DevAddr,
        session_keys => SessionKeys
    },
    hpr_skf:test_new(SKFMap).

-endif.
