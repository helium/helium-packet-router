-module(hpr_routing_config).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    lookup_eui/2
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(INIT_ASYNC, init_async).
-define(EUI_ETS, hpr_routing_config_eui_ets).
-define(DETS, hpr_routing_config_dets).

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec lookup_eui(AppEUI :: non_neg_integer(), DevEUI :: non_neg_integer()) ->
    [hpr_routing_config_route:route()].
lookup_eui(AppEUI, DevEUI) ->
    Routes0 = ets:lookup(?EUI_ETS, {AppEUI, DevEUI}),
    Routes1 = ets:lookup(?EUI_ETS, {AppEUI, 0}),
    [Route || {_, Route} <- Routes1 ++ Routes0].

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(#{base_dir := BaseDir} = _Args) ->
    {ok, ?DETS} = dets:open_file(?DETS, [{file, BaseDir ++ erlang:atom_to_list(?DETS)}]),
    _ = ets:new(?EUI_ETS, [
        public,
        named_table,
        bag,
        {read_concurrency, true}
    ]),
    ok = init_ets(),
    {ok, #state{}, {continue, ?INIT_ASYNC}}.

handle_continue(?INIT_ASYNC, State) ->
    %% Connect to Config Service to get updates
    {noreply, State};
handle_continue(_Msg, State) ->
    {noreply, State}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    _ = dets:close(?DETS),
    _ = ets:delete(?EUI_ETS),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec init_ets() -> ok.
init_ets() ->
    EUIRoutes = dets:foldl(
        fun({_OUI, Route}, Acc0) ->
            EUIs = hpr_routing_config_route:euis(Route),
            [{{AppEUI, DevEUI}, Route} || {AppEUI, DevEUI} <- EUIs] ++ Acc0
        end,
        [],
        ?DETS
    ),
    true = ets:insert(?EUI_ETS, EUIRoutes),
    ok.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-define(BASE_TMP_DIR, "./_build/test/tmp").
-define(BASE_TMP_DIR_TEMPLATE, "XXXXXXXXXX").

init_test() ->
    BaseDir = tmp_dir("init_test"),
    [Route1, Route2] = init_dets(BaseDir),
    {ok, Pid} = ?MODULE:start_link(#{base_dir => BaseDir}),

    ?assertEqual([Route1], ?MODULE:lookup_eui(1, 1)),
    ?assertEqual([Route1, Route2], ?MODULE:lookup_eui(2, 1)),

    ok = gen_server:stop(Pid),
    ok.

init_dets(BaseDir) ->
    {ok, ?DETS} = dets:open_file(?DETS, [{file, BaseDir ++ erlang:atom_to_list(?DETS)}]),
    Route1 = hpr_routing_config_route:new(
        1, [{1, 10}, {11, 20}], [{1, 1}, {2, 0}], <<"lsn.lora.com>">>, gwmp, 10
    ),
    Route2 = hpr_routing_config_route:new(
        1, [{1, 10}, {11, 20}], [{2, 1}, {3, 0}], <<"lsn.lora.com>">>, gwmp, 10
    ),
    ok = dets:insert(?DETS, [{1, Route1}, {2, Route2}]),
    ok = dets:close(?DETS),
    [Route1, Route2].

tmp_dir(SubDir) ->
    Path = filename:join(?BASE_TMP_DIR, SubDir),
    os:cmd("mkdir -p " ++ Path),
    create_tmp_dir(Path ++ "/" ++ ?BASE_TMP_DIR_TEMPLATE).

-spec create_tmp_dir(list()) -> list().
create_tmp_dir(Path) ->
    nonl(os:cmd("mktemp -d " ++ Path)).

nonl([$\n | T]) -> nonl(T);
nonl([H | T]) -> [H | nonl(T)];
nonl([]) -> [].

-endif.
