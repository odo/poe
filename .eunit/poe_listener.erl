-module(poe_listener).
-export([start_link/4, init/4]).

start_link(ListenerPid, Socket, Transport, Opts) ->
	Pid = spawn_link(?MODULE, init, [ListenerPid, Socket, Transport, Opts]),
	{ok, Pid}.

init(ListenerPid, Socket, Transport, _Opts = []) ->
	ok = ranch:accept_ack(ListenerPid),
	loop(Socket, Transport).

loop(Socket, ranch_tcp) ->
	case ranch_tcp:recv(Socket, 0, infinity) of
		{ok, Data} ->
			Reply = case poe_protocol:decode_request(Data) of
				unknown_command ->
					ranch_tcp:send(Socket, <<"unknown_command\n">>);
				{request_pointer, Topic, Pointer, Limit} ->
					Server = poe_server:read_pid(Topic, Pointer),
					{FileName, Position, Length} = appendix_server:file_pointer(Server, Pointer, Limit),
					{ok, File} = file:open(FileName, [raw, binary]),
					{ok, _BytesSent} = file:sendfile(File, Socket, Position, Length, []),
					file:close(File)
			end,
			error_logger:info_msg("Reply:", [Reply]),
			loop(Socket, ranch_tcp);
		_ ->
			ok = ranch_tcp:close(Socket)
	end.