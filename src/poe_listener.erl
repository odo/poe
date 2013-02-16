-module(poe_listener).
-author('Florian Odronitz <odo@mac.com>').

-export([start_link/4, init/4]).

start_link(ListenerPid, Socket, Transport, Opts) ->
	Pid = spawn_link(?MODULE, init, [ListenerPid, Socket, Transport, Opts]),
	{ok, Pid}.

init(ListenerPid, Socket, Transport, _Opts = []) ->
	ok = ranch:accept_ack(ListenerPid),
	loop(Socket, Transport).

loop(Socket, ranch_tcp) ->
	case poe_protocol:read_command(Socket) of
		{pointer_request, Topic, Pointer, Limit} ->
				Server = poe_server:read_pid(Topic, Pointer),
				Header1 = poe_protocol:add_message_type(poe_protocol:message_type(data_reply), <<>>),
				case appendix_server:file_pointer(Server, Pointer, Limit) of
					{FileName, Position, LengthData} ->
						Length = LengthData + byte_size(Header1),
						Header2 = poe_protocol:add_length(Length, Header1),
						gen_tcp:send(Socket, Header2),
						{ok, File} = file:open(FileName, [raw, binary]),
						{ok, LengthData} = file:sendfile(File, Socket, Position, LengthData, []),
						file:close(File);
					not_found ->
						Length = byte_size(Header1),
						Header2 = poe_protocol:add_length(Length, Header1),
						gen_tcp:send(Socket, Header2)
				end,
				loop(Socket, ranch_tcp);
		{put_request, Topic, Messages} ->
			Pointer = lists:foldl(fun(M, _) -> poe:put(Topic, M) end, {}, Messages),
			Reply = poe_protocol:encode_put_reply(Pointer),
			gen_tcp:send(Socket, Reply),
			loop(Socket, ranch_tcp);
		_ ->
			ok = ranch_tcp:close(Socket)
	end.