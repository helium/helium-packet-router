-module(hpr_router_stream_manager).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    get_stream/2,
    start_link/3
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-type lns() :: binary().
-type from() :: {pid(), any()}.
-type service() :: atom().
-type rpc() :: atom().

-record(state, {
    stream_table :: ets:tab(),
    service :: atom(),
    rpc :: atom(),
    decode_module :: module()
}).

-record(stream, {
    gateway_router_map :: {libp2p_crypto:pubkey_bin(), lns()},
    router_stream :: grpc_client:client_stream()
}).

-define(STREAM_TAB, hpr_router_stream_manager_tab).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(service(), rpc(), module()) -> {ok, pid()}.
%% @doc Start this service.
start_link(Service, Rpc, DecodeModule) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Service, Rpc, DecodeModule], []).

-spec get_stream(PubKeyBin :: libp2p_crypto:pubkey_bin(), Lns :: lns()) ->
    {ok, grpc_client:client_stream()} | {error, any()}.
%% @doc Get a stream for PubKeyBin to the Router at Lns or create a new
%% stream if this one doesn't exist.
get_stream(PubKeyBin, Lns) ->
    gen_server:call(?MODULE, {get_stream, PubKeyBin, Lns}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

-spec init(list()) -> {ok, #state{}}.
init([Service, Rpc, DecodeModule]) ->
    StreamTab = init_ets(),
    {
        ok,
        #state{
            stream_table = StreamTab,
            service = Service,
            rpc = Rpc,
            decode_module = DecodeModule
        }
    }.

-spec handle_call({get_stream, libp2p_crypto:pubkey_bin(), lns()}, from(), #state{}) ->
    {reply, {ok, grpc_client:client_stream()} | {error, any()}, #state{}}.
handle_call(
    {get_stream, PubKeyBin, Lns},
    _From,
    #state{
        stream_table = StreamTab,
        service = Service,
        rpc = Rpc,
        decode_module = DecodeModule
    } = State
) ->
    Reply = do_get_stream(PubKeyBin, Lns, Service, Rpc, DecodeModule, StreamTab),
    {reply, Reply, State}.

-spec handle_cast(Msg, #state{}) -> {stop, {unimplemented_cast, Msg}, #state{}}.
handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

handle_info({{'DOWN', {PubKeyBin, Lns} = Key}, _, process, RouterStream, Reason}, State) ->
    lager:info(
        [
            {gateway, hpr_utils:gateway_name(PubKeyBin)},
            {lns, Lns}
        ],
        "stream ~p went down ~p",
        [RouterStream, Reason]
    ),
    true = ets:delete(?STREAM_TAB, Key),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("unknown handle_info ~p", [_Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec init_ets() -> ets:tab().
init_ets() ->
    init_ets([]).

-spec init_ets(list()) -> ets:tab().
init_ets(Options) ->
    % [#stream{}]
    ets:new(
        ?STREAM_TAB,
        Options ++ [public, named_table, set, {keypos, #stream.gateway_router_map}]
    ).

%% @doc Return exising stream. Create a new stream if there isn't one.
-spec do_get_stream(libp2p_crypto:pubkey_bin(), lns(), service(), rpc(), module(), ets:tab()) ->
    {ok, grpc_client:client_stream()} | {error, any()}.
do_get_stream(PubKeyBin, Lns, Service, Rpc, DecodeModule, StreamTab) ->
    case ets:lookup(StreamTab, {PubKeyBin, Lns}) of
        [] ->
            case grpc_stream_connect(Lns, Service, Rpc, DecodeModule) of
                {error, _} = Error ->
                    Error;
                {ok, RouterStreamPid} ->
                    {ok, _RelayPid} = hpr_router_relay:start(PubKeyBin, RouterStreamPid),
                    ets:insert(StreamTab, #stream{
                        gateway_router_map = {PubKeyBin, Lns},
                        router_stream = RouterStreamPid
                    }),
                    _ = erlang:monitor(process, RouterStreamPid, [{tag, {'DOWN', {PubKeyBin, Lns}}}]),
                    {ok, RouterStreamPid}
            end;
        [StreamRecord] ->
            {ok, StreamRecord#stream.router_stream}
    end.

-spec grpc_stream_connect(lns(), service(), rpc(), module()) ->
    {ok, grpc_client:client_stream()} | {error, any()}.
grpc_stream_connect(Lns, Service, Rpc, DecodeModule) ->
    ConnectionResult = hpr_router_connection_manager:get_connection(Lns),
    maybe_create_grpc_stream(ConnectionResult, Service, Rpc, DecodeModule).

-spec maybe_create_grpc_stream
    ({ok, grpc_client:connection()}, service(), rpc(), module()) ->
        {ok, grpc_client:client_stream()};
    ({error, Reason}, service(), rpc(), module()) -> {error, Reason}.
maybe_create_grpc_stream({ok, GrpcConnection}, Service, Rpc, DecodeModule) ->
    grpc_client:new_stream(GrpcConnection, Service, Rpc, DecodeModule);
maybe_create_grpc_stream({error, _} = Error, _, _, _) ->
    Error.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {setup, fun setup/0,
        {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
            ?_test(test_get_stream())
        ]}}.

setup() ->
    init_ets([named_table, public]),
    ok.

foreach_setup() ->
    ok.

foreach_cleanup(ok) ->
    meck:unload(),
    ok.

test_get_stream() ->
    meck:new(grpc_client),
    meck:new(hpr_router_connection_manager),
    meck:new(hpr_router_relay),
    PubKeyBin = <<"PubKeyBin">>,
    Lns1 = <<"1fakelns">>,
    Lns2 = <<"2fakelns">>,
    Service = fake_service,
    Rpc = fake_rpc,
    DecodeModule = fake_decode_module,
    FakeGrpcConnection = #{fake => connection},
    FakeGrpcStream = self(),

    meck:expect(
        hpr_router_connection_manager,
        get_connection,
        ['_'],
        {ok, FakeGrpcConnection}
    ),
    meck:expect(
        grpc_client,
        new_stream,
        [FakeGrpcConnection, Service, Rpc, DecodeModule],
        {ok, FakeGrpcStream}
    ),
    meck:expect(
        hpr_router_relay, start, [PubKeyBin, FakeGrpcStream], {ok, self()}
    ),

    % First get_stream opens connection and stream.
    {ok, GrpcStream0} = do_get_stream(
        PubKeyBin, Lns1, Service, Rpc, DecodeModule, ?STREAM_TAB
    ),

    ?assertEqual(FakeGrpcStream, GrpcStream0),
    ?assertEqual(1, meck:num_calls(hpr_router_connection_manager, get_connection, 1)),
    ?assertEqual(1, meck:num_calls(grpc_client, new_stream, 4)),

    % second get_stream doesn't reconnect
    {ok, _GrpcStream1} = do_get_stream(
        PubKeyBin, Lns1, Service, Rpc, DecodeModule, ?STREAM_TAB
    ),
    ?assertEqual(1, meck:num_calls(hpr_router_connection_manager, get_connection, 1)),
    ?assertEqual(1, meck:num_calls(grpc_client, new_stream, 4)),

    % different Lns with the same gateway connects again
    {ok, _GrpcStream2} = do_get_stream(
        PubKeyBin, Lns2, Service, Rpc, DecodeModule, ?STREAM_TAB
    ),
    ?assertEqual(2, meck:num_calls(hpr_router_connection_manager, get_connection, 1)),
    ?assertEqual(2, meck:num_calls(grpc_client, new_stream, 4)).

-endif.
