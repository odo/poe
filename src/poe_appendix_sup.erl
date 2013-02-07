-module(poe_appendix_sup).

-behaviour(supervisor).

-define(SERVER, ?MODULE).

-export([start_link/0, start_child/4, init/1]).

start_link() ->
	supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_child(Topic, Dir, BufferCountMax, Timeout) ->
	supervisor:start_child(?SERVER, [Dir, [{id, Topic}, {buffer_count_max, BufferCountMax}, {timeout, Timeout}]]).

init([]) ->
	AppendixServer = {appendix_server, {appendix_server, start_link, []}, temporary, 5000, worker, [appendix_server, bisect]},
	RestartStrategy = {simple_one_for_one, 10, 1},
	{ok, {RestartStrategy, [AppendixServer]}}.