-module(hpr_packet_reporter).

-behaviour(gen_server).

-export([
    start_link/0,
    init_ets/0,
    report_packet/1,
    write_packets/1
]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(ETS, hpr_packet_report_ets).

%% 5 minute interval
-define(DEFAULT_REPORT_INTERVAL, 300000).
-define(MAX_FILE_SIZE, 50_000_000).

-record(state, {
    aws_client :: aws_client:aws_client()
}).

%%%===================================================================
%%% API Functions
%%%===================================================================

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [named_table, set]),
    ok.

%% API to report packet
%% TODO: Handle packet data
%% Can be set to pattern match on different inputs
report_packet(ID) ->
    Timestamp = erlang:system_time(),
    true = ets:insert(?ETS, {ID, Timestamp}),
    ok.

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    AWSClient = setup_aws(),
    start_report_interval(self()),
    {ok, #state{
        aws_client = AWSClient
    }}.

handle_call(write, _From, State = #state{}) ->
    Timestamp = erlang:system_time(millisecond),
    FilePath = "./tmp/packetreport.gz",

    {ok, S} = open_tmp_file(FilePath),
    Data = get_packets_by_timestamp(Timestamp),

    lists:foreach(
        fun(Packet) ->
            io:fwrite(S, "~w~n", [Packet])
        end,
        Data
    ),
    file:close(S),

    delete_packets_by_timestamp(Timestamp),

    case filelib:file_size(FilePath) >= ?MAX_FILE_SIZE of
        true -> gen_server:cast(?SERVER, {upload, FilePath});
        false -> skip
    end,
    {reply, ok, State};
handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast({upload, FilePath}, State = #state{aws_client = AWSClient}) ->
    Timestamp = erlang:system_time(millisecond),
    FileName = "packetreport." ++ integer_to_list(Timestamp) ++ ".gz",
    upload_file(AWSClient, FilePath, FileName),
    file:delete(FilePath),
    {noreply, State};
handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info(_Info, State = #state{}) ->
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec setup_aws() -> aws_client:aws_client().
setup_aws() ->
    #{
        access_key_id := AccessKey,
        secret_access_key := Secret,
        aws_region := Region
    } = maps:from_list(application:get_env(hpr, aws_config, [])),
    aws_client:make_client(AccessKey, Secret, Region).

-spec start_report_interval(pid()) -> ok.
start_report_interval(Pid) ->
    Interval = application:get_env(hpr, packet_reporter_report_interval, ?DEFAULT_REPORT_INTERVAL),
    timer:apply_interval(Interval, ?MODULE, write_packets, [Pid]).

-spec write_packets(pid()) -> ok.
write_packets(Pid) ->
    gen_server:call(Pid, write).

-spec open_tmp_file(string()) -> {ok, file:io_device()} | {error, atom()}.
open_tmp_file(FilePath) ->
    case file:open(FilePath, [write, compressed]) of
        {error, Error} ->
            lager:error("failed to open tmp write file: ~p~n", [Error]);
        IODevice ->
            IODevice
    end.

upload_file(AWSClient, Path, FileName) ->
    BucketName = application:get_env(hpr, packet_reporter_bucket),
    {ok, Content} = file:read_file(Path),
    aws_s3:put_object(AWSClient, BucketName, FileName, #{
        <<"Body">> => Content
    }).

%% TODO: Adjust match patterns for packets
-spec get_packets_by_timestamp(integer()) -> [term()].
get_packets_by_timestamp(Timestamp) ->
    ets:select(?ETS, [{{'$1', '$2'}, [{'>', '$2', Timestamp}], [{{'$1', '$2'}}]}]).

-spec delete_packets_by_timestamp(integer()) -> integer().
delete_packets_by_timestamp(Timestamp) ->
    ets:select_delete(?ETS, [{{'$1', '$2'}, [{'>', '$2', Timestamp}], [{{'$1', '$2'}}]}]).

% ------------------------------------------------------------------
% EUNIT Tests
% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

file_test() ->
    Table = ets:new(test_ets, [named_table, set]),
    Timestamp = erlang:system_time(millisecond),
    FilePath = "./tmp/packetreport." ++ integer_to_list(Timestamp) ++ ".txt",

    true = ets:insert(Table, {<<"1A2B3C4D">>, list_to_binary(integer_to_list(Timestamp))}),
    true = ets:insert(Table, {<<"1A2B3C4E">>, list_to_binary(integer_to_list(Timestamp))}),

    {ok, S} = open_tmp_file(FilePath),
    Data = ets:select(Table, [{{'$1', '$2'}, [], ['$$']}]),

    Fun = fun([A, B]) ->
        Prop = [{a, A}, {b, B}],

        io:fwrite(S, "~w~n", [Prop])
    end,
    lists:foreach(Fun, Data),
    file:close(S).

% aws_test() ->
%     AccessKey = <<"">>,
%     SecretKey = <<"">>,
%     Region = <<"">>,
%     Client = aws_client:make_client(AccessKey, SecretKey, Region),
%     {ok, S} = file:open("/tmp/test.txt", [write, compressed]),
%     file:write(S, <<"HelloWorld">>),
%     file:close(S),

%     {ok, Content} = file:read_file("/tmp/test.txt"),
%     io:format("~p~n", [Content]),
%     aws_s3:put_object(Client, <<"test-bucket-hw">>, <<"my-key3">>, #{
%         <<"Body">> => Content
%     }),
%     {ok, Response, _} = aws_s3:get_object(Client, <<"test-bucket-hw">>, <<"my-key3">>),
%     io:format("Test2: ~p~n", [Response]),
%     Content = maps:get(<<"Body">>, Response).

-endif.
