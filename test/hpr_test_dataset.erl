%%%-------------------------------------------------------------------
%% @doc
%% Synthetic route sets for load tests, shaped like the ones that make
%% routing expensive.
%%
%% What drives routing cost is not how many session key filters a route has
%% but how many share a DevAddr: `find_routes' reads every key on the packet's
%% DevAddr and tries each against the MIC. So each shape fixes the
%% DevAddr-to-key ratio, not just the total:
%%
%% ```
%% | route                 | devaddrs       | keys each | total   |
%% |-----------------------|----------------|-----------|---------|
%% | route-huge            | 128            | 1,072     | 137,216 |
%% | route-big             | 96             | 850       | 81,600  |
%% | route-mid             | 64             | 880       | 56,320  |
%% | route-gwmp            | 8              | 538       | 4,304   |
%% | route-gwmp-inactive   | same 8         | 0         | 0       |
%% | route-high-devaddr    | 4              | 60        | 240     |
%% | tail (5,277 routes)   | 1-4            | 1-35      | ~238k   |
%% '''
%%
%% `route-gwmp' ignores empty SKFs; `route-gwmp-inactive' shares its DevAddrs
%% with no keys, so it comes back from `find_routes' as an empty route and is
%% rejected at delivery. `route-high-devaddr' sits above 2^31, where a DevAddr
%% stops fitting a signed 32-bit integer.
%%
%% Session keys are derived, not stored, so any key can be rebuilt from its
%% position and a given seed always gives the same dataset:
%%
%% ```
%% session_key = sha256(Seed || RouteID || DevAddr:32 || Index:32)[:16]
%% '''
%%
%% SKFs are generated route by route as they are inserted or streamed: the
%% full set is about half a million, too many to hold as records at once.
%% @end
%%%-------------------------------------------------------------------
-module(hpr_test_dataset).

-export([
    shapes/1,
    build/1, build/2,
    route/2,
    routes/1,
    total_skfs/1,
    session_key/4,
    skf_max_copies/1,
    skfs/2,
    insert/1,
    responses/2,
    stream/2,
    push/1,
    uplink/4, uplink/5,
    uplink_args/4,
    expected/3,
    sample/3,
    find_routes/1,
    wait_counts/1, wait_counts/3,
    quiet_logs/0,
    percentiles/1
]).

-define(SEED, <<"hpr-route-load">>).
%% First DevAddr handed out, and the gap left between two routes' blocks: small
%% enough that a block's neighbours share its devaddr-range index bucket.
-define(BASE_DEVADDR, 16#48000000).
-define(BLOCK_GAP, 16).
-define(HIGH_DEVADDR, 16#FC000000).
-define(TAIL_ROUTES, 5277).
%% Stream messages delivered but not yet taken by the stream worker: its
%% mailbox is kept below this.
-define(STREAM_WINDOW, 5000).
-define(STREAM_CHECK_EVERY, 500).

-type shape() :: #{
    name := string(),
    devaddrs := pos_integer(),
    keys_each := non_neg_integer() | {rand, pos_integer(), pos_integer()},
    protocol => gwmp | http_roaming | packet_router,
    active => boolean(),
    ignore_empty_skf => boolean(),
    share => string(),
    base => non_neg_integer()
}.

-type route_spec() :: #{
    name := string(),
    id := string(),
    route := hpr_route:route(),
    range := {non_neg_integer(), non_neg_integer()},
    %% Keys on each DevAddr of the block, in block order.
    keys := [non_neg_integer()],
    %% Index of the first key on each DevAddr; skfs/2 with a higher one gives
    %% keys that never collide with the dataset's own.
    first_key => non_neg_integer(),
    ignore_empty_skf := boolean()
}.

-type dataset() :: #{seed := binary(), routes := [route_spec()]}.

-export_type([dataset/0, route_spec/0]).

%% ------------------------------------------------------------------
%% Building
%% ------------------------------------------------------------------

-spec shapes(named | full) -> [shape()].
shapes(named) ->
    [
        #{name => "route-huge", devaddrs => 128, keys_each => 1072},
        #{name => "route-big", devaddrs => 96, keys_each => 850},
        #{name => "route-mid", devaddrs => 64, keys_each => 880, protocol => http_roaming},
        #{
            name => "route-gwmp",
            devaddrs => 8,
            keys_each => 538,
            protocol => gwmp,
            ignore_empty_skf => true
        },
        #{
            name => "route-gwmp-inactive",
            devaddrs => 8,
            keys_each => 0,
            protocol => gwmp,
            active => false,
            share => "route-gwmp"
        },
        #{name => "route-high-devaddr", devaddrs => 4, keys_each => 60, base => ?HIGH_DEVADDR}
    ];
