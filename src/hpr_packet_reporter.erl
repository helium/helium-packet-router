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
    aws :: pid()
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    {ok, AWS} = setup_aws(),
    {ok, #state{
        aws = AWS
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

-spec setup_aws() -> {ok, AWSPid :: pid()} | {error, any()}.
setup_aws() ->
    {ok, AWS} = httpc_aws:start_link(),
    #{
        access_key_id := AccessKey,
        secret_access_key := Secret,
        aws_region := Region
    } = maps:from_list(application:get_env(hpr, aws_config, [])),
    httpc_aws:set_credentials(AWS, AccessKey, Secret),
    httpc_aws:set_region(AWS, Region),

    {ok, AWS}.
