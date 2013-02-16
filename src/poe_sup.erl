-module(poe_sup).

-behaviour(supervisor).

-define(SERVER, ?MODULE).

-export([start_link/1, init/1]).

-spec start_link(list()) -> {ok, pid()} | ignore | {error, {already_started, pid()} | {shutdown, term()} | term()}.
start_link(BaseDir) ->
	supervisor:start_link({local, ?SERVER}, ?MODULE, [BaseDir]).

init([BaseDir]) ->
	AppendixSup = {poe_appendix_sup, 	{poe_appendix_sup, start_link, []}, permanent, infinity, supervisor, [poe_appendix_sup, appendix_server, appendix, bisect]},
	PoeServer =   {poe_server,			{poe_server, start_link, [BaseDir]}, permanent, 5000, worker, [poe_server]},
	RestartStrategy = {one_for_one, 10, 1},
	{ok, {RestartStrategy, [AppendixSup, PoeServer]}}.