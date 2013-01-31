-module(poe_appendix_sup).

-behaviour(supervisor).

-define(SERVER, ?MODULE).

-export([start_link/0, start_child/2, init/1]).

start_link() ->
	supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_child(Topic, Dir) ->
	supervisor:start_child(?SERVER, [Dir, Topic, [{use_gproc, true}]]).

init([]) ->
	AppendixServer = {appendix_server, {appendix_server, start_link_with_id, []}, temporary, 5000, worker, [appendix_server, bisect]},
	RestartStrategy = {simple_one_for_one, 10, 1},
	{ok, {RestartStrategy, [AppendixServer]}}.