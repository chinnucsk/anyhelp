-module(trunkstore_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

-include("ts.hrl").

%% ===================================================================
%% Application callbacks
%% ===================================================================

-spec(start/2 :: (StartType :: term(), StartArgs :: term()) -> tuple(ok, pid()) | tuple(error, term())).
start(_StartType, _StartArgs) ->
    setup_views(),
    setup_base_docs(),
    case trunkstore:start_link() of
	{ok, P} -> {ok, P};
	{error,{already_started, P}} -> {ok, P};
	{error, _}=E -> E
    end.

stop(_State) ->
    ok.

setup_views() ->
    lists:foreach(fun(File) ->
			  ts_util:load_doc_from_file(?TS_DB, File)
		  end, ?TS_COUCH_DESIGN_DOCS).


setup_base_docs() ->
    lists:foreach(fun(File) ->
			  ts_util:load_doc_from_file(?TS_DB, File)
		  end, ?TS_COUCH_BASE_DOCS).