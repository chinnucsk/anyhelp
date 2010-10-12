%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.com>
%%% @copyright (C) 2010, James Aimonetti
%%% @doc
%%% Receive call events from freeSWITCH, publish to the call's event
%%% queue
%%% @end
%%% Created : 25 Aug 2010 by James Aimonetti <james@2600hz.com>
%%%-------------------------------------------------------------------
-module(ecallmgr_call_events).

-export([start/4, init/4]).

-include("whistle_api.hrl").

-import(logger, [log/2, format_log/3]).
-import(proplists, [get_value/2, get_value/3]).

%% Node, UUID, {Channel, Ticket, EvtQueue}
start(Node, UUID, Amqp, CtlPid) ->
    spawn(ecallmgr_call_events, init, [Node, UUID, Amqp, CtlPid]).

init(Node, UUID, Amqp, CtlPid) ->
    freeswitch:handlecall(Node, UUID),
    loop(UUID, Amqp, CtlPid).

%% Amqp = {Channel, Ticket, EvtQueue}
loop(UUID, Amqp, CtlPid) ->
    receive
	{call, {event, [UUID | Data]}} ->
	    format_log(info, "EVT(~p): {Call, {Event}} for ~p: ~p~n", [self(), UUID, get_value(<<"Event-Name">>, Data)]),
	    publish_msg(Amqp, Data),
	    loop(UUID, Amqp, CtlPid);
	{call_event, {event, [ UUID | Data ] } } ->
	    format_log(info, "EVT(~p): {Call_Event, {Event}} for ~p(~p): ~p~n"
		       ,[self(), UUID, get_value(<<"Application">>, Data), get_value(<<"Event-Name">>, Data)]),
	    publish_msg(Amqp, Data),
	    send_ctl_event(CtlPid, UUID, get_value(<<"Event-Name">>, Data), get_value(<<"Application">>, Data)),
	    loop(UUID, Amqp, CtlPid);
	call_hangup ->
	    CtlPid ! {hangup, UUID},
	    remove_queue(Amqp),
	    format_log(info, "EVT(~p): Call Hangup~n", [self()]);
	_Msg ->
	    format_log(error, "EVT(~p): Unhandled FS Msg: ~n~p~n", [self(), _Msg]),
	    loop(UUID, Amqp, CtlPid)
    end.

%% let the ctl process know a command finished executing
send_ctl_event(CtlPid, UUID, <<"CHANNEL_EXECUTE_COMPLETE">>, AppName) ->
    CtlPid ! {execute_complete, UUID, AppName};
send_ctl_event(_CtlPid, _UUID, _Evt, _Data) ->
    ok.

remove_queue({Channel, Ticket, EvtQueue}) ->
    QD = amqp_util:queue_delete(Ticket, EvtQueue),
    format_log(info, "EVT(~p): Delete Queue ~p~n", [self(), QD]),
    amqp_channel:cast(Channel, QD).

publish_msg({Channel, Ticket, EvtQueue}, Prop) ->
    EvtName = get_value(<<"Event-Name">>, Prop),
    case lists:member(EvtName, ?FS_EVENTS) of
	true ->
	    EvtProp = [{<<"Event-Category">>, get_value(<<"Event-Category">>, Prop)}
		       ,{<<"Event-Name">>, EvtName}
		       ,{<<"Msg-ID">>, get_value(<<"Event-Date-Timestamp">>, Prop)}
		       ,{<<"Event-Timestamp">>, get_value(<<"Event-Timestamp">>, Prop)}
		       ,{<<"Event-Date-Timestamp">>, get_value(<<"Event-Date-Timestamp">>, Prop)}
		       ,{<<"Call-ID">>, get_value(<<"Unique-ID">>, Prop)}
		       ,{<<"Channel-Call-State">>, get_value(<<"Channel-Call-State">>, Prop)}
		       ,{<<"Server-ID">>, get_value(<<"Server-ID">>, Prop)}
		       ,{<<"App-Name">>, get_value(<<"App-Name">>, Prop)}
		       ,{<<"App-Version">>, get_value(<<"App-Name">>, Prop)}
		       | event_specific(EvtName, Prop)
		      ] ++
		whistle_api:default_headers(EvtQueue, <<"Call-Event">>, EvtName, <<"ecallmgr.event">>, <<"0.1">>),
	    EvtProp1 = case ecallmgr_util:custom_channel_vars(Prop) of
			   [] -> EvtProp;
			   CustomProp -> [{<<"Custom-Channel-Vars">>, {struct, CustomProp}} | EvtProp]
		       end,

	    case whistle_api:call_event(EvtProp1) of
		{ok, JSON} ->
		    {BP, AmqpMsg} = amqp_util:callevt_publish(Ticket
							      ,EvtQueue
							      ,list_to_binary(JSON)
							      ,<<"application/json">>
							     ),
		    %% execute the publish command
		    amqp_channel:call(Channel, BP, AmqpMsg);
		{error, Msg} ->
		    format_log(error, "EVT(~p): Bad event API ~p~n", [self(), Msg])
	    end;
	false ->
	    ok
    end.

-spec(event_specific/2 :: (EventName :: binary(), Prop :: proplist()) -> proplist()).
event_specific(<<"CHANNEL_EXECUTE_COMPLETE">>, Prop) ->
    Application = get_value(<<"Application">>, Prop),
    case get_value(Application, ?SUPPORTED_APPLICATIONS) of
	undefined ->
	    io:format("WHISTLE_API: Didn't find ~p in supported~n", [Application]),
	    [{<<"Application-Name">>, <<"">>}, {<<"Application-Response">>, <<"">>}];
	AppName ->
	    [{<<"Application-Name">>, AppName}
	     ,{<<"Application-Response">>, get_value(<<"Application-Response">>, Prop, <<"">>)}
	    ]
    end;
event_specific(_Evt, _Prop) ->
    [].