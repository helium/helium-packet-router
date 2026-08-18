%%%-------------------------------------------------------------------
%% @doc
%% S3 client construction shared by the report uploaders
%% (`hpr_packet_reporter' and `hpr_gateway_liveness_reporter').
%%
%% Each reporter uploads to its own bucket, and the two may live on different
%% providers with different credentials. `aws_credentials' is a single VM-wide
%% gen_server holding exactly one credential set, so it cannot serve both on its
%% own. The rule is therefore:
%%
%%   `aws_endpoint' set  -> talk to that endpoint using this reporter's own
%%                          `aws_access_key_id' / `aws_secret_access_key'.
%%   `aws_endpoint' unset -> real AWS S3 in `aws_region', credentials from
%%                          `aws_credentials:get_credentials/0'.
%%
%% Clients come from the `aws_client' constructors rather than hand-built maps
%% (`aws_client:aws_client()' is opaque). One override is unavoidable:
%% `make_local_client/4' is the only constructor taking a custom endpoint, and
%% it hardcodes `proto => http', so https endpoints patch that one field.
%% Its `region => <<"local">>' is also what selects path-style addressing in
%% `aws_s3' (bucket in the path, endpoint used verbatim as the host).
%% @end
%%%-------------------------------------------------------------------
-module(hpr_s3_client).

-export([
    from_config/1,
    client/1,
    bucket/1,
    credential_source/1
]).

-export_type([config/0, opts/0]).

-ifdef(TEST).

-export([normalize/1, parse_endpoint/1]).

-endif.

-type config() :: #{
    aws_bucket := binary(),
    aws_region => binary(),
    aws_endpoint => binary(),
    aws_access_key_id => binary(),
    aws_secret_access_key => binary(),
    atom() => term()
}.

%% Where this reporter uploads, resolved once at init.
-type target() ::
    {endpoint, Proto :: binary(), Host :: binary(), Port :: binary(), Key :: binary(),
        Secret :: binary()}
    | {aws, Region :: binary()}.

-type opts() :: #{bucket := binary(), target := target()}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

%% @doc Resolve a reporter's config. Call once from `init/1' so a bad config
%% fails at boot rather than on the next upload -- which for the liveness
%% reporter is the next midnight.
-spec from_config(config()) -> opts().
from_config(#{aws_bucket := Bucket} = Config) ->
    #{bucket => Bucket, target => target(Config)}.

-spec client(opts()) -> aws_client:aws_client().
client(#{target := {endpoint, Proto, Host, Port, Key, Secret}}) ->
    %% make_local_client/4 takes (Key, Secret, Port, Endpoint) and pins
    %% proto => http; patch it for https endpoints.
    Client = aws_client:make_local_client(Key, Secret, Port, Host),
    case Proto of
        <<"http">> -> Client;
        _ -> Client#{proto => Proto}
    end;
client(#{target := {aws, Region}, bucket := Bucket}) ->
    %% Re-read every upload so rotated (STS) credentials are picked up.
    case aws_credentials:get_credentials() of
        undefined ->
            erlang:error({no_aws_credentials, Bucket});
        #{access_key_id := Key, secret_access_key := Secret, token := Token} ->
            aws_client:make_temporary_client(Key, Secret, Token, Region);
        #{access_key_id := Key, secret_access_key := Secret} ->
            %% Static credentials carry no `token' key at all.
            aws_client:make_client(Key, Secret, Region)
    end.

-spec bucket(opts()) -> binary().
bucket(#{bucket := Bucket}) ->
    Bucket.

%% @doc Logged at startup so the migration onto per-bucket credentials is
%% greppable without waiting for an upload.
-spec credential_source(opts()) -> static | provider.
credential_source(#{target := {endpoint, _, _, _, _, _}}) -> static;
credential_source(#{target := {aws, _}}) -> provider.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec target(config()) -> target().
target(Config) ->
    case normalize(maps:get(aws_endpoint, Config, undefined)) of
        undefined ->
            {aws, required(aws_region, Config)};
        Endpoint ->
            {Proto, Host, Port} = parse_endpoint(Endpoint),
            {endpoint, Proto, Host, Port, required(aws_access_key_id, Config),
                required(aws_secret_access_key, Config)}
    end.

%% An endpoint implies this reporter authenticates as itself, so its credentials
%% are mandatory: falling back to the global provider here would authenticate a
%% custom endpoint with an unrelated identity on nothing more than a typo. The
%% raised term names the missing key and never carries a value.
-spec required(atom(), config()) -> binary().
required(Key, Config) ->
    case normalize(maps:get(Key, Config, undefined)) of
        undefined -> erlang:error({missing_s3_config, Key});
        Value -> Value
    end.

%% @doc Treat an unset value as absent.
%%
%% relx substitutes an unset ${VAR} to the empty string, but older versions
%% leave the literal `${VAR}' in place, so both count as unset. Trailing
%% whitespace is trimmed because a secret pasted from a dashboard commonly
%% carries a newline, which would otherwise surface as an opaque
%% SignatureDoesNotMatch rather than as a configuration error.
-spec normalize(binary() | string() | undefined) -> binary() | undefined.
normalize(undefined) ->
    undefined;
normalize(Value) when is_list(Value) ->
    normalize(erlang:list_to_binary(Value));
normalize(Value) when is_binary(Value) ->
    case string:trim(Value) of
        <<>> ->
            undefined;
        Trimmed ->
            case binary:match(Trimmed, <<"${">>) of
                nomatch -> Trimmed;
                _ -> undefined
            end
    end.

%% Split <<"https://host:port">> into {Proto, Host, Port}. The scheme is
%% optional and defaults to https; the port defaults to 443 for https and 80
%% for http.
-spec parse_endpoint(binary()) -> {binary(), binary(), binary()}.
parse_endpoint(Endpoint) ->
    {Proto, Rest} =
        case Endpoint of
            <<"https://", R/binary>> -> {<<"https">>, R};
            <<"http://", R/binary>> -> {<<"http">>, R};
            R -> {<<"https">>, R}
        end,
    DefaultPort =
        case Proto of
            <<"https">> -> <<"443">>;
            <<"http">> -> <<"80">>
        end,
    Trimmed = erlang:iolist_to_binary(string:trim(Rest, trailing, "/")),
    {Host, Port} =
        case binary:split(Trimmed, <<":">>) of
            [H, P] -> {H, P};
            [H] -> {H, DefaultPort}
        end,
    {Proto, Host, Port}.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-define(ENDPOINT_CONFIG, #{
    aws_bucket => <<"test-bucket">>,
    aws_endpoint => <<"https://t3.storageapi.dev">>,
    aws_access_key_id => <<"railway-key">>,
    aws_secret_access_key => <<"railway-secret">>
}).

normalize_test() ->
    ?assertEqual(undefined, normalize(undefined)),
    ?assertEqual(undefined, normalize(<<>>)),
    ?assertEqual(undefined, normalize(<<"   ">>)),
    %% relx leaves the literal form in some versions
    ?assertEqual(undefined, normalize(<<"${HPR_PACKET_REPORTER_AWS_ENDPOINT}">>)),
    ?assertEqual(<<"real">>, normalize(<<"real">>)),
    ?assertEqual(<<"real">>, normalize("real")),
    %% a secret pasted from a dashboard commonly carries a newline
    ?assertEqual(<<"secret">>, normalize(<<"secret\n">>)),
    ok.

parse_endpoint_test() ->
    ?assertEqual(
        {<<"https">>, <<"t3.storageapi.dev">>, <<"443">>},
        parse_endpoint(
            <<"t3.storageapi.dev">>
        )
    ),
    ?assertEqual(
        {<<"https">>, <<"t3.storageapi.dev">>, <<"443">>},
        parse_endpoint(
            <<"https://t3.storageapi.dev">>
        )
    ),
    ?assertEqual({<<"http">>, <<"localhost">>, <<"80">>}, parse_endpoint(<<"http://localhost">>)),
    ?assertEqual(
        {<<"http">>, <<"localhost">>, <<"9000">>},
        parse_endpoint(
            <<"http://localhost:9000">>
        )
    ),
    ?assertEqual(
        {<<"https">>, <<"example.com">>, <<"443">>},
        parse_endpoint(
            <<"https://example.com/">>
        )
    ),
    ok.

%% An endpoint selects this reporter's own credentials and never consults the
%% VM-wide aws_credentials gen_server, which is not running here.
endpoint_client_test() ->
    ?assertNot(erlang:is_pid(erlang:whereis(aws_credentials))),
    Client = client(from_config(?ENDPOINT_CONFIG)),
    ?assertEqual(<<"railway-key">>, aws_client:access_key_id(Client)),
    ?assertEqual(<<"railway-secret">>, aws_client:secret_access_key(Client)),
    ?assertEqual(<<"t3.storageapi.dev">>, aws_client:endpoint(Client)),
    ?assertEqual(<<"https">>, aws_client:proto(Client)),
    ?assertEqual(<<"443">>, aws_client:port(Client)),
    %% path-style addressing in aws_s3 keys off this
    ?assertEqual(<<"local">>, aws_client:region(Client)),
    %% never inherit an unrelated STS token: SigV4 signs that header
    ?assertNot(maps:is_key(token, Client)),
    ok.

%% http endpoints (rustfs in CT) keep the constructor's proto untouched.
endpoint_http_client_test() ->
    Client = client(
        from_config(?ENDPOINT_CONFIG#{aws_endpoint => <<"http://localhost:9000">>})
    ),
    ?assertEqual(
        aws_client:make_local_client(
            <<"railway-key">>, <<"railway-secret">>, <<"9000">>, <<"localhost">>
        ),
        Client
    ).

%% An endpoint without credentials must fail loudly rather than quietly
%% authenticate as somebody else.
endpoint_requires_credentials_test() ->
    ?assertError(
        {missing_s3_config, aws_access_key_id},
        from_config(maps:remove(aws_access_key_id, ?ENDPOINT_CONFIG))
    ),
    ?assertError(
        {missing_s3_config, aws_secret_access_key},
        from_config(maps:remove(aws_secret_access_key, ?ENDPOINT_CONFIG))
    ),
    %% an unsubstituted value counts as missing
    ?assertError(
        {missing_s3_config, aws_secret_access_key},
        from_config(?ENDPOINT_CONFIG#{
            aws_secret_access_key => <<"${HPR_PACKET_REPORTER_AWS_SECRET}">>
        })
    ),
    ok.

no_endpoint_requires_region_test() ->
    ?assertError(
        {missing_s3_config, aws_region},
        from_config(#{aws_bucket => <<"b">>})
    ),
    %% an unsubstituted endpoint is absent, not a host
    ?assertError(
        {missing_s3_config, aws_region},
        from_config(#{aws_bucket => <<"b">>, aws_endpoint => <<"${UNSET}">>})
    ),
    ok.

with_mocked_credentials(Credentials, Fun) ->
    meck:new(aws_credentials, [non_strict, no_link]),
    meck:expect(aws_credentials, get_credentials, fun() -> Credentials end),
    try
        Fun()
    after
        meck:unload(aws_credentials)
    end.

aws_opts() ->
    from_config(#{aws_bucket => <<"test-bucket">>, aws_region => <<"us-west-2">>}).

%% Static (env/file) credentials have no `token' key at all. Matching on
%% `token :=' here is what used to crash the liveness reporter every report.
aws_client_without_token_test() ->
    with_mocked_credentials(
        #{
            credential_provider => aws_credentials_env,
            access_key_id => <<"static-key">>,
            secret_access_key => <<"static-secret">>
        },
        fun() ->
            Client = client(aws_opts()),
            ?assertEqual(
                aws_client:make_client(<<"static-key">>, <<"static-secret">>, <<"us-west-2">>),
                Client
            ),
            ?assertNot(maps:is_key(token, Client))
        end
    ).

aws_client_with_token_test() ->
    with_mocked_credentials(
        #{
            credential_provider => aws_credentials_ec2,
            access_key_id => <<"sts-key">>,
            secret_access_key => <<"sts-secret">>,
            token => <<"sts-token">>
        },
        fun() ->
            ?assertEqual(<<"sts-token">>, aws_client:token(client(aws_opts())))
        end
    ).

aws_client_unavailable_test() ->
    with_mocked_credentials(undefined, fun() ->
        ?assertError({no_aws_credentials, <<"test-bucket">>}, client(aws_opts()))
    end).

credential_source_test() ->
    ?assertEqual(static, credential_source(from_config(?ENDPOINT_CONFIG))),
    ?assertEqual(provider, credential_source(aws_opts())),
    ok.

-endif.
