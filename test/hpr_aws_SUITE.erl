-module(hpr_aws_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    s3_test/1
]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        s3_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_suite(Config) ->
    {ok, AWS} = httpc_aws:start_link(),
    #{
        access_key_id => AccessKey,
        secret_access_key => Secret,
        aws_region => Region
    } = maps:from_list(application:get_env(hpr, aws_config, [])),
    httpc_aws:set_credentials(AWS, AccessKey, Secret),
    httpc_aws:set_region(AWS, Region),
    [
        {aws, AWS}
        | Config
    ].
init_per_testcase(_TestCase, Config) -> Config.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_suite(Config) ->
    AWS = proplists:get_value(aws, Config),
    exit(AWS, normal),
    Config.
end_per_testcase(_TestCase, Config) -> Config.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

s3_test(Config) ->
    AWS = proplists:get_value(aws, Config),
    hpr_aws:upload_file(AWS, <<"test-bucket">>, <<"test.txt">>, <<"Hello World">>).
