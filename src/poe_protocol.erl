-module(poe_protocol).
-author('Florian Odronitz <odo@mac.com>').

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(LENGTHSIZE, 32).
-define(MESSAGETYPESIZE, 16).
-define(POINTERSIZE, 56).
-define(LIMITSIZE, 32).

-define(POINTERREQUEST, 0).
-define(DATAREPLY, 1).
-define(PUTREQUEST, 2).
-define(PUTREPLY, 3).

-export([
	encode_pointer_request/3
	, encode_put_request/2
	, encode_put_reply/1
	, socket/2
	, read_command/1
	, add_length/2
	, add_message_type/2
	, message_type/1
	, read/4
	, write/3
]).

% All sizes is on the wire are Bytes.

% The messages used by poe are composed following the schema:
% 32 bit int: RequestLength
% 16 bit int: MessageType
% RequestLength - 16 bits bitstring: MessageBody

% Depending on the MessageType, the format of the MessageBody is:

	% PointerRequest
	% request messages from the server
	% MessageType: 0
	% 56 bit int: Pointer
	% 32 bit int: Limit
	% RequestLength - 16 - 56 -32 bits bitstring: Topic

	% DataReply
	% MessageType: 1
	% send messages to the client
	% RequestLength - 16 bits bitstring: Messages
	% each Message has the following format:
		% 32 bit int: MessageLength
		% 56 bit int: Pointer
		% MessageLength - 56 bit bitstring: Message

	% PutRequest
	% MessageType: 2
	% send messages to the server
	% the order of messages on the wire is reversed
	% 56 bit int: Pointer
	% RequestLength - 16 bits bitstring: Messages
	% 32 bit int: TopicLength
	% TopicLength bits bitstring: Topic
	% MessageLength - 32 bits - TopicLength bitstring: Messages
	% each Message has the following format:
		% 32 bit int: MessageLength
		% MessageLength bitstring: Message

	% PutReply
	% indicates the the PutRequest was provcessed
	% and returns the pointer of the last message
	% MessageType: 3
	% 56 bit int: Pointer

message_type(pointer_request) ->
	?POINTERREQUEST;

message_type(data_reply) ->
	?DATAREPLY;

message_type(put_request) ->
	?PUTREQUEST.

%%%===================================================================
%%% API
%%%===================================================================

socket(Host, Port) ->
	{ok, Socket} = gen_tcp:connect(Host, Port, [binary, {active, false}, {packet, raw}]),
	Socket.

read(Topic, Pointer, Limit, Socket) when is_integer(Pointer) ->
	gen_tcp:send(Socket, encode_pointer_request(Topic, Pointer, Limit)),
	{data_reply, Messages} = read_command(Socket),
	Messages.

write(Topic, Messages, Socket) when is_binary(Topic) andalso is_list(Messages) ->
	gen_tcp:send(Socket, encode_put_request(Topic, Messages)),
	{put_reply, Pointer} = read_command(Socket),
	Pointer.

%%%===================================================================
%%% Reading and parsing commands
%%%===================================================================

read_command(Socket) ->
	case gen_tcp:recv(Socket, round(?LENGTHSIZE / 8)) of
		{error, closed} ->
			{error, closed};
	{ok, LengthBin} ->
		{Length, _} = split_length(LengthBin),
		{ok, Repl} = gen_tcp:recv(Socket, Length),
		decode_command(Repl)
	end.

decode_command(Req) ->
	{MessageType, Rest} = split_message_type(Req),
	decode_command(MessageType, Rest).

decode_command(?POINTERREQUEST, Data) ->
	{Pointer, Rest} = split_pointer(Data),
	{Limit, Topic} = split_limit(Rest),
	{pointer_request, Topic, Pointer, Limit};

decode_command(?DATAREPLY, Data) ->
	Messages = decode_server_messages(Data),
	{data_reply, Messages};

decode_command(?PUTREQUEST, Data) ->
	{TopicLength, Rest1} = split_length(Data),
	{Topic, Rest2} = split_bin(TopicLength * 8, Rest1),
	Messages = decode_client_messages(Rest2),
	{put_request, Topic, Messages};

decode_command(?PUTREPLY, Data) ->
	{Pointer, _} = split_pointer(Data),
	{put_reply, Pointer};

decode_command(ReadCommand, _) ->
	throw({error, {unknown_command, ReadCommand}}).

% decode messages coming from the server
% including pointers
decode_server_messages(<<>>) ->
	[];
decode_server_messages(Data) ->
	{Length, Rest1} = split_length(Data),
	{Pointer, Rest2} = split_pointer(Rest1),
	MessageLengthBits = Length * 8 - ?POINTERSIZE,
	<< Message:MessageLengthBits/bitstring, Rest3/binary >> = Rest2,
	[{Pointer, Message}|decode_server_messages(Rest3)].

