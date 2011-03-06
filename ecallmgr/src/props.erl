%%%-------------------------------------------------------------------
%%% @author James Aimonetti <>
%%% @copyright (C) 2010, James Aimonetti
%%% @doc
%%% Replaces proplists get_value/2 and get_value/3 with a faster version
%%% using lists:keyfind
%%% @end
%%% Created :  6 Oct 2010 by James Aimonetti <>
%%%-------------------------------------------------------------------
-module(props).

-export([get_value/2, get_value/3]).

-spec(get_value/2 :: (Key :: term(), Prop :: [term()] ) -> term()).
get_value(Key, Prop) ->
    get_value(Key, Prop, undefined).

-spec(get_value/3 :: (Key :: term(), Prop :: [term()], Default :: term() ) -> term()).
get_value(_Key, [], Def) -> Def;
get_value(Key, Prop, Default) ->
    case lists:keyfind(Key, 1, Prop) of
	false ->
	    case lists:member(Key, Prop) of
		true -> true;
		false -> Default
	    end;
	{Key, V} -> % only return V if a two-tuple is found
	    V;
	Other when is_tuple(Other) -> % otherwise return the default
	    Default
    end.