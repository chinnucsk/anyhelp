%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, Karl Anderson
%%% @doc
%%% API resource
%%%
%%%
%%% @end
%%% Created :  05 Jan 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(v1_resource).

-export([init/1]).
-export([to_json/2, to_xml/2]).
-export([from_json/2, from_xml/2, from_form/2]).
-export([encodings_provided/2, finish_request/2, is_authorized/2, forbidden/2, allowed_methods/2]).
-export([malformed_request/2, content_types_provided/2, content_types_accepted/2, resource_exists/2]).
-export([expires/2, generate_etag/2]).
-export([process_post/2, delete_resource/2]).

-import(logger, [format_log/3]).

-include("crossbar.hrl").
-include_lib("webmachine/include/webmachine.hrl").

-define(NAME, <<"v1_resource">>).

%%%===================================================================
%%% WebMachine API
%%%===================================================================
init(Opts) ->
    {Context, _} = crossbar_bindings:fold(<<"v1_resource.init">>, {#cb_context{start=now()}, Opts}),
    {ok, Context}.
    %%{{trace, "/tmp"}, Context}.

allowed_methods(RD, #cb_context{allowed_methods=Methods}=Context) ->
    Verb = whistle_util:to_binary(string:to_lower(atom_to_list(wrq:method(RD)))),
    Tokens = lists:map(fun whistle_util:to_binary/1, wrq:path_tokens(RD)),
    Loaded = lists:map(fun whistle_util:to_binary/1, erlang:loaded()),
    case parse_path_tokens(Tokens, Loaded, []) of
        [{Mod, Params}|_] = Nouns ->
            Responses = crossbar_bindings:map(<<"v1_resource.allowed_methods.", Mod/binary>>, Params),
            Methods1 = allow_methods(Responses, Methods),
            {Methods1, RD, Context#cb_context{req_nouns=Nouns, req_verb=Verb}};
        [] ->
            {Methods, RD, Context#cb_context{req_verb=Verb}}
    end.

malformed_request(RD, Context) ->
    try	
        Json = case wrq:req_body(RD) of
		   <<>> ->
		       {struct, []};
		   ReqBody ->
		       mochijson2:decode(ReqBody)
	       end,
        Data = whapps_json:get_value(Json, ["data"]),
        Auth = get_auth_token(RD, Json),
	{false, RD, Context#cb_context{req_json=Json, req_data=Data, auth_token=Auth}}
    catch
        _Exception:_Reason ->
	    Context1 = Context#cb_context{
			  resp_status = error
			 ,resp_error_msg = <<"Invalid or malformed content">>
			 ,resp_error_code = 400
			},
            Content = create_resp_content(RD, Context1),
	    RD1 = wrq:set_resp_body(Content, RD),
            {true, RD1, Context1}
    end.

is_authorized(RD, #cb_context{auth_token=AuthToken}=Context) ->
    S0 = crossbar_session:start_session(AuthToken),
    Event = <<"v1_resource.start_session">>,
    S = crossbar_bindings:fold(Event, S0),
    {true, RD, Context#cb_context{session=S}}.
    
forbidden(RD, Context) ->
    case is_authentic(RD, Context) of
        true ->
            case is_permitted(RD, Context) of
                true -> {false, RD, Context};
                false -> {true, RD, Context}
            end;
        false ->
            {{halt, 401}, RD, Context}
    end.

resource_exists(RD, #cb_context{req_nouns=[{<<"404">>,_}|_]}=Context) ->
    {false, RD, Context};
resource_exists(RD, Context) ->
    case does_resource_exist(RD, Context) of
	true ->
            {RD1, Context1} = validate(RD, Context),
            case succeeded(Context1) of
                true ->
                    execute_request(RD1, Context1);
                false ->
                    Content = create_resp_content(RD, Context1),
                    RD2 = wrq:append_to_response_body(Content, RD1),
                    ReturnCode = Context1#cb_context.resp_error_code,
                    {{halt, ReturnCode}, wrq:remove_resp_header("Content-Encoding", RD2), Context1}
            end;
	false ->
	    {false, RD, Context}
    end.

content_types_provided(RD, #cb_context{content_types_provided=CTP}=Context) ->
    CTP1 = lists:foldr(fun({Fun, L}, Acc) ->
			       lists:foldr(fun(EncType, Acc1) -> [ {EncType, Fun} | Acc1 ] end, Acc, L)
		       end, [], CTP),
    {CTP1, RD, Context}.

content_types_accepted(RD, #cb_context{content_types_accepted=CTA}=Context) ->
    CTA1 = lists:foldr(fun({Fun, L}, Acc) ->
			       lists:foldr(fun(EncType, Acc1) -> [ {EncType, Fun} | Acc1 ] end, Acc, L)
		       end, [], CTA),
    {CTA1, RD, Context}.

generate_etag(RD, Context) ->
    Event = <<"v1_resource.etag">>,
    {RD1, Context1} = crossbar_bindings:fold(Event, {RD, Context}),
    case Context1#cb_context.resp_etag of
        automatic ->
            RespContent = create_resp_content(RD1, Context1),
            {mochihex:to_hex(crypto:md5(RespContent)), RD1, Context1};
        undefined ->
            {undefined, RD1, Context1};
        Tag when is_list(Tag) ->
            {undefined, RD1, Context1}
    end.

encodings_provided(RD, Context) ->
    { [ {"identity", fun(X) -> X end} ]
      %%,{"gzip", fun(X) -> zlib:gzip(X) end}]
      ,RD, Context}.

expires(RD, #cb_context{resp_expires=Expires}=Context) ->
    Event = <<"v1_resource.expires">>,
    crossbar_bindings:fold(Event, {Expires, RD, Context}).

process_post(RD, Context) ->
    Event = <<"v1_resource.process_post">>,
    crossbar_bindings:map(Event, {RD, Context}),
    create_push_response(RD, Context).

delete_resource(RD, Context) ->
    Event = <<"v1_resource.delete_resource">>,
    crossbar_bindings:map(Event, {RD, Context}),
    create_push_response(RD, Context).

finish_request(RD, #cb_context{start=T1}=Context) ->
    Event = <<"v1_resource.finish_request">>,
    {RD1, Context1} = crossbar_bindings:fold(Event, {RD, Context}),
    case Context1#cb_context.session of
        undefined ->
            io:format("Request fulfilled in ~p ms~n", [timer:now_diff(now(), T1)*0.001]),
            {true, RD1, Context1};
        #session{}=S ->
            io:format("Request fulfilled in ~p ms, finish session~n", [timer:now_diff(now(), T1)*0.001]),
            {true, crossbar_session:finish_session(S, RD1), Context1#cb_context{session=undefined}}
    end.

%%%===================================================================
%%% Content Acceptors
%%%===================================================================
from_json(RD, Context) ->
    Event = <<"v1_resource.from_json">>,
    crossbar_bindings:map(Event, {RD, Context}),
    create_push_response(RD, Context).

from_xml(RD, Context) ->
    Event = <<"v1_resource.from_xml">>,
    crossbar_bindings:map(Event, {RD, Context}),
    create_push_response(RD, Context).

from_form(RD, Context) ->
    Event = <<"v1_resource.from_form">>,
    crossbar_bindings:map(Event, {RD, Context}),
    create_push_response(RD, Context).

%%%===================================================================
%%% Content Providers
%%%===================================================================
to_json(RD, Context) ->
    Event = <<"v1_resource.to_json">>,
    crossbar_bindings:map(Event, {RD, Context}),
    create_pull_response(RD, Context).

to_xml(RD, Context) ->
    Event = <<"v1_resource.to_xml">>,
    crossbar_bindings:map(Event, {RD, Context}),
    create_pull_response(RD, Context).

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will loop over the Tokens in the request path and return
%% a proplist with keys being the module and values a list of parameters
%% supplied to that module.  If the token order is improper a empty list
%% is returned.
%% @end
%%--------------------------------------------------------------------
-spec(parse_path_tokens/3 :: (Tokens :: list(), Loaded :: list(), Events :: list()) -> proplist()).
parse_path_tokens([], _Loaded, Events) ->
    Events;
parse_path_tokens([Mod|T], Loaded, Events) ->
    case lists:member(Mod, Loaded) of
        false ->
            parse_path_tokens([], Loaded, []);
        true ->
            {Params, List2} = lists:splitwith(fun(Elem) -> not lists:member(Elem, Loaded) end, T),
            Params1 = lists:map(fun whistle_util:to_binary/1, Params),
            parse_path_tokens(List2, Loaded, [{Mod, Params1} | Events])
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will find the intersection of the allowed methods
%% among event respsonses.  The responses can only veto the list of
%% methods, they can not add.
%% @end
%%--------------------------------------------------------------------
-spec(allow_methods/2  :: (Reponses :: list(tuple(term(), term())), Avaliable :: http_methods()) -> http_methods()).
allow_methods(Responses, Available) ->
    case crossbar_bindings:succeeded(Responses) of
        [] ->
	    Available;
	Succeeded ->
            lists:foldr(fun({true, Response}, Acc) ->
				Set1 = sets:from_list(Acc),
				Set2 = sets:from_list(Response),
				sets:to_list(sets:intersection(Set1, Set2))
			end, Available, Succeeded)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will look for the authorization token, first checking the
%% request headers, if not found there it will look either in the HTTP
%% query paramerts (for GET and DELETE) or HTTP content (for POST and PUT)
%% @end
%%--------------------------------------------------------------------
-spec(get_auth_token/2 :: (RD :: #wm_reqdata{}, JSON :: proplist()) -> binary()).
get_auth_token(RD, JSON) ->
    case wrq:get_req_header("X-Auth-Token", RD) of
        undefined ->
            case wrq:method(RD) of
                'GET' ->
                    whistle_util:to_binary(proplists:get_value("auth-token", wrq:req_qs(RD), ""));
                'POST' ->
                    whistle_util:to_binary(proplists:get_value("auth-token", JSON, ""));
                'PUT' ->
                    whistle_util:to_binary(proplists:get_value("auth-token", JSON, ""));
                'DELETE' ->
                    whistle_util:to_binary(proplists:get_value("auth-token", wrq:req_qs(RD), ""))
            end;
        AuthToken ->
            whistle_util:to_binary(AuthToken)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use event bindings to determine if the target noun
%% (the final module in the chain) accepts this verb parameter pair.
%% @end
%%--------------------------------------------------------------------
-spec(does_resource_exist/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> boolean()).
does_resource_exist(_RD, #cb_context{req_nouns=[{Mod, Params}|_]}) ->
    Event = <<"v1_resource.resource_exists.", Mod/binary>>,
    Responses = crossbar_bindings:map(Event, Params),
    crossbar_bindings:all(Responses) and true;
does_resource_exist(_RD, _Context) ->
    false.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use event bindings to determine if the client has
%% provided a valid authentication token
%% @end
%%--------------------------------------------------------------------
-spec(is_authentic/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> boolean()).
is_authentic(_RD, #cb_context{req_nouns=Nouns, auth_token=AuthToken})->
    Event = <<"v1_resource.authenticate">>,
    Responses = crossbar_bindings:map(Event, {AuthToken, Nouns}),
    crossbar_bindings:any(Responses).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will use event bindings to determine if the client is
%% authorized for this request
%% @end
%%--------------------------------------------------------------------
-spec(is_permitted/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> boolean()).
is_permitted(RD, #cb_context{req_nouns=Nouns, auth_token=AuthToken})->
    Event = <<"v1_resource.authorize">>,
    Responses = crossbar_bindings:map(Event, {AuthToken, wrq:method(RD), Nouns}),
    crossbar_bindings:any(Responses).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function gives each noun a chance to determine if
%% it is valid and returns the status, and any errors
%% @end
%%--------------------------------------------------------------------
-spec(validate/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> tuple(#wm_reqdata{}, #cb_context{})).
validate(RD, #cb_context{req_nouns=Nouns}=Context) ->
    lists:foldr(fun({Mod, Params}, {RD1, Context1}) ->
			Event = <<"v1_resource.validate.", Mod/binary>>,
                        Payload = [RD1, Context1] ++ Params,
			[RD2, Context2 | _] = crossbar_bindings:fold(Event, Payload),
			{RD2, Context2}
                end, {RD, Context}, Nouns).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will execute the request
%% @end
%%--------------------------------------------------------------------
-spec(execute_request/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> tuple(true|tuple(halt, 500), #wm_reqdata{}, #cb_context{})).
execute_request(RD, #cb_context{req_nouns=[{Mod, Params}|_], req_verb=Verb}=Context) ->
    Event = <<"v1_resource.execute.", Verb/binary, ".", Mod/binary>>,
    Payload = [RD, Context] ++ Params,
    [RD1, Context1 | _] = crossbar_bindings:fold(Event, Payload),
    case succeeded(Context1) of
        false ->
            Content = create_resp_content(RD, Context1),
            RD2 = wrq:append_to_response_body(Content, RD1),
            ReturnCode = Context1#cb_context.resp_error_code,
            {{halt, ReturnCode}, wrq:remove_resp_header("Content-Encoding", RD2), Context1};
        true ->
            case wrq:method(RD) of
                'PUT' ->
                    {false, RD1, Context1};
                _Else ->
                    {true, RD1, Context1}
            end
    end;
execute_request(RD, Context) ->
    {false, RD, Context}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will create the content for the response body
%% @end
%%--------------------------------------------------------------------
-spec(create_resp_content/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> iolist()).
create_resp_content(RD, Context) ->
    Prop = create_resp_envelope(Context),
    case get_resp_type(RD) of
	xml ->
            io_lib:format("<?xml version=\"1.0\"?><crossbar>~s</crossbar>", [encode_xml(lists:reverse(Prop), [])]);
        json ->
            mochijson2:encode({struct, Prop})
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will create response expected for a request that
%% is pushing data (like PUT)
%% @end
%%--------------------------------------------------------------------
-spec(create_push_response/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> tuple(boolean(), #wm_reqdata{}, #cb_context{})).
create_push_response(RD, Context) ->
    Content = create_resp_content(RD, Context),
    {succeeded(Context), wrq:set_resp_body(Content, RD), Context}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will create response expected for a request that
%% is pulling data (like GET)
%% @end
%%--------------------------------------------------------------------
-spec(create_pull_response/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> tuple(iolist() | tuple(halt, 500), #wm_reqdata{}, #cb_context{})).
create_pull_response(RD, Context) ->
    Content = create_resp_content(RD, Context),
    case succeeded(Context) of
        false ->
            {{halt, 500}, wrq:set_resp_body(Content, RD), Context};
        true ->
            {Content, RD, Context}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the response is of type success
%% @end
%%--------------------------------------------------------------------
-spec(succeeded/1 :: (Context :: #cb_context{}) -> boolean()).
succeeded(#cb_context{resp_status=Status}) ->
    Status =:= success.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function extracts the reponse fields and puts them in a proplist
%% @end
%%--------------------------------------------------------------------
-spec(create_resp_envelope/1 :: (Context :: #cb_context{}) -> proplist()).
create_resp_envelope(#cb_context{auth_token=A, resp_data=D, resp_status=S, resp_error_msg=E, resp_error_code=C}) ->
    case {S, C} of
	{success, _} ->
	    [
                 {<<"auth-token">>, A}
                ,{<<"status">>, S}
                ,{<<"data">>, D}
            ];
	{_, undefined} ->
            Msg =
                case E of
                    undefined ->
                        <<"Unspecified server error">>;
                    Else ->
                        whistle_util:to_binary(Else)
                end,
	    [
                 {<<"auth-token">>, A}
                ,{<<"status">>, S}
                ,{<<"message">>, Msg}
                ,{<<"error">>, 500}
                ,{<<"data">>, D}
            ];
	_ ->
            Msg =
                case E of
                    undefined ->
                        <<"Unspecified server error">>;
                    Else ->
                        whistle_util:to_binary(Else)
                end,
	    [
                 {<<"auth-token">>, A}
                ,{<<"status">>, S}
                ,{<<"message">>, Msg}
                ,{<<"error">>, C}
                ,{<<"data">>, D}
            ]
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will determine the appropriate content format to return
%% based on the request....
%% @end
%%--------------------------------------------------------------------
-spec(get_resp_type/1 :: (RD :: #wm_reqdata{}) -> json|xml).
get_resp_type(RD) ->
    case wrq:get_resp_header("Content-Type",RD) of
        "application/xml" -> xml;
        "application/json" -> json;
        "application/x-json" -> json;
        _Else -> json
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is used to encode the response proplist in xml
%% @end
%%--------------------------------------------------------------------
-spec(encode_xml/2 :: (Prop :: proplist(), Xml :: iolist()) -> iolist()).
encode_xml([], Xml) ->
    Xml;
encode_xml([{K, V}|T], Xml) ->
    Xml1 =
    if
       is_atom(V) orelse is_binary(V) ->
            case V of
                <<"true">> -> xml_tag(K, "true", "boolean");
                true -> xml_tag(K, "true", "boolean");
                <<"false">> -> xml_tag(K, "false", "boolean");
                false -> xml_tag(K, "true", "boolean");
                _Else -> xml_tag(K, mochijson2:encode(V), "string")
            end;
       is_number(V) ->
           xml_tag(K, mochijson2:encode(V), "number");
       is_list(V) ->
           xml_tag(K, list_to_xml(lists:reverse(V), []), "array");
       true ->
            case V of
                {struct, Terms} ->
                    xml_tag(K, encode_xml(Terms, ""), "object");
                {json, IoList} ->
                    xml_tag(K, encode_xml(IoList, ""), "json")
           end
    end,
    encode_xml(T, Xml1 ++ Xml).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function loops over a list and creates the XML tags for each
%% element
%% @end
%%--------------------------------------------------------------------
-spec(list_to_xml/2 :: (List :: list(), Xml :: iolist()) -> iolist()).
list_to_xml([], Xml) ->
    Xml;
list_to_xml([{struct, Terms}|T], Xml) ->
    Xml1 = xml_tag(encode_xml(Terms, ""), "object"),
    list_to_xml(T, Xml1 ++ Xml);
list_to_xml([E|T], Xml) ->
    Xml1 =
    if
        is_atom(E) orelse is_binary(E) ->
            case E of
                <<"true">> -> xml_tag("true", "boolean");
                true -> xml_tag("true", "boolean");
                <<"false">> -> xml_tag("false", "boolean");
                false -> xml_tag("true", "boolean");
                _Else -> xml_tag(mochijson2:encode(E), "string")
            end;
        is_number(E) -> xml_tag(mochijson2:encode(E), "number");
        is_list(E) -> xml_tag(list_to_xml(lists:reverse(E), ""), "array")
    end,
    list_to_xml(T, Xml1 ++ Xml).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function creates a XML tag, optionaly with the name
%% attribute if called as xml_tag/3
%% @end
%%--------------------------------------------------------------------
-spec(xml_tag/2 :: (Value :: iolist(), Type :: iolist()) -> iolist()).
xml_tag(Value, Type) ->
    io_lib:format("<~s>~s</~s>~n", [Type, Value, Type]).
xml_tag(Key, Value, Type) ->
    io_lib:format("<~s type=\"~s\">~s</~s>~n", [Key, Type, string:strip(Value, both, $"), Key]).