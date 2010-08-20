%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.com>
%%% @copyright (C) 2010, James Aimonetti
%%% @doc
%%% Handles authentication requests on the FS instance by a device
%%% @end
%%% Created : 17 Aug 2010 by James Aimonetti <james@2600hz.com>
%%%-------------------------------------------------------------------
-module(ecallmgr_auth).

-behaviour(gen_server).

%% API
-export([start_link/0, lookup_user/2, send_fetch_response/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-import(proplists, [get_value/2, get_value/3]).

-include("../include/amqp_client/include/amqp_client.hrl").
-include("freeswitch_xml.hrl").

-define(SERVER, ?MODULE). 


-record(state, {fs_node, channel, ticket}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

send_fetch_response(ID, Response) ->
    gen_server:cast(?MODULE, {send_fetch_response, ID, Response}).

%% see lookup_user/2 after gen_server callbacks

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    process_flag(trap_exit, true),
    Node = list_to_atom(lists:concat(["freeswitch@", net_adm:localhost()])),
    {ok, Channel, Ticket} = amqp_manager:open_channel(self()),
    State = #state{fs_node=Node, channel=Channel, ticket=Ticket},
    case net_adm:ping(Node) of
	pong ->
	    {ok, Pid} = freeswitch:start_fetch_handler(Node, directory, ?MODULE, lookup_user, State),
	    link(Pid);
	_ ->
	    io:format("Unable to find ~p to talk to freeSWITCH~n", [Node])
    end,

    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({send_fetch_response, ID, Response}, #state{fs_node=Node}=State) ->
    freeswitch:fetch_reply(Node, ID, Response),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

lookup_user(Node, State) ->
    receive
	{fetch, directory, "domain", "name", _Value, ID, [undefined | Data]} ->
	    io:format("fetch directory: Id: ~p Data: ~p~n", [ID, Data]),
	    spawn(fun() -> lookup_user(State, ID, Data) end),
	    ?MODULE:lookup_user(Node, State);
	{fetch, _Section, _Something, _Key, _Value, ID, [undefined | _Data]} ->
	    io:format("fetch unknown: Se: ~p So: ~p, K: ~p V: ~p ID: ~p, D: ~p~n", [_Section, _Something, _Key, _Value, ID, _Data]),
	    freeswitch:fetch_reply(Node, ID, ?EMPTYRESPONSE),
	    ?MODULE:lookup_user(Node, State);
	{nodedown, Node} ->
	    io:format("Node we were serving XML search requests to exited", []),
	    ok;
	Other ->
	    io:format("got other response: ~p", [Other]),
	    ?MODULE:lookup_user(Node, State)
    end.

lookup_user(#state{fs_node=Node, channel=Channel, ticket=Ticket}=State, ID, Data) ->
    %bind_q(Channel, Ticket, ID),
    %% build req for rabbit
    
    %% put on wire to rabbit
    %% recv resp from rabbit
    User = get_value("user", Data),
    Domain = get_value("domain", Data),
    Pass = "james", %% lookup here, or timeout
    %Hash = a1hash(User, Domain, Pass),
    %%Resp = lists:flatten(io_lib:format(?REGISTERRESPONSE, [Domain, User, Hash])),
    Resp = lists:flatten(io_lib:format(?REGISTER_NOPASS_RESPONSE, [Domain, User])),
    io:format("LOOKUP_USER(~p): Sending resp: ~p~n", [self(), Resp]),
    ?MODULE:send_fetch_response(ID, Resp).

bind_q(Channel, Ticket, ID) ->
    #'exchange.declare_ok'{} = amqp_channel:call(Channel, amqp_util:targeted_exchange(Ticket)),
    #'queue.declare_ok'{queue = Queue} = amqp_channel:call(Channel, amqp_util:new_targeted_queue(Ticket, ID)),
    #'queue.bind_ok'{} = amqp_channel:call(Channel, amqp_util:bind_q_to_targeted(Ticket, Queue, Queue)),
    #'basic.consume_ok'{} = amqp_channel:subscribe(Channel, amqp_util:targeted_consume(Ticket, ID), self()).


a1hash(User, Realm, Password) ->
    to_hex(erlang:md5(User++":"++Realm++":"++Password)).

to_hex(Bin) when is_binary(Bin) ->
    to_hex(binary_to_list(Bin));
to_hex(L) when is_list(L) ->
    string:to_lower(lists:flatten([io_lib:format("~2.16.0B", [H]) || H <- L])).