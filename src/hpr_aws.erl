-module(hpr_aws).

-define(HEADERS, [{"content-type", "application/json"}]).

%% API
-export([upload_file/4]).

upload_file(AWS, BucketName, FileName, Body) ->
    #{
        s3_scheme := S3Scheme,
        s3_host := S3Host
    } = maps:from_list(application:get_env(hpr, aws_config, [])),
    case
        httpc_aws:put(
            AWS,
            "s3",
            binary_to_list(
                <<S3Scheme/binary, S3Host/binary, "/", BucketName/binary, "/", FileName/binary>>
            ),
            Body,
            ?HEADERS
        )
    of
        {error, Reason, _} ->
            {error, Reason};
        {ok, _} ->
            ok
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
% -ifdef(TEST).
% -include_lib("eunit/include/eunit.hrl").

% -endif.
