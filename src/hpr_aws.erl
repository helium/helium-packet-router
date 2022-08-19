-module(hpr_aws).

-define(HEADERS, [{"content-type", "application/json"}]).

%% API
-export([upload_file/5]).

-spec upload_file(
    AWS :: pid(),
    S3Bucket :: binary(),
    FileName :: binary(),
    Body :: binary(),
    Headers :: proplists:proplist()
) ->
    ok | {error, binary()}.
upload_file(AWS, S3Bucket, FileName, Body, Headers) ->
    case
        httpc_aws:put(
            AWS,
            "s3",
            binary_to_list(
                <<"/", S3Bucket/binary, "/", FileName/binary>>
            ),
            Body,
            Headers
        )
    of
        {error, Reason, _} ->
            {error, Reason};
        {ok, _} ->
            ok
    end.
