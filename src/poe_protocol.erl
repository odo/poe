-module(poe_protocol).

-define(INDEXSIZE, 7).
-define(INDEXSIZEBITS, (?INDEXSIZE * 8)).
-define(REQPOINTER, 1).
-define(SIZESIZE, 4).
-define(SIZESIZEBITS, (?SIZESIZE * 8)).

-export([
	encode_request_pointer/3
	, decode_request/1
	, decode_data/1
	, socket/2
]).

socket(Host, Port) ->
	{ok, Socket} = gen_tcp:connect(Host, Port, [binary, {active, false}, {packet, raw}]),
	Socket.

encode_request_pointer(Topic, Pointer, Limit) when is_binary(Topic) andalso is_integer(Pointer)->
	PointerBin = encode_pointer(Pointer),
	Data1 = << PointerBin/binary, Limit:32/integer >>,
	Data2 = << Data1/binary, Topic/binary >>,
	<< ?REQPOINTER:16/integer, Data2/binary >>.

decode_request(Req) ->
	<<Command:16/integer, Rest/binary>> = Req,
	decode_command(Command, Rest).

decode_command(?REQPOINTER, Data) ->
	<< PointerBin:?INDEXSIZE/binary, Limit:32/integer, Topic/binary >> = Data,
	{request_pointer, Topic, decode_pointer(PointerBin), Limit};

decode_command(_, _) ->
	unknown_command.

encode_pointer(Micros) ->
	<<Micros:?INDEXSIZEBITS>>.

decode_pointer(Index) ->
	binary:decode_unsigned(Index).

decode_data(<<>>) ->
	[];

decode_data(Data) ->
	<< Pointer:?INDEXSIZE/binary, SizeBin:?SIZESIZE/binary, Rest1/binary>> = Data,
	Size = binary:decode_unsigned(SizeBin),
	<< Item:Size/binary, Rest2/binary>> = Rest1,
	[{decode_pointer(Pointer), Item} | decode_data(Rest2)].
