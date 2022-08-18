-module(hpr_aws).

-define(HEADERS, [{"content-type", "application/json"}]).

%% API
-export([upload_file/4]).

-spec upload_file(AWS :: pid(), S3Bucket :: binary(), FileName :: binary(), Body :: binary()) ->
    ok | {error, binary()}.
upload_file(AWS, S3Bucket, FileName, Body) ->
    case
        httpc_aws:put(
            AWS,
            "s3",
            binary_to_list(
                <<"/", S3Bucket/binary, "/", FileName/binary>>
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
