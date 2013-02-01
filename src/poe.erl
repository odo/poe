-module(poe).

-behaviour(application).

%% Application callbacks
-export([start/0, start/2, stop/1]).

%% API
-compile({no_auto_import,[put/2]}).
-export([topics/0, put/2, next/2]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start() ->
	application:start(poe).

start(_StartType, _StartArgs) ->
	configure(),
	Dir = env_or_throw(dir),
	poe_sup:start_link(Dir).

stop(_State) ->
    ok.

% when CONFIG is specified, we are loading the config file manually
configure() ->
	case os:getenv("CONFIG") of
		false ->
			noop;
		FileName ->
			error_logger:info_msg("Loading configuration from ~p.\n", [FileName]),
			{ok, [Config]} = file:consult(FileName),
			[set_app_env(C) || C <- Config]
	end.

set_app_env({App, Vars}) ->
	[application:set_env(App, K, V) || {K, V} <- Vars].

env_or_throw(Key) ->
	case proplists:get_value(Key, application:get_all_env(poe)) of
		undefined ->
			throw({error, {atom_to_list(Key) ++ " must be configured in poes environment"}});
		Value ->
			Value
	end.

%% ===================================================================
%% API
%% ===================================================================

topics() ->
	poe_server:topics().

put(Topic, Data) when byte_size(Topic) > 0 andalso byte_size(Data) > 0 ->
	Server = poe_server:write_pid(Topic),
	try
		appendix_server:put(Server, Data)
	catch
		exit:{noproc, _Reason} ->
			error_logger:info_msg("Process for ~p is dead, retrying..\n", [Topic]),
			timer:sleep(20),
			put(Topic, Data)
	end.

next(Topic, Pointer) ->
	case poe_server:read_pid(Topic, Pointer) of
		not_found ->
			throw({unknown_topic, Topic});
		Server ->
			try
				appendix_server:next(Server, Pointer)
			catch
				exit:{noproc, _Reason} ->
					error_logger:info_msg("Process for ~p is dead, retrying..\n", [Topic]),
					timer:sleep(20),
					next(Topic, Pointer)
			end
	end.