shapes(full) ->
    shapes(named) ++
        [
            #{
                name => lists:flatten(io_lib:format("tail-~4..0w", [N])),
                devaddrs => {rand, 1, 4},
                keys_each => {rand, 1, 35}
            }
         || N <- lists:seq(1, ?TAIL_ROUTES)
        ].

-spec build([shape()] | named | full) -> dataset().
build(Shapes) ->
    build(Shapes, #{}).

%% @doc Opts: `seed' (binary), and `server' to point every route at one server
%% (e.g. a local packet router) instead of its shape's protocol.
-spec build([shape()] | named | full, map()) -> dataset().
build(Which, Opts) when is_atom(Which) ->
    build(shapes(Which), Opts);
build(Shapes, Opts) ->
    Seed = maps:get(seed, Opts, ?SEED),
    Rand0 = rand:seed_s(exsss, erlang:phash2(Seed)),
    {Routes, _, _, _} = lists:foldl(
        fun(Shape, {Acc, Next, Index, Rand}) ->
            {Spec, Next1, Rand1} = build_route(Shape, Index, Next, Acc, Seed, Opts, Rand),
            {[Spec | Acc], Next1, Index + 1, Rand1}
        end,
        {[], ?BASE_DEVADDR, 0, Rand0},
        Shapes
    ),
    #{seed => Seed, routes => lists:reverse(Routes)}.

build_route(Shape, Index, Next, Built, Seed, Opts, Rand0) ->
    Name = maps:get(name, Shape),
    {DevAddrs, Rand1} = draw(maps:get(devaddrs, Shape), Rand0),
    {Keys, Rand2} = lists:foldl(
        fun(_, {Acc, R}) ->
            {K, R1} = draw(maps:get(keys_each, Shape), R),
            {[K | Acc], R1}
        end,
        {[], Rand1},
        lists:seq(1, DevAddrs)
    ),
    %% A route sharing another's block is that owner's duplicate: same OUI.
    {Start, Next1, OUI} =
        case Shape of
            #{share := Other} ->
                #{range := {S, _}, route := Owner} = find(Other, lists:reverse(Built)),
                {S, Next, hpr_route:oui(Owner)};
            #{base := Base} ->
                {Base, Next, 1000 + Index};
            _ ->
                {Next, Next + DevAddrs + ?BLOCK_GAP, 1000 + Index}
        end,
    ID = route_id(Seed, Name),
    Server = maps:get(server, Opts, server(maps:get(protocol, Shape, packet_router))),
    IgnoreEmpty = maps:get(ignore_empty_skf, Shape, false),
    Route = hpr_route:test_new(#{
        id => ID,
        net_id => 0,
        oui => OUI,
        server => Server,
        max_copies => 3,
        active => maps:get(active, Shape, true),
        ignore_empty_skf => IgnoreEmpty
    }),
    Spec = #{
        name => Name,
        id => ID,
        route => Route,
        range => {Start, Start + DevAddrs - 1},
        keys => lists:reverse(Keys),
        ignore_empty_skf => IgnoreEmpty
    },
    {Spec, Next1, Rand2}.

draw({rand, Min, Max}, Rand) ->
    {N, Rand1} = rand:uniform_s(Max - Min + 1, Rand),
    {Min + N - 1, Rand1};
draw(N, Rand) when is_integer(N) ->
    {N, Rand}.

server(packet_router) ->
    #{host => "127.0.0.1", port => 8082, protocol => {packet_router, #{}}};
server(gwmp) ->
    #{
        host => "127.0.0.1",
        port => 1700,
        protocol => {gwmp, #{mapping => [#{region => 'US915', port => 1700}]}}
    };
server(http_roaming) ->
    #{host => "127.0.0.1", port => 8090, protocol => {http_roaming, #{}}}.

%% A UUID-shaped id, stable for a seed and name.
route_id(Seed, Name) ->
    <<A:32, B:16, C:16, D:16, E:48, _/binary>> = crypto:hash(sha256, [Seed, Name]),
    lists:flatten(
        io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [A, B, C, D, E])
    ).

%% ------------------------------------------------------------------
%% Reading
%% ------------------------------------------------------------------

