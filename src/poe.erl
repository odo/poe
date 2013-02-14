-module(poe).

-behaviour(application).

%% Application callbacks
-export([start/0, start/1, start/2, stop/1]).

%% API
-compile({no_auto_import,[put/2]}).
-export([put/2, next/2]).
-export([topics/0, status/0, print_status/0]).

-define(DEFAULTS, 
	[
		{dir, undefined}
		, {check_interval, 0.5}
		, {count_limit, 100000}
		, {size_limit, 64 * 1024 * 1024}
		, {buffer_count_max, 100}
		, {worker_timeout, 1000}
		, {port, 5555}
		, {max_age, infinity}
	]
).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start() ->
	start([]).

start(Options) ->
	configure(),
	[read_from_options(Key, Default, Options)||{Key, Default}<-?DEFAULTS],
	application:start(poe).

start(_StartType, _StartArgs) ->
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

read_from_options(Key, Default, Options) ->
	case proplists:get_value(Key, Options, Default) of
		undefined ->
			noop;
		Value ->
			application:set_env(poe, Key, Value)
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

print_status() ->
    lists:map(
        fun({T, Servers}) ->
            io:format("~ts\t:", [T]),
            [io:format("~p", [State])||{_Pid, State}<-Servers],
            io:format("\n", [])
        end,
        status()
        ).    

status() ->
    [{T, topic_status(T)}||T<-topics()].

topic_status(Topic) ->
    TopicTimestampPid = [{TS, Pid}||[{{T, TS}, Pid}]<-ets:match(poe_server_dir, '$1'), T =:= Topic],
    WritePid = poe_server:write_pid(Topic),
    lists:map(
        fun({_TS, Pid}) ->
            case Pid =:= WritePid of
                true ->
                    {Pid, w};
                false ->
                    case process_info(Pid, current_function) of
                        {current_function, {erlang, hibernate, 3}} ->
                            {Pid, h};
                        _ ->
                            {Pid, r}
                    end
            end
        end
        , lists:sort(TopicTimestampPid)
    ).