-module(hpr_utils).

-export([
    hotspot_name/1,
    int_to_hex/1,
    bin_to_hex/1,
    hex_to_bin/1
]).

-spec hotspot_name(PubkeyBin :: libp2p_crypto:pubkey_bin() | string()) -> string().
hotspot_name(PubkeyBin) when is_binary(PubkeyBin) ->
    B58 = libp2p_crypto:bin_to_b58(PubkeyBin),
    hotspot_name(B58);
hotspot_name(B58) when is_list(B58) ->
    {ok, Name} = erl_angry_purple_tiger:animal_name(B58),
    Name.

-spec int_to_hex(Integer :: integer()) -> string().
int_to_hex(Integer) ->
    io_lib:format("~.16B", [Integer]).

-spec bin_to_hex(binary()) -> string().
bin_to_hex(Bin) ->
    lists:flatten([[io_lib:format("~2.16.0b", [X]) || <<X:8>> <= Bin]]).

-spec hex_to_bin(binary()) -> binary().
hex_to_bin(Hex) ->
    <<
        begin
            {ok, [V], []} = io_lib:fread("~16u", [X, Y]),
            <<V:8/integer-little>>
        end
     || <<X:8/integer, Y:8/integer>> <= Hex
    >>.