% decode messages coming from the client
% not including pointers
decode_client_messages(<<>>) ->
	[];
decode_client_messages(Data) ->
	{Length, Rest1} = split_length(Data),
	MessageLengthBits = Length * 8,
	<< Message:MessageLengthBits/bitstring, Rest2/binary >> = Rest1,
	[Message|decode_client_messages(Rest2)].

%%%===================================================================
%%% Encoding commands
%%%===================================================================

encode_pointer_request(Topic, Pointer, Limit) when is_binary(Topic) andalso is_integer(Pointer) andalso is_integer(Limit) ->
	Body = add_message_type(?POINTERREQUEST, add_pointer(Pointer, add_limit(Limit, Topic))),
	add_length(byte_size(Body), Body).

encode_put_request(Topic, Messages) when is_list(Messages) ->
	TopicAndLength = add_length(byte_size(Topic), Topic),
	MessageBin = lists:foldl(fun(M, B) -> add_client_message(M, B) end, <<>>, lists:reverse(Messages)),
	TopicAndMessages = add_bin(TopicAndLength, MessageBin),
	Body = add_message_type(?PUTREQUEST, TopicAndMessages),
	add_length(byte_size(Body), Body).

encode_put_reply(Pointer) ->
	Body = add_message_type(?PUTREPLY, add_pointer(Pointer, <<>>)),
	add_length(byte_size(Body), Body).

%%%===================================================================
%%% Encoding and decoding binaries
%%%===================================================================

add_client_message(Message, Bin) when is_binary(Message)->
	add_length(byte_size(Message), add_bin(Message, Bin)).

add_pointer(Pointer, Bin) ->
	add_integer(Pointer, ?POINTERSIZE, Bin).

split_pointer(Bin) ->
	split_integer(?POINTERSIZE, Bin).

add_length(Length, Bin) ->
	add_integer(Length, ?LENGTHSIZE, Bin).

split_length(Bin) ->
	split_integer(?LENGTHSIZE, Bin).

add_message_type(MessageType, Bin) ->
	add_integer(MessageType, ?MESSAGETYPESIZE, Bin).

split_message_type(Bin) ->
	split_integer(?MESSAGETYPESIZE, Bin).

add_limit(Limit, Bin) ->
	add_integer(Limit, ?LIMITSIZE, Bin).

split_limit(Bin) ->
	split_integer(?LIMITSIZE, Bin).

add_integer(Integer, Size, Bin) ->
	<<Integer:Size, Bin/binary>>.	

split_integer(Size, Bin) ->
	<<Integer:Size/bitstring, Rest/binary>> = Bin,
	{binary:decode_unsigned(Integer), Rest}.	

add_bin(BinAdd, Bin) ->
	<<BinAdd/binary, Bin/binary>>.	

split_bin(Length, Bin) ->
	<<BinSplit:Length/bitstring, Rest/binary>> = Bin,
	{BinSplit, Rest}.

%%%===================================================================
%%% Tests
%%%===================================================================

-ifdef(TEST).

store_test_() ->
    [{foreach, local,
      fun test_setup/0,
      fun test_teardown/1,
      [
        {"encoding and decoding pointer request works", fun test_pointer_request/0}
        , {"encoding and decoding put request works", fun test_put_request/0}
        , {"encoding and decoding put reply works", fun test_put_reply/0}
        ]}
    ].

test_setup() ->
	meck:new(gen_tcp, [unstick]).

test_teardown(_) ->
	meck:unload(gen_tcp).

set_socket(Data) ->
	SetSocketInt = fun(SetSocketFun, DataInt) -> 
		meck:expect(
			gen_tcp,
			recv,
			fun(_Socket, Length) ->
				<< Read:Length/binary, RestData/binary >> = DataInt,
				SetSocketFun(SetSocketFun, RestData),
				{ok, Read}
			end
		)
	end,
	SetSocketInt(SetSocketInt, Data).

test_pointer_request() ->
	Request = encode_pointer_request(<<"topic">>, 123, 321),
	set_socket(Request),
	?assertEqual({pointer_request, <<"topic">>, 123, 321}, read_command('_')).

test_put_request() ->
	Request = encode_put_request(<<"topic">>, [<<"1">>, <<"2">>, <<"3">>]),
	set_socket(Request),
	?assertEqual({put_request, <<"topic">>, [<<"1">>, <<"2">>, <<"3">>]}, read_command('_')).

test_put_reply() ->
	Request = encode_put_reply(1234567),
	set_socket(Request),
	?assertEqual({put_reply, 1234567}, read_command('_')).

-endif.
