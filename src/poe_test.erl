-module(poe_test).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(TESTDIR, "/tmp/poe_test_dir").
-define(TESTTOPIC, <<"test_topic">>).
-define(TESTTOPIC2, <<"test_topic2">>).
-define(TESTDATA, <<"test_data">>).
-define(TESTDATA2, <<"test_data2">>).
-endif.

-ifdef(TEST).

store_test_() ->
    [{foreach, local,
      fun test_setup/0,
      fun test_teardown/1,
      [
        {"the protocol works", fun test_protocol/0}
        , {"new server is empty", fun test_blank/0}
        , {"write creates topic", fun test_create_topic/0}
        , {"get next", fun test_get_next/0}
        , {"test_creation_of_prtitions", fun test_partition/0}
        ]}
    ].

test_protocol() ->
	{Topic, Pointer, Limit} = {<<"the_topic">>, 1234567, 100},
	Enc = poe_protocol:encode_request_pointer(Topic, Pointer, Limit),
	Dec = poe_protocol:decode_request(Enc),
	?assertEqual({request_pointer, Topic, Pointer, Limit}, Dec).

test_blank() ->
	?assertThrow({unknown_topic, ?TESTTOPIC}, poe:next(?TESTTOPIC, 0)).

test_create_topic() ->
	?assertEqual([], poe:topics()),
	poe:put(?TESTTOPIC, ?TESTDATA),
	?assertEqual([?TESTTOPIC], poe:topics()),
	{_, Data} = poe:next(?TESTTOPIC, 0),
	?assertEqual(?TESTDATA, Data),
	poe:put(?TESTTOPIC2, ?TESTDATA2),
	?assert(poe_server:write_pid(?TESTTOPIC) =/= poe_server:write_pid(?TESTTOPIC2)),
	?assert(poe_server:read_pid(?TESTTOPIC, 0) =/= poe_server:read_pid(?TESTTOPIC2, 0)),
	?assertEqual([?TESTTOPIC2, ?TESTTOPIC], poe:topics()),
	{_, Data2} = poe:next(?TESTTOPIC2, 0),
	?assertEqual(?TESTDATA2, Data2).

test_get_next() ->
	poe:put(?TESTTOPIC, ?TESTDATA),
	{Pointer, Data} = poe:next(?TESTTOPIC, 0),
	?assertEqual({Pointer, Data}, poe:next(?TESTTOPIC, Pointer - 1)),
	?assertEqual(not_found, poe:next(?TESTTOPIC, Pointer)),
	?assertEqual(not_found, poe:next(?TESTTOPIC, Pointer + 1)).

test_partition() ->
	Pointer = poe:put(?TESTTOPIC, ?TESTDATA),
	{Pointer, ?TESTDATA} = poe:next(?TESTTOPIC, 0),
	Reader1 = poe_server:read_pid(?TESTTOPIC, Pointer - 1),
	Writer1 = poe_server:write_pid(?TESTTOPIC),
	poe_server:create_partition(?TESTTOPIC),
	Reader2 = poe_server:read_pid(?TESTTOPIC, Pointer),
	Writer2 = poe_server:write_pid(?TESTTOPIC),
	?assert(Writer1 =/= Writer2),
	?assert(Reader1 =/= Reader2),
	poe:put(?TESTTOPIC, ?TESTDATA2),
	{Pointer,  ?TESTDATA} = poe:next(?TESTTOPIC, Pointer - 1),
	{Pointer2, ?TESTDATA2} = poe:next(?TESTTOPIC, Pointer),
	not_found = poe:next(?TESTTOPIC, Pointer2).

test_setup() ->
	application:start(sasl),
	os:cmd("rm -r " ++ ?TESTDIR),
	application:set_env(poe, dir, ?TESTDIR),
    % application:start(sasl),
    application:start(poe).

test_teardown(_) ->
    application:stop(poe).

-endif.
