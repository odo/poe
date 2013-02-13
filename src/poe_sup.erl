-module(poe_sup).

-behaviour(supervisor).

-define(SERVER, ?MODULE).

-export([start_link/1, init/1]).

start_link(BaseDir) ->
	supervisor:start_link({local, ?SERVER}, ?MODULE, [BaseDir]).

init([BaseDir]) ->
	Port = proplists:get_value(port, application:get_all_env(poe)),
	AppendixSup = {poe_appendix_sup, 	{poe_appendix_sup, start_link, []}, permanent, infinity, supervisor, [poe_appendix_sup, appendix_server, appendix, bisect]},
	PoeServer =   {poe_server,			{poe_server, start_link, [BaseDir]}, permanent, 5000, worker, [poe_server]},
	RanchSup = {ranch_sup, {ranch_sup, start_link, []}, permanent, 5000, supervisor, [ranch_sup]},
    Listener = ranch:child_spec(poe_tcp_listener, 1, ranch_tcp, [{port, Port}], poe_listener, []),
	RestartStrategy = {one_for_one, 10, 1},
	{ok, {RestartStrategy, [AppendixSup, PoeServer, RanchSup, Listener]}}.