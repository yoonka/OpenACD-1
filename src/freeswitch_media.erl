%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is Spice Telephony.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <athompson at spicecsm dot com>
%%	Micah Warren <mwarren at spicecsm dot com>
%%

%% @doc An on demand gen_server for watching a freeswitch call.
%% This is started by freeswitch_media_manager when a new call id is found.
%% This is responsible for:
%% <ul>
%% <li>Connecting an agent to a call</li>
%% <li>Moving a call into queue.</li>
%% <li>Removing a call from queue.</li>
%% <li>Signalling when a call has hung up.</li>
%% </ul>
%% @see freeswitch_media_manager

-module(freeswitch_media).
-author("Micah").

-behaviour(gen_media).

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("log.hrl").
-include("queue.hrl").
-include("call.hrl").
-include("agent.hrl").

-define(TIMEOUT, 10000).


%% API
-export([
	start/1,
	start_link/1,
	get_call/1,
	%get_queue/1,
	%get_agent/1,
	%unqueue/1,
	%set_agent/3,
	dump_state/1
	]).

%% gen_media callbacks
-export([
	init/1, 
	handle_ring/3,
	handle_ring_stop/1,
	handle_answer/3,
	handle_voicemail/1,
	handle_announce/2,
	handle_agent_transfer/4,
	handle_queue_transfer/1,
	handle_wrapup/1,
	handle_call/3, 
	handle_cast/2, 
	handle_info/2,
	handle_warm_transfer_begin/2,
	terminate/2,
	code_change/3]).

-record(state, {
	callrec = undefined :: #call{} | 'undefined',
	cook :: pid() | 'undefined',
	queue :: string() | 'undefined',
	queue_pid :: pid() | 'undefined',
	cnode :: atom(),
	agent :: string() | 'undefined',
	agent_pid :: pid() | 'undefined',
	ringchannel :: pid() | 'undefined',
	manager_pid :: 'undefined' | any()
	}).

