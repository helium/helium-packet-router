-module(hpr_packet_reporter).

-behaviour(gen_server).

-export([start_link/0]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

-record(state, {
    aws_client :: aws_client:aws_client()
}).

%%%===================================================================
%%% API
%%%===================================================================

%% TODO:
%%
%% API to report packet
%% report_packet() -> ok.

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    AWSClient = setup_aws(),
    {ok, #state{
        aws_client = AWSClient
    }}.

handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

%% Handle store to ETS
%% If amount of data is above configured value
%% Handle upload to S3
%% To possibly scale, write to ETS can be done separately and packet reporter could check ETS regularly
%% (if number of packets/file size above configured value) and perform upload?
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

% ------------------------------------------------------------------
% EUNIT Tests
% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

aws_test() ->
    AccessKey = <<"">>,
    SecretKey = <<"">>,
    Region = <<"">>,
    Client = aws_client:make_client(AccessKey, SecretKey, Region),
    {ok, S} = file:open("/tmp/test.txt", [write, compressed]),
    file:write(S, <<"HelloWorld">>),
    file:close(S),

    {ok, Content} = file:read_file("/tmp/test.txt"),
    io:format("~p~n", [Content]),
    aws_s3:put_object(Client, <<"test-bucket-hw">>, <<"my-key3">>, #{
        <<"Body">> => Content
    }),
    {ok, Response, _} = aws_s3:get_object(Client, <<"test-bucket-hw">>, <<"my-key3">>),
    io:format("Test2: ~p~n", [Response]),
    Content = maps:get(<<"Body">>, Response).

-endif.
