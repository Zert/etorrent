%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Manage the rates of each connected peer
%% <p>This module implements a bookkeeping server. The server has
%% ETS tables which is used to save the current upload and download
%% rate as well as the state of each peer.</p>
%% @end
%% @todo module is a candidate for renaming. etorrent_g_peer_state.
-module(etorrent_rate_mgr).

-include("rate_mgr.hrl").
-include("etorrent_rate.hrl").
-include("log.hrl").

-behaviour(gen_server).

-define(DEFAULT_SNUB_TIME, 30).

%% API
-export([start_link/0,

         choke/2, unchoke/2, interested/2, not_interested/2,
         local_choke/2, local_unchoke/2,

         recv_rate/4, send_rate/3,

         get_state/2,
         get_torrent_rate/2,

         fetch_recv_rate/2,
         fetch_send_rate/2,
         select_state/2, pids_interest/2,

         global_rate/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(peer_state, {pid :: {pos_integer() | '_', pid() | '_'},
                     choke_state = choked :: choked | unchoked | '_',
                     interest_state = not_interested :: interested | not_interested | '_',
                     local_choke = true :: boolean() | '_'}).

-record(state, { recv,
                 send,
                 state,

                 global_recv,
                 global_send}).

-define(SERVER, ?MODULE).
-ignore_xref([{'start_link', 0}]).

%% ====================================================================

%% @doc Start the server
%% @end
-spec start_link() -> ignore | {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Update a peer state to `choked'
%% <p><em>Clarification:</em> This state is what the remote peer has
%% done to us.</p>
%% @end
-spec choke(integer(), pid()) -> ok.
choke(Id, Pid) ->
    alter_state(choke, Id, Pid).

%% @doc Update a peer state to `unchoked'
%% <p><em>Clarification:</em> This state is what the remote peer has
%% done to us.</p>
%% @end
-spec unchoke(integer(), pid()) -> ok.
unchoke(Id, Pid) ->
    alter_state(unchoke, Id, Pid).

%% @doc Update a peer state to `interested'
%% <p><em>Clarification:</em> This state is what the remote peer
%% thinks of us.</p>
%% @end
-spec interested(integer(), pid()) -> ok.
interested(Id, Pid) ->
    alter_state(interested, Id, Pid).

%% @doc Update a peer state to `not_interested'
%% <p><em>Clarification:</em> This state is what the remote peer
%% thinks of us.</p>
%% @end
-spec not_interested(integer(), pid()) -> ok.
not_interested(Id, Pid) ->
    alter_state(not_interested, Id, Pid).

%% @doc Update state: we `choke' the peer
%% @end
-spec local_choke(integer(), pid()) -> ok.
local_choke(Id, Pid) ->
    alter_state(local_choke, Id, Pid).

%% @doc Update state: we no longer `choke' the peer
%% @end
-spec local_unchoke(integer(), pid()) -> ok.
local_unchoke(Id, Pid) ->
    alter_state(local_unchoke, Id, Pid).

%% @doc Get the current state of a peer
%% <p>This function return `{value, Snubbed, PL}' where `Snubbed' is a
%% boolean() telling us whether the peer has been snubbed or not. `PL'
%% is a property list with these fields:
%% <dl>
%%  <dt>`pid'</dt>
%%    <dd>The pid of the peer</dd>
%%  <dt>`choke_state'</dt>
%%    <dd>boolean() - is the remote choking us?</dd>
%%  <dt>`interest_state'</dt>
%%    <dd>Is the peer interested in us?</dd>
%%  <dt>`local_choke'</dt>
%%    <dd>Are we currently choking the peer?</dd>
%% </dl></p>
%% @end
-spec get_state(integer(), pid()) -> {value, boolean(), [{atom(), term()}]}.
get_state(Id, Who) ->
    P = case ets:lookup(etorrent_peer_state, {Id, Who}) of
            [] -> #peer_state{}; % Pick defaults
            [Ps] -> Ps
        end,
    RP = [{pid, P#peer_state.pid},
	  {choke_state, P#peer_state.choke_state},
	  {interest_state, P#peer_state.interest_state},
	  {local_choke, P#peer_state.local_choke}],
    Snubbed = case ets:lookup(etorrent_recv_state, {Id, Who}) of
                [] -> false;
                [#rate_mgr { snub_state = normal}] -> false;
                [#rate_mgr { snub_state = snubbed}] -> true
              end,
    {value, Snubbed, RP}.

%% @doc Get the `#peer_state{}' record for a peer.
%% <p>If the peer is not in the table, the standard the default record
%% is returned.</p>
%% @end
%% @todo rename as 'get_'
-spec select_state(integer(), pid()) -> {value, #peer_state{}}.
select_state(Id, Who) ->
    case ets:lookup(etorrent_peer_state, {Id, Who}) of
        [] -> {value, #peer_state { }}; % Pick defaults
        [P] -> {value, P}
    end.

%% @doc Return a property list of interest for a pid
%% <p>The following values are returned: `interested', `choking'. Both
%% are boolean() values signifying what the remote thinks of us.</p>
%% <p>If the pid is not found, a dummy value is returned. Such a
%% dummy-peer is never interested and always choking.</p>
%% @end
pids_interest(Id, Pid) ->
    case ets:lookup(etorrent_peer_state, {Id, Pid}) of
	[] -> [{interested, false},
	       {choking, true}];
	[P] -> [{interested, P#peer_state.interest_state},
		{choking, P#peer_state.choke_state}]
    end.

%% @doc Get the receive rate of the peer
%% @end
%% @todo rename to 'get_'
%% @todo eradicate the 'undefined' return here
-spec fetch_recv_rate(integer(), pid()) ->
    none | undefined | float().
fetch_recv_rate(Id, Pid) -> fetch_rate(etorrent_recv_state, Id, Pid).

%% @doc Get the send rate of the peer
%% @end
%% @todo rename to 'get_'
%% @todo eradicate the 'undefined' return here
-spec fetch_send_rate(integer(), pid()) ->
    none | undefined | float().
fetch_send_rate(Id, Pid) -> fetch_rate(etorrent_send_state, Id, Pid).

%% @doc Set the receive rate of the peer
%% @end
%% @todo rename to 'set_' or something such
%% @todo eradicate the 'undefined' return here
-spec recv_rate(integer(), pid(), float(), normal | snubbed) -> ok.
recv_rate(Id, Pid, Rate, SnubState) ->
    alter_state(recv_rate, Id, Pid, Rate, SnubState).

%% @doc Set the send rate of the peer
%% @end
%% @todo rename to 'set_' or something such
%% @todo eradicate the 'undefined' return here
-spec send_rate(integer(), pid(), float()) -> ok.
send_rate(Id, Pid, Rate) ->
    alter_state(send_rate, Id, Pid, Rate, unchanged).

%% @doc Get the rate of a given Torrent
%% <p>This function proceeds by summing the rates for a given torrent.</p>
%% <p>The `Direction' parameter is either `leeching' or `seeding'. If
%% we are leeching the torrent, the receive rate is used. If we are
%% seeding, the send rate is used.</p>
%% @end
-spec get_torrent_rate(integer(), leeching | seeding) -> {ok, float()}.
get_torrent_rate(Id, Direction) ->
    Tab = case Direction of
            leeching -> etorrent_recv_state;
            seeding  -> etorrent_send_state
          end,
    Objects = ets:match_object(Tab, #rate_mgr { pid = {Id, '_'}, _ = '_' }),
    R = lists:sum([K#rate_mgr.rate || K <- Objects]),
    {ok, R}.

%% @doc Return the global receive and send rates
%% <p>This function returns `{Recv, Send}' where both `Recv' and
%% `Send' are float() values.</p>
%% @end
%% @todo Return a proplist(), not this thing you can't remember.
-spec global_rate() -> {float(), float()}.
global_rate() ->
    RR = sum_global_rate(etorrent_recv_state),
    SR = sum_global_rate(etorrent_send_state),
    {RR, SR}.

%% ====================================================================

%% @private
init([]) ->
    RTid = ets:new(etorrent_recv_state, [public, named_table,
                                         {keypos, #rate_mgr.pid}]),
    STid = ets:new(etorrent_send_state, [public, named_table,
                                         {keypos, #rate_mgr.pid}]),
    StTid = ets:new(etorrent_peer_state, [public, named_table,
                                         {keypos, #peer_state.pid}]),
    {ok, #state{ recv = RTid, send = STid, state = StTid,
                 global_recv = etorrent_rate:init(?RATE_FUDGE),
                 global_send = etorrent_rate:init(?RATE_FUDGE)}}.

%% @private
handle_call(Request, _From, State) ->
    ?INFO([unknown_request, ?MODULE, Request]),
    {reply, ok, State}.

%% @private
handle_cast({monitor, Pid}, S) ->
    erlang:monitor(process, Pid),
    {noreply, S};
handle_cast(Msg, State) ->
    ?INFO([unknown_cast, ?MODULE, Msg]),
    {noreply, State}.

%% @private
handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    true = ets:match_delete(etorrent_recv_state, #rate_mgr { pid = {'_', Pid}, _='_'}),
    true = ets:match_delete(etorrent_send_state, #rate_mgr { pid = {'_', Pid}, _='_'}),
    true = ets:match_delete(etorrent_peer_state, #peer_state { pid = {'_', Pid}, _='_'}),
    {noreply, S};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _S) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% --------------------------------------------------------------------
sum_global_rate(Table) ->
    Objs = ets:match_object(Table, #rate_mgr { _ = '_' }),
    lists:sum([K#rate_mgr.rate || K <- Objs]).

alter_state(What, Id, Pid) ->
    case ets:lookup(etorrent_peer_state, {Id, Pid}) of
        [] ->
	    ets:insert(etorrent_peer_state,
		       alter_record(What,
				    #peer_state {
				      pid = {Id, Pid},
				      choke_state = choked,
				      interest_state = not_interested,
				      local_choke = true})),
	    add_monitor(Pid);
        [R] ->
            ets:insert(etorrent_peer_state,
                       alter_record(What, R))
    end,
    ok.

alter_record(What, R) ->
    case What of
        choke ->
            R#peer_state { choke_state = choked };
        unchoke ->
            R#peer_state { choke_state = unchoked };
        interested ->
            R#peer_state { interest_state = interested };
        not_interested ->
            R#peer_state { interest_state = not_interested };
        local_choke ->
            R#peer_state { local_choke = true };
        local_unchoke ->
            R#peer_state { local_choke = false}
    end.

alter_state(What, Id, Who, Rate, SnubState) ->
    T = case What of
            recv_rate -> etorrent_recv_state;
            send_rate -> etorrent_send_state
        end,
    case ets:lookup(T, {Id, Who}) of
        [] ->
	    ets:insert(T,
		       #rate_mgr {
			 pid = {Id, Who},
			 snub_state = case SnubState of
					  snubbed -> snubbed;
					  normal  -> normal;
					  unchanged -> normal
				      end,
			 rate = Rate }),
	    add_monitor(Who);
	[R] ->
            ets:insert(T, R#rate_mgr {
			    rate = Rate,
			    snub_state =
			    case SnubState of
				unchanged -> R#rate_mgr.snub_state;
				X         -> X
			    end })
    end,
    ok.

-type rate_mgr_tables() :: etorrent_send_state | etorrent_recv_state.
-spec fetch_rate(rate_mgr_tables(), integer(), pid()) ->
    none | float() | undefined.
fetch_rate(Where, Id, Pid) ->
    case ets:lookup(Where, {Id, Pid}) of
        [] ->
            none;
        [R] -> R#rate_mgr.rate
    end.

add_monitor(Pid) ->
    gen_server:cast(?SERVER, {monitor, Pid}).

