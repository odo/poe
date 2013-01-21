-module(poe_protocol).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(LENGTHSIZE, 32).
-define(MESSAGETYPESIZE, 16).
-define(POINTERSIZE, 56).
-define(LIMITSIZE, 32).

-define(POINTERREQUEST, 0).
-define(DATAREPLY, 1).

-export([
	encode_pointer_request/3
	, encode_data_reply/1
	, socket/2
	, command/1
]).

% the messages used by poe are composed following the schema:
% 32 bit int: RequestLength
% 16 bit int: MessageType
% RequestLength - 16 bits bitstring: MessageBody

% Depending on the MessageType, the format of the MessageBody is:

	% PointerRequest
	% MessageType: 0
	% 56 bit int: Pointer
	% 32 bit int: Limit
	% RequestLength - 16 - 56 -32 bits bitstring: Topic

	% DataReply
	% MessageType: 1
	% RequestLength - 16 bits bitstring: Messages
	% each Message has the following format:
		% 32 bit int: MessageLength
		% 56 bit int: Pointer
		% MessageLength - 56 bit bitstring: Message

socket(Host, Port) ->
	{ok, Socket} = gen_tcp:connect(Host, Port, [binary, {active, false}, {packet, raw}]),
	Socket.

command(Socket) ->
	{ok, LengthBin} = gen_tcp:recv(Socket, round(?LENGTHSIZE / 8)),
	{Length, _} = split_length(LengthBin),
	{ok, Req} = gen_tcp:recv(Socket, round(Length / 8)),
	decode_request(Req).

decode_request(Req) ->
	{MessageType, Rest} = split_message_type(Req),
	decode_command(MessageType, Rest).

decode_command(?POINTERREQUEST, Data) ->
	{Pointer, Rest} = split_pointer(Data),
	{Limit, Topic} = split_limit(Rest),
	{pointer_request, Topic, Pointer, Limit};

decode_command(?DATAREPLY, Data) ->
	Messages = decode_messages(Data),
	{data_reply, Messages};

decode_command(Command, _) ->
	throw({error, {unknown_command, Command}}).

encode_pointer_request(Topic, Pointer, Limit) when is_binary(Topic) andalso is_integer(Pointer) andalso is_integer(Limit) ->
	Body = add_message_type(?POINTERREQUEST, add_pointer(Pointer, add_limit(Limit, Topic))),
	add_length(bit_size(Body), Body).

encode_data_reply(Messages) ->
	Body = add_message_type(?DATAREPLY, encode_messages(Messages)),
	add_length(bit_size(Body), Body).

encode_messages([]) ->
	<<>>;

encode_messages([{Pointer, Message}|Messages]) ->
	Body = add_pointer(Pointer, Message),
	MessageBin = add_length(bit_size(Body), Body),
	MessagesRestBin = encode_messages(Messages),
	<< MessageBin/binary, MessagesRestBin/binary >>.

decode_messages(<<>>) ->
	[];
decode_messages(Data) ->
	{Length, Rest1} = split_length(Data),
	{Pointer, Rest2} = split_pointer(Rest1),
	MessageLength = Length - ?POINTERSIZE,
	<< Message:MessageLength/bitstring, Rest3/binary >> = Rest2,
	[{Pointer, Message}|decode_messages(Rest3)].
	
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

-ifdef(TEST).

store_test_() ->
    [{foreach, local,
      fun test_setup/0,
      fun test_teardown/1,
      [
        {"encoding and decoding pointer request works", fun test_pointer_request/0}
        , {"encoding and decoding data reply works", fun test_data_reply/0}
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
	?assertEqual({pointer_request, <<"topic">>, 123, 321}, command('_')).

test_data_reply() ->
	Request = encode_data_reply([{7, <<"seven">>}, {8, <<"ate">>}, {9, <<"nine">>}]),
	set_socket(Request),
	?assertEqual({data_reply, [{7, <<"seven">>}, {8, <<"ate">>}, {9, <<"nine">>}]}, command('_')).

-endif.
