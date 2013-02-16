-module(poe).
-author('Florian Odronitz <odo@mac.com>').

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
		, {worker_timeout, 1}
		, {port, 5555}
		, {max_age, infinity}
	]
).

-type topic() :: binary().
-type pointer() :: non_neg_integer().
-type message() :: binary().
-type server_type() :: w|w|h.

-export_type([topic/0, pointer/0, message/0]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

-spec start() -> ok | {error, term()}.
start() ->
	start([]).

-spec start(list()) -> ok | {error, term()}.
start(Options) ->
	[read_from_options(Key, Default, Options)||{Key, Default}<-?DEFAULTS],
	application:start(poe).

-spec start(term(), term()) -> {ok, pid()}.
start(_StartType, _StartArgs) ->
	start_listener(env_or_throw(port)),
	case poe_sup:start_link(env_or_throw(dir)) of
		{ok, Pid} ->
			{ok, Pid};
		{error, {already_started, Pid}} ->
			{ok, Pid};
		Error ->
			throw(Error)
	end.

-spec stop(term()) -> ok.
stop(_State) ->
	% we are only stopping the listener here
	% since other applications might depend on ranch
	ranch:stop_listener(poe_tcp_listener),
    ok.

-spec start_listener(non_neg_integer()) -> pid().
start_listener(Port)->
	case application:start(ranch) of
		ok ->
			ok;
		{error, {already_started, ranch}} ->
			ok;
		E ->
			throw(E)
	end,
	{ok, Pid} = ranch:start_listener(poe_tcp_listener, 10, ranch_tcp, [{port, Port}], poe_listener, []),
	Pid.

read_from_options(Key, Default, Options) ->
	case proplists:get_value(Key, Options, Default) of
		undefined ->
			noop;
		Value ->
			application:set_env(poe, Key, Value)
	end.

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

-spec topics() -> [topic()].
topics() ->
	poe_server:topics().

-spec put(topic(), message()) -> pointer().
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

-spec next(topic(), pointer()) -> {pointer(), message()} | not_found.
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

-spec print_status() -> ok.
print_status() ->
    lists:map(
        fun({T, Servers}) ->
            io:format("~ts\t:", [T]),
            [io:format("~p", [State])||{_Pid, State}<-Servers],
            io:format("\n", [])
        end,
        status()
        ),
  	ok.

-spec status() -> [{topic(), [{pid(), server_type()}]}].
status() ->
    [{T, topic_status(T)}||T<-topics()].

-spec topic_status(topic()) -> [{pid(), server_type()}].
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