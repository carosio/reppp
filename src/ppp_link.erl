-module(ppp_link).

-behaviour(gen_fsm).

%% API
-export([start_link/3]).
-export([packet_in/2, send/2]).
-export([layer_up/3, layer_down/3, layer_started/3, layer_finished/3]).
-export([auth_withpeer/3, auth_peer/3]).

%% RADIUS helper
-export([accounting_attrs/2]).

%% gen_fsm callbacks
-export([init/1,
	 establish/2, auth/2, network/2, terminating/2,
	 handle_event/3, handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-include("ppp_lcp.hrl").
-include("ppp_ipcp.hrl").
-include_lib("eradius/include/eradius_lib.hrl").
-include_lib("eradius/include/dictionary.hrl").
-include_lib("eradius/include/dictionary_rfc4679.hrl").

-define(SERVER, ?MODULE).
-define(DEFAULT_INTERIM, 10).

-record(state, {
	  config		:: list(),         		%% config options proplist
	  transport		:: pid(), 			%% Transport Layer
	  lcp			:: pid(), 			%% LCP protocol driver
	  pap			:: pid(), 			%% PAP protocol driver
	  ipcp			:: pid(), 			%% IPCP protocol driver

	  auth_required = true	:: boolean,
	  auth_pending = []	:: [atom()],

	  peerid = <<>>		:: binary(),

	  our_lcp_opts		:: #lcp_opts{}, 		%% Options that peer ack'd
	  his_lcp_opts		:: #lcp_opts{},			%% Options that we ack'd

								%% Accounting data
	  accounting_start	:: integer(),			%% Session Start Time in Ticks
	  our_ipcp_opts		:: #lcp_opts{}, 		%% Options that peer ack'd
	  his_ipcp_opts		:: #lcp_opts{},			%% Options that we ack'd
	  interim_ref		:: reference()			%% Interim-Accouting Timer

	 }).

%%%===================================================================
%%% API
%%%===================================================================

packet_in(Connection, Packet) ->
    gen_fsm:send_event(Connection, {packet_in, ppp_frame:decode(Packet)}).

send(Connection, Packet) ->
    gen_fsm:send_all_state_event(Connection, {packet_out, Packet}).

layer_up(Link, Layer, Info) ->
    gen_fsm:send_event(Link, {layer_up, Layer, Info}).

layer_down(Link, Layer, Info) ->
    gen_fsm:send_event(Link, {layer_down, Layer, Info}).

layer_started(Link, Layer, Info) ->
    gen_fsm:send_event(Link, {layer_started, Layer, Info}).

layer_finished(Link, Layer, Info) ->
    gen_fsm:send_event(Link, {layer_finished, Layer, Info}).

auth_withpeer(Link, Layer, Info) ->
    gen_fsm:send_event(Link, {auth_withpeer, Layer, Info}).

auth_peer(Link, Layer, Info) ->
    gen_fsm:send_event(Link, {auth_peer, Layer, Info}).

start_link(TransportModule, TransportRef, Config) ->
    gen_fsm:start_link(?MODULE, [{TransportModule, TransportRef}, Config], []).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

init([Transport, Config]) ->
    process_flag(trap_exit, true),

    {ok, LCP} = ppp_lcp:start_link(self(), Config),
    {ok, PAP} = ppp_pap:start_link(self(), Config),
    ppp_lcp:loweropen(LCP),
    ppp_lcp:lowerup(LCP),
    {ok, establish, #state{config = Config, transport = Transport, lcp = LCP, pap = PAP}}.

establish({packet_in, Frame}, State = #state{lcp = LCP})
  when element(1, Frame) == lcp ->
    io:format("LCP Frame in phase establish: ~p~n", [Frame]),
    case ppp_lcp:frame_in(LCP, Frame) of
 	{up, OurOpts, HisOpts} ->
	    NewState0 = State#state{our_lcp_opts = OurOpts, his_lcp_opts = HisOpts},
	    lowerup(NewState0),
	    if
		OurOpts#lcp_opts.neg_auth /= [] orelse
		HisOpts#lcp_opts.neg_auth /= [] ->
		    NewState1 = do_auth_peer(OurOpts#lcp_opts.neg_auth, NewState0),
		    NewState2 = do_auth_withpeer(HisOpts#lcp_opts.neg_auth, NewState1),
		    {next_state, auth, NewState2};
		true ->
		    np_open(NewState0)
	    end;
	Reply ->
	    io:format("LCP got: ~p~n", [Reply]),
	    {next_state, establish, State}
    end;

establish({packet_in, Frame}, State) ->
    %% RFC 1661, Sect. 3.4:
    %%   Any non-LCP packets received during this phase MUST be silently
    %%   discarded.
    io:format("non-LCP Frame in phase establish: ~p, ignoring~n", [Frame]),
    {next_state, establish, State};

establish({layer_down, lcp, Reason}, State) ->
    lowerdown(State),
    lowerclose(Reason, State),
    lcp_down(State);

establish({layer_finished, lcp, terminated}, State) ->
    io:format("LCP in phase establish got: terminated~n"),
    %% TODO: might want to restart LCP.....
    {stop, normal, State}.

auth({packet_in, Frame}, State = #state{lcp = LCP})
  when element(1, Frame) == lcp ->
    io:format("LCP Frame in phase auth: ~p~n", [Frame]),
    case ppp_lcp:frame_in(LCP, Frame) of
 	down ->
	    lcp_down(State);
	Reply ->
	    io:format("LCP got: ~p~n", [Reply]),
	    {next_state, auth, State}
    end;

%% TODO: we might be able to start protocols on demand....
auth({packet_in, Frame}, State = #state{pap = PAP})
  when element(1, Frame) == pap ->
    io:format("PAP Frame in phase auth: ~p~n", [Frame]),
    case ppp_pap:frame_in(PAP, Frame) of
	ok ->
	    {next_state, auth, State};
	Reply when is_tuple(Reply) ->
	    io:format("PAP in phase auth got: ~p~n", [Reply]),
	    auth_reply(Reply, State)
    end;

auth({packet_in, Frame}, State) ->
    %% RFC 1661, Sect. 3.5:
    %%   Only Link Control Protocol, authentication protocol, and link quality
    %%   monitoring packets are allowed during this phase.  All other packets
    %%   received during this phase MUST be silently discarded.
    io:format("non-Auth Frame: ~p, ignoring~n", [Frame]),
    {next_state, auth, State}.

network(interim_accounting, State) ->
    NewState = accounting_interim(State),
    {next_state, network, NewState};

network({packet_in, Frame}, State = #state{lcp = LCP})
  when element(1, Frame) == lcp ->
    io:format("LCP Frame in phase network: ~p~n", [Frame]),
    case ppp_lcp:frame_in(LCP, Frame) of
 	down ->
	    State1 = accounting_stop(down, State),
	    lcp_down(State1);
	Reply ->
	    io:format("LCP got: ~p~n", [Reply]),
	    {next_state, network, State}
    end;

%% TODO: we might be able to start protocols on demand....
network({packet_in, Frame}, State = #state{ipcp = IPCP})
  when element(1, Frame) == ipcp ->
    io:format("IPCP Frame in phase network: ~p~n", [Frame]),
    case ppp_ipcp:frame_in(IPCP, Frame) of
	down ->
	    State1 = accounting_stop(down, State),
	    np_finished(State1);
	ok ->
	    {next_state, network, State};
 	{up, OurOpts, HisOpts} ->
	    %% IP is open
	    io:format("--------------------------~nIPCP is UP~n--------------------------~n"),
	    State1 = accounting_start(ipcp_up, OurOpts, HisOpts, State),
	    {next_state, network, State1};
	Reply when is_tuple(Reply) ->
	    io:format("IPCP in phase network got: ~p~n", [Reply]),
	    {next_state, network, State}
    end;

network({layer_down, lcp, Reason}, State) ->
    State1 = accounting_stop(down, State),
    lowerdown(State1),
    lowerclose(Reason, State1),
    lcp_down(State1).

terminating(interim_accounting, State) ->
    {next_state, terminating, State};

terminating({packet_in, Frame}, State = #state{lcp = LCP})
  when element(1, Frame) == lcp ->
    io:format("LCP Frame in phase terminating: ~p~n", [Frame]),
    case ppp_lcp:frame_in(LCP, Frame) of
	terminated ->
	    io:format("LCP in phase terminating got: terminated~n"),
	    %% TODO: might want to restart LCP.....
	    {stop, normal, State};
	Reply ->
	    io:format("LCP in phase terminating got: ~p~n", [Reply]),
	    {next_state, terminating, State}
    end;

terminating({packet_in, Frame}, State) ->
    %% RFC 1661, Sect. 3.4:
    %%   Any non-LCP packets received during this phase MUST be silently
    %%   discarded.
    io:format("non-LCP Frame in phase terminating: ~p, ignoring~n", [Frame]),
    {next_state, establish, State};

terminating({layer_down, lcp, Reason}, State) ->
    lowerdown(State),
    lowerclose(Reason, State),
    lcp_down(State);

terminating({layer_finished, lcp, terminated}, State = #state{transport = Transport}) ->
    io:format("LCP in phase terminating got: terminated~n"),
    %% TODO: might want to restart LCP.....
    transport_terminate(Transport),
    {stop, normal, State}.

handle_event({packet_out, Frame}, StateName, State = #state{transport = Transport}) ->
    transport_send(Transport, Frame),
    {next_state, StateName, State};

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info(Info, StateName, State) ->
    io:format("Info: ~p~n", [Info]),
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    io:format("ppp_link ~p terminated~n", [self()]),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

transport_send({TransportModule, TransportRef}, Data) ->
    TransportModule:send(TransportRef, Data).

transport_terminate({TransportModule, TransportRef}) ->
    TransportModule:terminate(TransportRef).

transport_get_counter({TransportModule, TransportRef}, IP) ->
    TransportModule:get_counter(TransportRef, IP).

lowerup(#state{pap = PAP, ipcp = IPCP}) ->
    ppp_pap:lowerup(PAP),
    ppp_ipcp:lowerup(IPCP),
    ok.

lowerdown(#state{pap = PAP, ipcp = IPCP}) ->
    ppp_pap:lowerdown(PAP),
    ppp_ipcp:lowerdown(IPCP),
    ok.

lowerclose(Reason, #state{pap = PAP, ipcp = IPCP}) ->
    ppp_pap:lowerclose(PAP, Reason),
    ppp_ipcp:lowerclose(IPCP, Reason),
    ok.

do_auth_peer([], State) ->
    State;
do_auth_peer([pap|_], State = #state{auth_pending = Pending, pap = PAP}) ->
    ppp_pap:auth_peer(PAP),
    State#state{auth_pending = [auth_peer|Pending]}.

do_auth_withpeer([], State) ->
    State;
do_auth_withpeer([pap|_], State = #state{auth_pending = Pending, pap = PAP}) ->
    ppp_pap:auth_withpeer(PAP, <<"">>, <<"">>),
    State#state{auth_pending = [auth_withpeer|Pending]}.

auth_success(Direction, State = #state{auth_pending = Pending}) ->
    NewState = State#state{auth_pending = proplists:delete(Direction, Pending)},
    if
	NewState#state.auth_pending == [] ->
	    np_open(NewState);
	true ->
	    {next_state, auth, NewState}
    end.

auth_reply({auth_peer, success, PeerId, Opts}, State = #state{config = Config}) ->

    Config0 = lists:foldl(fun(Opt, Acc) ->
				  lists:keystore(element(1, Opt), 1, Acc, Opt)
			  end,
			  proplists:unfold(Config),
			  proplists:unfold(Opts)),
    Config1 = proplists:compact(Config0),
    NewState = State#state{config = Config1, peerid = PeerId},
    auth_success(auth_peer, NewState);

auth_reply({auth_peer, fail}, State) ->
    lcp_close(<<"Authentication failed">>, State);
    
auth_reply({auth_withpeer, success}, State) ->
    auth_success(auth_withpeer, State);
  
auth_reply({auth_withpeer, fail}, State) ->
    lcp_close(<<"Failed to authenticate ourselves to peer">>, State).

lcp_down(State) ->
    NewState = State#state{our_lcp_opts = undefined, his_lcp_opts = undefined},
    {next_state, terminating, NewState}.

lcp_close(Msg, State = #state{lcp = LCP}) ->
    Reply = ppp_lcp:lowerclose(LCP, Msg),
    io:format("LCP close got: ~p~n", [Reply]),
    {next_state, terminating, State}.

np_finished(State) ->
    lcp_close(<<"No network protocols running">>, State).

np_open(State0 = #state{config = Config}) ->
    State1 = accounting_start(init, State0),
    {ok, IPCP} = ppp_ipcp:start_link(self(), Config),
    ppp_ipcp:lowerup(IPCP),
    ppp_ipcp:loweropen(IPCP),
    {next_state, network, State1#state{ipcp = IPCP}}.

accounting_start(init, State) ->
    State.

accounting_start(ipcp_up, OurOpts, HisOpts,
		 State = #state{config = Config}) ->
    NewState0 = State#state{accounting_start = now_ticks(), our_ipcp_opts = OurOpts, his_ipcp_opts = HisOpts},
    io:format("--------------------------~nAccounting: OPEN~n--------------------------~n"),
    spawn(fun() -> do_accounting_start(NewState0) end),
    InterimAccounting = proplists:get_value(interim_accounting, Config, ?DEFAULT_INTERIM),
    Ref = gen_fsm:send_event_after(InterimAccounting * 1000, interim_accounting),
    NewState0#state{interim_ref = Ref}.

accounting_interim(State = #state{accounting_start = Start,
				  config = Config}) ->
    Now = now_ticks(),
    InterimAccounting = proplists:get_value(interim_accounting, Config, ?DEFAULT_INTERIM) * 10,
    %% avoid time drifts...
    Next = InterimAccounting - (Now - Start) rem InterimAccounting,
    Ref = gen_fsm:send_event_after(InterimAccounting * 100, interim_accounting),

    io:format("--------------------------~nAccounting: Interim~nNext: ~p~n--------------------------~n", [Next]),
    spawn(fun() -> do_accounting_interim(Now, State) end),
    State#state{interim_ref = Ref}.

accounting_stop(_Reason,
		State = #state{interim_ref = Ref}) ->
    Now = now_ticks(),
    gen_fsm:cancel_timer(Ref),
    spawn(fun() -> do_accounting_stop(Now, State) end),
    State.

accounting_attrs([], Attrs) ->
    Attrs;
accounting_attrs([{class, Class}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Class, Class}|Attrs]);
accounting_attrs([{calling_station, Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Calling_Station_Id, Value}|Attrs]);
accounting_attrs([{called_station, Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Called_Station_Id, Value}|Attrs]);
accounting_attrs([{port_id, Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?NAS_Port_Id, Value}|Attrs]);

accounting_attrs([{port_type, pppoe_eth}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?NAS_Port_Type, 32}|Attrs]);
accounting_attrs([{port_type, pppoe_vlan}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?NAS_Port_Type, 33}|Attrs]);
accounting_attrs([{port_type, pppoe_qinq}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?NAS_Port_Type, 34}|Attrs]);

%% DSL-Forum PPPoE Intermediate Agent Attributes
accounting_attrs([{'ADSL-Agent-Circuit-Id', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?ADSL_Agent_Circuit_Id, Value}|Attrs]);
accounting_attrs([{'ADSL-Agent-Remote-Id', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?ADSL_Agent_Remote_Id, Value}|Attrs]);
accounting_attrs([{'Actual-Data-Rate-Upstream', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Actual_Data_Rate_Upstream, Value}|Attrs]);
accounting_attrs([{'Actual-Data-Rate-Downstream', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Actual_Data_Rate_Downstream, Value}|Attrs]);
accounting_attrs([{'Minimum-Data-Rate-Upstream', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Minimum_Data_Rate_Upstream, Value}|Attrs]);
accounting_attrs([{'Minimum-Data-Rate-Downstream', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Minimum_Data_Rate_Downstream, Value}|Attrs]);
accounting_attrs([{'Attainable-Data-Rate-Upstream', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Attainable_Data_Rate_Upstream, Value}|Attrs]);
accounting_attrs([{'Attainable-Data-Rate-Downstream', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Attainable_Data_Rate_Downstream, Value}|Attrs]);
accounting_attrs([{'Maximum-Data-Rate-Upstream', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Maximum_Data_Rate_Upstream, Value}|Attrs]);
accounting_attrs([{'Maximum-Data-Rate-Downstream', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Maximum_Data_Rate_Downstream, Value}|Attrs]);
accounting_attrs([{'Minimum-Data-Rate-Upstream-Low-Power', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Minimum_Data_Rate_Upstream_Low_Power, Value}|Attrs]);
accounting_attrs([{'Minimum-Data-Rate-Downstream-Low-Power', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Minimum_Data_Rate_Downstream_Low_Power, Value}|Attrs]);
accounting_attrs([{'Maximum-Interleaving-Delay-Upstream', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Maximum_Interleaving_Delay_Upstream, Value}|Attrs]);
accounting_attrs([{'Actual-Interleaving-Delay-Upstream', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Actual_Interleaving_Delay_Upstream, Value}|Attrs]);
accounting_attrs([{'Maximum-Interleaving-Delay-Downstream', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Maximum_Interleaving_Delay_Downstream, Value}|Attrs]);
accounting_attrs([{'Actual-Interleaving-Delay-Downstream', Value}|Rest], Attrs) ->
    accounting_attrs(Rest, [{?Actual_Interleaving_Delay_Downstream, Value}|Attrs]);

accounting_attrs([H|Rest], Attrs) ->
    io:format("unhandled accounting attr: ~p~n", [H]),
    accounting_attrs(Rest, Attrs).

do_accounting_start(#state{config = Config,
			   peerid = PeerId,
			   his_ipcp_opts = HisOpts}) ->
    Accounting = proplists:get_value(accounting, Config, []),
    UserName = case proplists:get_value(username, Accounting) of
		   undefined -> PeerId;
		   Value -> Value
	       end,
    {ok, NasId} = application:get_env(nas_identifier),
    Attrs = [
	     {?RStatus_Type, ?RStatus_Type_Start},
	     {?User_Name, UserName},
	     {?Service_Type, 2},
	     {?Framed_Protocol, 1},
	     {?NAS_Identifier, NasId},
	     {?Framed_IP_Address, HisOpts#ipcp_opts.hisaddr}
	     | accounting_attrs(Accounting, [])],
    Req = #radius_request{
	     cmd = accreq,
	     attrs = Attrs,
	     msg_hmac = true},
    {ok, NAS} = application:get_env(radius_acct_server),
    eradius_client:send_request(NAS, Req).

do_accounting_interim(Now, #state{config = Config,
				  transport = Transport,
				  peerid = PeerId,
				  accounting_start = Start,
				  his_ipcp_opts = HisOpts}) ->
    io:format("do_accounting_interim~n"),
    Accounting = proplists:get_value(accounting, Config, []),
    UserName = case proplists:get_value(username, Accounting) of
		   undefined -> PeerId;
		   Value -> Value
	       end,
    Counter = transport_get_counter(Transport, HisOpts#ipcp_opts.hisaddr),
    {ok, NasId} = application:get_env(nas_identifier),
    Attrs = [
	     {?RStatus_Type, ?RStatus_Type_Update},
	     {?User_Name, UserName},
	     {?Service_Type, 2},
	     {?Framed_Protocol, 1},
	     {?NAS_Identifier, NasId},
	     {?Framed_IP_Address, HisOpts#ipcp_opts.hisaddr},
	     {?RSession_Time, round((Now - Start) / 10)}
	     | accounting_attrs(Accounting, [])],
    Req = #radius_request{
	     cmd = accreq,
	     attrs = Attrs,
	     msg_hmac = true},
    {ok, NAS} = application:get_env(radius_acct_server),
    eradius_client:send_request(NAS, Req).

do_accounting_stop(Now, #state{config = Config,
			       transport = Transport,
			       peerid = PeerId,
			       accounting_start = Start,
			       his_ipcp_opts = HisOpts}) ->
    io:format("do_accounting_stop~n"),
    Accounting = proplists:get_value(accounting, Config, []),
    UserName = case proplists:get_value(username, Accounting) of
		   undefined -> PeerId;
		   Value -> Value
	       end,
    Counter = transport_get_counter(Transport, HisOpts#ipcp_opts.hisaddr),
    {ok, NasId} = application:get_env(nas_identifier),
    Attrs = [
	     {?RStatus_Type, ?RStatus_Type_Stop},
	     {?User_Name, UserName},
	     {?Service_Type, 2},
	     {?Framed_Protocol, 1},
	     {?NAS_Identifier, NasId},
	     {?Framed_IP_Address, HisOpts#ipcp_opts.hisaddr},
	     {?RSession_Time, round((Now - Start) / 10)}
	     | accounting_attrs(Accounting, [])],
    Req = #radius_request{
	     cmd = accreq,
	     attrs = Attrs,
	     msg_hmac = true},
    {ok, NAS} = application:get_env(radius_acct_server),
    eradius_client:send_request(NAS, Req).


%% get time with 100ms +/50ms presision
now_ticks() ->
    {MegaSecs, Secs, MicroSecs} = erlang:now(),
    MegaSecs * 10000000 + Secs * 10 + round(MicroSecs div 100000).