-type(state() :: #state{}).
-define(GEN_MEDIA, true).
-include("gen_spec.hrl").

%%====================================================================
%% API
%%====================================================================
%% @doc starts the freeswitch media gen_server.  `Cnode' is the C node the communicates directly with freeswitch.
-spec(start/1 :: (Cnode :: atom()) -> {'ok', pid()}).
start(Cnode) ->
	gen_media:start(?MODULE, [Cnode]).

-spec(start_link/1 :: (Cnode :: atom()) -> {'ok', pid()}).
start_link(Cnode) ->
	gen_media:start_link(?MODULE, [Cnode]).

%% @doc returns the record of the call freeswitch media `MPid' is in charge of.
-spec(get_call/1 :: (MPid :: pid()) -> #call{}).
get_call(MPid) ->
	gen_media:get_call(MPid).

%-spec(get_queue/1 :: (MPid :: pid()) -> pid()).
%get_queue(MPid) ->
%	gen_media:call(MPid, get_queue).
%
%-spec(get_agent/1 :: (MPid :: pid()) -> pid()).
%get_agent(MPid) ->
%	gen_media:call(MPid, get_agent).

-spec(dump_state/1 :: (Mpid :: pid()) -> #state{}).
dump_state(Mpid) when is_pid(Mpid) ->
	gen_media:call(Mpid, dump_state).
	
%%====================================================================
%% gen_media callbacks
%%====================================================================
%% @private
init([Cnode]) ->
	process_flag(trap_exit, true),
	Manager = whereis(freeswitch_media_manager),
	{ok, {#state{cnode=Cnode, manager_pid = Manager}, undefined}}.

handle_announce(Announcement, #state{callrec = Callrec} = State) ->
	freeswitch:sendmsg(State#state.cnode, Callrec#call.id,
		[{"call-command", "execute"},
			{"execute-app-name", "playback"},
			{"execute-app-arg", Announcement}]),
	{ok, State}.

handle_answer(Apid, _Callrec, State) ->
	{ok, State#state{agent_pid = Apid}}.

handle_ring(Apid, Callrec, State) ->
	?INFO("ring to agent ~p for call ~s", [Apid, Callrec#call.id]),
	F = fun(UUID) ->
		fun(ok, _Reply) ->
			freeswitch:api(State#state.cnode, uuid_bridge, UUID ++ " " ++ Callrec#call.id);
		(error, Reply) ->
			?WARNING("originate failed: ~p", [Reply]),
			ok
		end
	end,
	AgentRec = agent:dump_state(Apid),
	case freeswitch_ring:start(State#state.cnode, AgentRec, Apid, Callrec, 600, F) of
		{ok, Pid} ->
			link(Pid),
			{ok, State#state{ringchannel = Pid, agent_pid = Apid}};
		{error, Error} ->
			?ERROR("error:  ~p", [Error]),
			{invalid, State}
	end.

handle_ring_stop(State) ->
	?DEBUG("hanging up ring channel", []),
	case State#state.ringchannel of
		undefined ->
			ok;
		RingChannel ->
			freeswitch_ring:hangup(RingChannel)
	end,
	{ok, State#state{ringchannel=undefined}}.

handle_voicemail(#state{callrec = Call} = State) ->
	UUID = Call#call.id,
	F = fun(ok, _Reply) ->
			F2 = fun(ok, _Reply2) ->
					?NOTICE("voicemail for ~s recorded", [UUID]);
				(err, Reply2) ->
					?WARNING("Recording voicemail for ~s failed: ~p", [UUID, Reply2])
			end,
			freeswitch:bgapi(State#state.cnode, uuid_record, UUID ++ " start", F2);
		(error, Reply) ->
			?WARNING("Playing voicemail prompt to ~s failed: ~p", [UUID, Reply])
	end,
	freeswitch:bgapi(State#state.cnode, uuid_broadcast, lists:flatten(io_lib:format("~s voicemail/vm-record_message.wav aleg", [UUID])), F),
	{ok, State}.

handle_agent_transfer(AgentPid, Call, Timeout, State) ->
	?INFO("transfer_agent to ~p for call ~p", [AgentPid, Call#call.id]),
	AgentRec = agent:dump_state(AgentPid),
	%#agent{login = Offerer} = agent:dump_state(Offererpid),
	%Ringout = Timeout div 1000,
	%?DEBUG("ringout ~p", [Ringout]),
	%cdr:agent_transfer(Call, {Offerer, Recipient}),
	% fun that returns another fun when passed the UUID of the new channel
	% (what fun!)
	F = fun(UUID) ->
		fun(ok, _Reply) ->
			% agent picked up?
			freeswitch:sendmsg(State#state.cnode, UUID,
				[{"call-command", "execute"}, {"execute-app-name", "intercept"}, {"execute-app-arg", Call#call.id}]);
		(error, Reply) ->
			?WARNING("originate failed: ~p", [Reply])
			%agent:set_state(AgentPid, idle)
		end
	end,
	case freeswitch_ring:start(State#state.cnode, AgentRec, AgentPid, Call, Timeout, F) of
		{ok, Pid} ->
			{ok, State#state{agent_pid = AgentPid, ringchannel=Pid}};
		{error, Error} ->
			?ERROR("error:  ~p", [Error]),
			{error, Error, State}
	end.

handle_warm_transfer_begin(Number, #state{agent_pid = AgentPid, callrec = Call, cnode = Node} = State) when is_pid(AgentPid) ->
	case freeswitch:api(Node, uuid_transfer, lists:flatten(io_lib:format("~s -both 'conference:~s+flags{mintwo}' inline", [Call#call.id, Call#call.id]))) of
		{error, Error} ->
			?WARNING("transferring into a conference failed: ~s", [Error]),
			{error, Error, State};
		{ok, _Whatever} ->
			% okay, now figure out the member IDs
			NF = io_lib:format("Conference ~s not found", [Call#call.id]),
			timer:sleep(100),
			case freeswitch:api(Node, conference, lists:flatten(io_lib:format("~s list", [Call#call.id]))) of
				{ok, NF} ->
					% TODO uh-oh!
					?WARNING("newly created conference not found", []),
					{ok, State};
				{ok, Output} ->
					Members = lists:map(fun(Y) -> util:string_split(Y, ";") end, util:string_split(Output, "\n")),
					?NOTICE("members ~p", [Members]),
					[[Id | _Rest]] = lists:filter(fun(X) -> lists:nth(3, X) =:= Call#call.id end, Members),
					freeswitch:api(Node, conference, Call#call.id ++ " play local_stream://moh " ++ Id),
					freeswitch:api(Node, conference, Call#call.id ++ " mute " ++ Id),
					?NOTICE("Muting ~s in conference", [Id]),
					case freeswitch:api(Node, create_uuid) of
						{ok, UUID} ->
							DialResult = freeswitch:api(Node, conference, lists:flatten(io_lib:format("~s dial {origination_uuid=~s,originate_timeout=30}sofia/gateway/cpxvgw.fusedsolutions.com/~s 1234567890 FreeSWITCH_Conference", [Call#call.id, UUID, Number]))),
							?NOTICE("warmxfer dial result: ~p, UUID requested: ~s", [DialResult, UUID]),
							{ok, UUID, State};
						_ ->
							{error, "allocating UUID failed", State}
					end
			end
	end;
handle_warm_transfer_begin(_Number, #state{agent_pid = AgentPid} = State) ->
	?WARNING("wtf?! agent pid is ~p", [AgentPid]),
	{error, "error: no agent bridged to this call~n", State}.


handle_wrapup(State) ->
	% This intentionally left blank; media is out of band, so there's
	% no direct hangup by the agent
	{ok, State}.
	
handle_queue_transfer(State) ->
	% TODO fully implement this.
	{ok, State}.
%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------
%% @private
%handle_call({transfer_agent, AgentPid, Timeout}, _From, #state{callrec = Call, agent_pid = Offererpid} = State) ->
%	?INFO("transfer_agent to ~p for call ~p", [AgentPid, Call#call.id]),
%	#agent{login = Recipient} = AgentRec = agent:dump_state(AgentPid),
%	#agent{login = Offerer} = agent:dump_state(Offererpid),
%	Ringout = Timeout div 1000,
%	?DEBUG("ringout ~p", [Ringout]),
%	cdr:agent_transfer(Call, {Offerer, Recipient}),
%	case agent:set_state(AgentPid, ringing, Call) of
%		ok ->
%			% fun that returns another fun when passed the UUID of the new channel
%			% (what fun!)
%			F = fun(UUID) ->
%				fun(ok, _Reply) ->
%					% agent picked up?
%					freeswitch:sendmsg(State#state.cnode, UUID,
%						[{"call-command", "execute"}, {"execute-app-name", "intercept"}, {"execute-app-arg", Call#call.id}]);
%				(error, Reply) ->
%					?WARNING("originate failed: ~p", [Reply]),
%					agent:set_state(AgentPid, idle)
%				end
%			end,
%			case freeswitch_ring:start(State#state.cnode, AgentRec, AgentPid, Call, Ringout, F) of
%				{ok, Pid} ->
%					{reply, ok, State#state{agent_pid = AgentPid, ringchannel=Pid}};
%				{error, Error} ->
%					?ERROR("error:  ~p", [Error]),
%					agent:set_state(AgentPid, released, "badring"),
%					{reply, invalid, State}
%			end;
%		Else ->
%			?INFO("Agent ringing response:  ~p", [Else]),
%			{reply, invalid, State}
%	end;
handle_call(get_call, _From, State) ->
	{reply, State#state.callrec, State};
handle_call(get_queue, _From, State) ->
	{reply, State#state.queue_pid, State};
handle_call(get_agent, _From, State) ->
	{reply, State#state.agent_pid, State};
handle_call({set_agent, Agent, Apid}, _From, State) ->
	{reply, ok, State#state{agent = Agent, agent_pid = Apid}};
handle_call(dump_state, _From, State) ->
	{reply, State, State};
handle_call(_Request, _From, State) ->
	{reply, ok, State}.

%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------
%% @private
handle_cast(_Msg, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
%% @private
handle_info(check_recovery, State) ->
	case whereis(freeswitch_media_manager) of
		Pid when is_pid(Pid) ->
			link(Pid),
			Call = State#state.callrec,
			gen_server:cast(freeswitch_media_manager, {notify, Call#call.id, self()}),
			{noreply, State#state{manager_pid = Pid}};
		_Else ->
			{ok, Tref} = timer:send_after(1000, check_recovery),
			{noreply, State#state{manager_pid = Tref}}
	end;
handle_info({'EXIT', Pid, Reason}, #state{ringchannel = Pid} = State) ->
	?WARNING("Handling ring channel ~w exit ~p", [Pid, Reason]),
	{stop_ring, State#state{ringchannel = undefined}};
handle_info({'EXIT', Pid, Reason}, #state{manager_pid = Pid} = State) ->
	?WARNING("Handling manager exit from ~w due to ~p", [Pid, Reason]),
	{ok, Tref} = timer:send_after(1000, check_recovery),
	{noreply, State#state{manager_pid = Tref}};
handle_info({call, {event, [UUID | Rest]}}, State) when is_list(UUID) ->
	?DEBUG("reporting new call ~p.", [UUID]),
	Callrec = #call{id = UUID, source = self()},
	%cdr:cdrinit(Callrec),
	freeswitch_media_manager:notify(UUID, self()),
	State2 = State#state{callrec = Callrec},
	case_event_name([UUID | Rest], State2);
handle_info({call_event, {event, [UUID | Rest]}}, State) when is_list(UUID) ->
	?DEBUG("reporting existing call progess ~p.", [UUID]),
	% TODO flesh out for all call events.
	case_event_name([ UUID | Rest], State);
handle_info({set_agent, Login, Apid}, State) ->
	{noreply, State#state{agent = Login, agent_pid = Apid}};
handle_info({bgok, Reply}, State) ->
	?DEBUG("bgok:  ~p", [Reply]),
	{noreply, State};
handle_info({bgerror, "-ERR NO_ANSWER\n"}, State) ->
	?INFO("Potential ringout.  Statecook:  ~p", [State#state.cook]),
	%% the apid is known by gen_media, let it handle if it is not not.
	{stop_ring, State};
handle_info({bgerror, "-ERR USER_BUSY\n"}, State) ->
	?NOTICE("Agent rejected the call", []),
	{stop_ring, State};
handle_info({bgerror, Reply}, State) ->
	?WARNING("unhandled bgerror: ~p", [Reply]),
	{noreply, State};
handle_info(call_hangup, State) ->
	?NOTICE("Call hangup info, terminating", []),
	{stop, normal, State};
handle_info(Info, State) ->
	?INFO("unhandled info ~p", [Info]),
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
%% @private
terminate(Reason, State) ->
	?NOTICE("terminating: ~p", [Reason]),
	ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% @private
case_event_name([UUID | Rawcall], #state{callrec = Callrec} = State) ->
	Ename = freeswitch:get_event_name(Rawcall),
	?DEBUG("Event:  ~p;  UUID:  ~p", [Ename, UUID]),
	case Ename of
		"CHANNEL_PARK" ->
			case State#state.queue_pid of
				undefined ->
					Queue = freeswitch:get_event_header(Rawcall, "variable_queue"),
					Brand = freeswitch:get_event_header(Rawcall, "variable_brand"),
					case call_queue_config:get_client(Brand) of
						none ->
							Clientrec = #client{label="Unknown", tenant=0, brand=0, timestamp = 1};
						Clientrec ->
							ok
					end,
					Calleridname = freeswitch:get_event_header(Rawcall, "Caller-Caller-ID-Name"),
					Calleridnum = freeswitch:get_event_header(Rawcall, "Caller-Caller-ID-Number"),
					NewCall = Callrec#call{client=Clientrec, callerid=Calleridname++ " "++Calleridnum},
					freeswitch:sendmsg(State#state.cnode, UUID,
						[{"call-command", "execute"},
							{"execute-app-name", "answer"}]),
					% play musique d'attente
					freeswitch:sendmsg(State#state.cnode, UUID,
						[{"call-command", "execute"},
							{"execute-app-name", "playback"},
							{"execute-app-arg", "local_stream://moh"}]),
						%% tell gen_media to (finally) queue the media
					{queue, Queue, NewCall, State#state{queue = Queue}};
				_Otherwise ->
					{noreply, State}
			end;
		"CHANNEL_HANGUP" ->
			?DEBUG("Channel hangup", []),
			Qpid = State#state.queue_pid,
			Apid = State#state.agent_pid,
			case Apid of
				undefined ->
					?WARNING("Agent undefined", []),
					State2 = State#state{agent = undefined, agent_pid = undefined};
				_Other ->
					case agent:query_state(Apid) of
						{ok, ringing} ->
							?NOTICE("caller hung up while we were ringing an agent", []),
							case State#state.ringchannel of
								undefined ->
									ok;
								RingChannel ->
									freeswitch_ring:hangup(RingChannel)
							end;
						{ok, oncall} ->
							ok;
						{ok, released} ->
							ok;
						{ok, warmtransfer} ->
							% caller hungup during warm transfer
							ok
					end,
					State2 = State#state{agent = undefined, agent_pid = undefined, ringchannel = undefined}
			end,
			case Qpid of
				undefined ->
					?WARNING("Queue undefined", []),
					State3 = State2#state{agent = undefined, agent_pid = undefined};
				_Else ->
					call_queue:remove(Qpid, self()),
					State3 = State2#state{queue = undefined, queue_pid = undefined}
			end,
			{hangup, State3};
		"CHANNEL_DESTROY" ->
			?DEBUG("Last message this will recieve, channel destroy", []),
			{stop, normal, State};
		{error, notfound} ->
			?WARNING("event name not found: ~p", [freeswitch:get_event_header(Rawcall, "Content-Type")]),
			{noreply, State};
		Else ->
			?DEBUG("Event unhandled ~p", [Else]),
			{noreply, State}
	end.
