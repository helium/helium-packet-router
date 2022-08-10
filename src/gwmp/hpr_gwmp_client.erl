%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 08. Aug 2022 3:24 PM
%%%-------------------------------------------------------------------
-module(hpr_gwmp_client).
-author("jonathanruttenberg").

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

-record(packet_router_packet_up_v1_pb,
    % = 1, optional
    {
        payload = <<>> :: iodata() | undefined,
        % = 2, optional, 64 bits
        timestamp = 0 :: non_neg_integer() | undefined,
        % = 3, optional
        signal_strength = 0.0 :: float() | integer() | infinity | '-infinity' | nan | undefined,
        % = 4, optional
        frequency = 0.0 :: float() | integer() | infinity | '-infinity' | nan | undefined,
        % = 5, optional
        datarate = [] :: unicode:chardata() | undefined,
        % = 6, optional
        snr = 0.0 :: float() | integer() | infinity | '-infinity' | nan | undefined,
        % = 7, optional, enum region
        region = 'US915' ::
            'US915'
            | 'EU868'
            | 'EU433'
            | 'CN470'
            | 'CN779'
            | 'AU915'
            | 'AS923_1'
            | 'KR920'
            | 'IN865'
            | 'AS923_2'
            | 'AS923_3'
            | 'AS923_4'
            | 'AS923_1B'
            | 'CD900_1A'
            | integer()
            | undefined,
        % = 8, optional, 64 bits
        hold_time = 0 :: non_neg_integer() | undefined,
        % = 9, optional
        hotspot = <<>> :: iodata() | undefined,
        % = 10, optional
        signature = <<>> :: iodata() | undefined
    }
).

-record(hpr_gwmp_client_state, {
    location :: no_location | {pos_integer(), float(), float()} | undefined,
    pubkeybin :: libp2p_crypto:pubkey_bin(),
    net_id :: non_neg_integer(),
    socket :: pp_udp_socket:socket(),
    push_data = #{} :: #{binary() => {binary(), reference()}},
    pull_data :: {reference(), binary()} | undefined,
    pull_data_timer :: non_neg_integer(),
    shutdown_timer :: {Timeout :: non_neg_integer(), Timer :: reference()}
}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Spawns the server and registers the local name (unique)
-spec start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec init(Args :: term()) ->
    {ok, State :: #hpr_gwmp_client_state{}}
    | {ok, State :: #hpr_gwmp_client_state{}, timeout() | hibernate}
    | {stop, Reason :: term()}
    | ignore.
init([]) ->
    _Packet = #packet_router_packet_up_v1_pb{},
    {ok, #hpr_gwmp_client_state{}}.

%% @private
%% @doc Handling call messages
-spec handle_call(
    Request :: term(),
    From :: {pid(), Tag :: term()},
    State :: #hpr_gwmp_client_state{}
) ->
    {reply, Reply :: term(), NewState :: #hpr_gwmp_client_state{}}
    | {reply, Reply :: term(), NewState :: #hpr_gwmp_client_state{}, timeout() | hibernate}
    | {noreply, NewState :: #hpr_gwmp_client_state{}}
    | {noreply, NewState :: #hpr_gwmp_client_state{}, timeout() | hibernate}
    | {stop, Reason :: term(), Reply :: term(), NewState :: #hpr_gwmp_client_state{}}
    | {stop, Reason :: term(), NewState :: #hpr_gwmp_client_state{}}.
handle_call(_Request, _From, State = #hpr_gwmp_client_state{}) ->
    {reply, ok, State}.

%% @private
%% @doc Handling cast messages
-spec handle_cast(Request :: term(), State :: #hpr_gwmp_client_state{}) ->
    {noreply, NewState :: #hpr_gwmp_client_state{}}
    | {noreply, NewState :: #hpr_gwmp_client_state{}, timeout() | hibernate}
    | {stop, Reason :: term(), NewState :: #hpr_gwmp_client_state{}}.
handle_cast(_Request, State = #hpr_gwmp_client_state{}) ->
    {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec handle_info(Info :: timeout() | term(), State :: #hpr_gwmp_client_state{}) ->
    {noreply, NewState :: #hpr_gwmp_client_state{}}
    | {noreply, NewState :: #hpr_gwmp_client_state{}, timeout() | hibernate}
    | {stop, Reason :: term(), NewState :: #hpr_gwmp_client_state{}}.
handle_info(_Info, State = #hpr_gwmp_client_state{}) ->
    {noreply, State}.

%% @private
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec terminate(
    Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #hpr_gwmp_client_state{}
) -> term().
terminate(_Reason, _State = #hpr_gwmp_client_state{}) ->
    ok.

%% @private
%% @doc Convert process state when code is changed
-spec code_change(
    OldVsn :: term() | {down, term()},
    State :: #hpr_gwmp_client_state{},
    Extra :: term()
) ->
    {ok, NewState :: #hpr_gwmp_client_state{}} | {error, Reason :: term()}.
code_change(_OldVsn, State = #hpr_gwmp_client_state{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