-spec route(dataset(), string()) -> route_spec().
route(#{routes := Routes}, Name) ->
    find(Name, Routes).

-spec routes(dataset()) -> [route_spec()].
routes(#{routes := Routes}) ->
    Routes.

-spec total_skfs(dataset() | route_spec()) -> non_neg_integer().
total_skfs(#{routes := Routes}) ->
    lists:sum([total_skfs(R) || R <- Routes]);
total_skfs(#{keys := Keys}) ->
    lists:sum(Keys).

find(Name, Routes) ->
    case [R || #{name := N} = R <- Routes, N =:= Name] of
        [Route] -> Route;
        [] -> erlang:error({unknown_route, Name})
    end.

-spec session_key(binary(), string(), non_neg_integer(), non_neg_integer()) -> binary().
session_key(Seed, RouteID, DevAddr, Index) ->
    <<Key:16/binary, _/binary>> = crypto:hash(
        sha256, [Seed, RouteID, <<DevAddr:32/integer-unsigned-big, Index:32/integer-unsigned-big>>]
    ),
    Key.

%% Varies by key so a test can tell which key a packet matched.
-spec skf_max_copies(non_neg_integer()) -> pos_integer().
skf_max_copies(Index) ->
    1 + (Index rem 5).

%% @doc Every SKF of one route, as records ready for storage or the stream.
-spec skfs(binary(), route_spec()) -> [hpr_skf:skf()].
skfs(Seed, #{id := ID, range := {Start, _}, keys := Keys} = Spec) ->
    First = maps:get(first_key, Spec, 0),
    lists:append([
        [
            hpr_skf:new(#{
                route_id => ID,
                devaddr => Start + Offset,
                session_key => hpr_utils:bin_to_hex_string(
                    session_key(Seed, ID, Start + Offset, I)
                ),
                max_copies => skf_max_copies(I)
            })
         || I <- lists:seq(First, First + N - 1)
        ]
     || {Offset, N} <- lists:zip(lists:seq(0, length(Keys) - 1), Keys)
    ]).

%% ------------------------------------------------------------------
%% Loading
%% ------------------------------------------------------------------

%% @doc Write a dataset straight into storage, the way the stream worker
%% applies it, but without the stream.
-spec insert(dataset()) -> ok.
insert(#{seed := Seed, routes := Routes}) ->
    lists:foreach(
        fun(#{id := ID, route := Route, range := {Start, End}} = Spec) ->
            ok = hpr_route_storage:insert(Route),
            ok = hpr_devaddr_range_storage:insert(
                hpr_devaddr_range:test_new(#{route_id => ID, start_addr => Start, end_addr => End})
            ),
            lists:foreach(fun hpr_skf_storage:insert/1, skfs(Seed, Spec))
        end,
        Routes
    ).

%% @doc A dataset as route stream responses, every one stamped
%% `TimestampSecs': per route, the route, its range, then its keys.
-spec responses(dataset(), non_neg_integer()) -> [hpr_route_stream_res:res()].
responses(#{seed := Seed, routes := Routes}, TimestampSecs) ->
    lists:append([route_responses(Seed, Spec, TimestampSecs) || Spec <- Routes]).

route_responses(Seed, #{id := ID, route := Route, range := {Start, End}} = Spec, TimestampSecs) ->
    Add = fun(Data) ->
        hpr_route_stream_res:test_new(#{action => add, data => Data, timestamp => TimestampSecs})
    end,
    Range = hpr_devaddr_range:test_new(#{route_id => ID, start_addr => Start, end_addr => End}),
    [Add({route, Route}), Add({devaddr_range, Range})] ++
        [Add({skf, SKF}) || SKF <- skfs(Seed, Spec)].

%% @doc Apply a dataset the way the route stream does, every message stamped
%% `TimestampSecs'. See push/1.
-spec stream(dataset(), non_neg_integer()) -> ok.
stream(#{seed := Seed, routes := Routes}, TimestampSecs) ->
    lists:foreach(fun(Spec) -> push(route_responses(Seed, Spec, TimestampSecs)) end, Routes).

%% @doc Hand stream responses to hpr_route_stream_worker exactly as its gRPC
%% client does -- `{data, StreamID, Response}' -- keeping its mailbox under
%% ?STREAM_WINDOW.
%%
%% Not through hpr_test_ics_route_service: grpcbox's server stops sending on a
%% stream after about a thousand of these messages and queues the rest, so a
%% large route never arrives. The worker's own path -- routes applied in
%% order, one process per SKF, storage -- is what these tests load; the mock
%% is still the way in for small volumes, such as resuming from `since'.
%%
%% Paced on the mailbox length rather than on test_counts/0: that call waits
%% behind every queued message, and on a small CI runner busy with lookups it
%% timed out before the worker got to it.
-spec push([hpr_route_stream_res:res()]) -> ok.
push(Resps) ->
    Worker = erlang:whereis(hpr_route_stream_worker),
    _ = lists:foldl(
        fun(Resp, Sent) ->
            ok = wait_window(Worker, Sent),
            Worker ! {data, load_test, Resp},
            Sent + 1
        end,
        0,
        Resps
    ),
    ok.

wait_window(_Worker, Sent) when Sent rem ?STREAM_CHECK_EVERY =/= 0 ->
    ok;
wait_window(Worker, Sent) ->
    case erlang:process_info(Worker, message_queue_len) of
        {message_queue_len, Queued} when Queued > ?STREAM_WINDOW ->
            timer:sleep(20),
            wait_window(Worker, Sent);
        _ ->
            ok
    end.

%% ------------------------------------------------------------------
%% Traffic
%% ------------------------------------------------------------------

-spec uplink(dataset(), string(), non_neg_integer(), non_neg_integer() | random) ->
    hpr_packet_up:packet().
uplink(Dataset, Name, DevAddrIdx, KeyIdx) ->
    uplink(Dataset, Name, DevAddrIdx, KeyIdx, #{}).

%% @doc An uplink from the `DevAddrIdx'th DevAddr of a route, signed with the
%% `KeyIdx'th session key there (so its MIC verifies) or with a random one.
%% `Opts' go to test_utils:uplink_packet_up/1 (fcnt, gateway, sig_fun, ...).
-spec uplink(dataset(), string(), non_neg_integer(), non_neg_integer() | random, map()) ->
    hpr_packet_up:packet().
uplink(Dataset, Name, DevAddrIdx, KeyIdx, Opts) ->
    test_utils:uplink_packet_up(maps:merge(Opts, uplink_args(Dataset, Name, DevAddrIdx, KeyIdx))).

%% @doc The `devaddr' and `nwk_session_key' half of an uplink, for callers that
%% build the packet elsewhere (hpr_test_gateway:send_packet/2).
-spec uplink_args(dataset(), string(), non_neg_integer(), non_neg_integer() | random) ->
    #{devaddr := non_neg_integer(), nwk_session_key := binary()}.
uplink_args(#{seed := Seed} = Dataset, Name, DevAddrIdx, KeyIdx) ->
    #{id := ID, range := {Start, _}} = route(Dataset, Name),
    DevAddr = Start + DevAddrIdx,
    Key =
        case KeyIdx of
            random -> crypto:strong_rand_bytes(16);
            I -> session_key(Seed, ID, DevAddr, I)
        end,
    #{devaddr => DevAddr, nwk_session_key => Key}.

%% @doc What `find_routes' should return for an uplink built by uplink/5,
%% normalised the way find_routes/1 normalises the real answer: the route that
%% holds the key, plus every route on the DevAddr with no keys there that does
%% not ignore empty SKFs.
-spec expected(dataset(), {string(), non_neg_integer()}, non_neg_integer() | random) ->
    {ok, [{string(), non_neg_integer()}]} | {error, invalid_mic}.
expected(Dataset, {Name, DevAddrIdx}, KeyIdx) ->
    #{range := {Start, _}} = route(Dataset, Name),
    DevAddr = Start + DevAddrIdx,
    Covering = [R || #{range := {S, E}} = R <- routes(Dataset), DevAddr >= S, DevAddr =< E],
    Matched =
        case KeyIdx of
            random ->
                [];
            I ->
                #{id := ID} = route(Dataset, Name),
                [{ID, skf_max_copies(I)}]
        end,
    Empty = [
        {ID, 0}
     || #{id := ID, keys := Keys, range := {S, _}, ignore_empty_skf := false} <- Covering,
        lists:nth(DevAddr - S + 1, Keys) =:= 0
    ],
    case Matched ++ Empty of
        [] -> {error, invalid_mic};
        Routes -> {ok, lists:sort(Routes)}
    end.

%% @doc `N' uplinks with what find_routes should say about each. Routes are
%% picked in proportion to their key count, the way traffic falls on them; a
%% `MatchRatio' share carry a seeded key and the rest a random one.
-spec sample(dataset(), pos_integer(), float()) ->
    [{hpr_packet_up:packet(), {ok, list()} | {error, invalid_mic}}].
sample(#{seed := Seed} = Dataset, N, MatchRatio) ->
    Weighted = [{total_skfs(R), R} || R <- routes(Dataset), total_skfs(R) > 0],
    Total = lists:sum([W || {W, _} <- Weighted]),
    {Samples, _} = lists:foldl(
        fun(_, {Acc, Rand0}) ->
            {Pick, Rand1} = rand:uniform_s(Total, Rand0),
            #{name := Name, keys := Keys} = pick(Pick, Weighted),
            {DevAddrIdx0, Rand2} = rand:uniform_s(length(Keys), Rand1),
            DevAddrIdx = DevAddrIdx0 - 1,
            {Coin, Rand3} = rand:uniform_s(Rand2),
            {KeyIdx, Rand4} =
                case lists:nth(DevAddrIdx0, Keys) of
                    0 ->
                        {random, Rand3};
                    _ when Coin > MatchRatio ->
                        {random, Rand3};
                    NKeys ->
                        {K, R4} = rand:uniform_s(NKeys, Rand3),
                        {K - 1, R4}
                end,
            Packet = uplink(Dataset, Name, DevAddrIdx, KeyIdx),
            {[{Packet, expected(Dataset, {Name, DevAddrIdx}, KeyIdx)} | Acc], Rand4}
        end,
        {[], rand:seed_s(exsss, erlang:phash2({Seed, sample}))},
        lists:seq(1, N)
    ),
    lists:reverse(Samples).

pick(N, [{W, R} | _]) when N =< W -> R;
pick(N, [{W, _} | Rest]) -> pick(N - W, Rest).

%% @doc hpr_routing:find_routes/2 with route records swapped for route ids,
%% comparable to expected/3.
-spec find_routes(hpr_packet_up:packet()) ->
    {ok, [{string(), non_neg_integer()}]} | {error, invalid_mic}.
find_routes(PacketUp) ->
    case hpr_routing:find_routes(hpr_packet_up:type(PacketUp), PacketUp) of
        {ok, Routes} ->
            {ok,
                lists:sort([
                    {hpr_route:id(hpr_route_ets:route(R)), MaxCopies}
                 || {R, MaxCopies} <- Routes
                ])};
        Error ->
            Error
    end.

%% ------------------------------------------------------------------
%% Waiting and measuring
%% ------------------------------------------------------------------

-spec wait_counts(dataset()) -> ok | {fail, term()}.
wait_counts(Dataset) ->
    wait_counts(Dataset, 600, 500).

%% @doc Wait until storage holds exactly this dataset's routes, ranges and keys.
-spec wait_counts(dataset(), pos_integer(), pos_integer()) -> ok | {fail, term()}.
wait_counts(Dataset, Retries, SleepMs) ->
    test_utils:wait_until(
        fun() ->
            case [R || R <- routes(Dataset), not loaded(R)] of
                [] -> true;
                [First | _] = Missing -> {false, {not_loaded, length(Missing), found(First)}}
            end
        end,
        Retries,
        SleepMs
    ).

%% What storage holds for a route, against what the dataset says it should.
found(#{name := Name, id := ID} = Spec) ->
    #{
        route => Name,
        stored => element(1, hpr_route_storage:lookup(ID)),
        ranges => hpr_devaddr_range_storage:count_for_route(ID),
        skfs => {hpr_skf_storage:count_route(ID), expected, total_skfs(Spec)}
    }.

loaded(#{id := ID} = Spec) ->
    case hpr_route_storage:lookup(ID) of
        {ok, _} ->
            hpr_devaddr_range_storage:count_for_route(ID) =:= 1 andalso
                hpr_skf_storage:count_route(ID) =:= total_skfs(Spec);
        {error, not_found} ->
            false
    end.

%% @doc Log warnings and up only. test_utils logs at debug (and CI adds the
%% console), and both HPR and the mock iot-config service log a line per SKF:
%% half a million of them for the full dataset, which the mock alone cannot
%% send faster than a few dozen a second.
-spec quiet_logs() -> ok.
quiet_logs() ->
    lists:foreach(
        fun
            ({lager_file_backend, File}) -> lager:set_loglevel(lager_file_backend, File, warning);
            (lager_console_backend) -> lager:set_loglevel(lager_console_backend, warning);
            (_) -> ok
        end,
        gen_event:which_handlers(lager_event)
    ).

-spec percentiles([number()]) -> #{atom() => number()}.
percentiles([]) ->
    #{n => 0};
percentiles(Values) ->
    Sorted = lists:sort(Values),
    N = length(Sorted),
    At = fun(P) -> lists:nth(max(1, min(N, ceil(P * N))), Sorted) end,
    #{n => N, p50 => At(0.50), p90 => At(0.90), p99 => At(0.99), max => lists:last(Sorted)}.
