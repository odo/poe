-module(poe_test).

-ifdef(TEST).
-compile([export_all]).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-define(TESTDIR, "/tmp/poe_test_dir").
-define(TESTTOPIC, <<"test_topic">>).
-define(TESTTOPIC2, <<"test_topic2">>).
-define(TESTDATA, <<"test_data">>).
-define(TESTDATA2, <<"test_data2">>).

test_setup() ->
	% application:start(sasl),
	os:cmd("rm -r " ++ ?TESTDIR),
	application:set_env(poe, dir, ?TESTDIR),
    % application:start(sasl),
    application:start(poe).

test_teardown(_) ->
    application:stop(poe).

store_test_() ->
    [{foreach, local,
      fun test_setup/0,
      fun test_teardown/1,
      [
        {"new server is empty", fun test_blank/0}
        , {"write creates topic", fun test_create_topic/0}
        , {"get next", fun test_get_next/0}
        , {"test_creation_of_partitions", fun test_partition/0}
        , {"properties", timeout, 1200, fun proper_test/0}
        ]}
    ].

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

proper_test() ->
	?assert(proper:quickcheck(proper_poe(), [{to_file, user}, {numtests, 100}])).

-record(proper_state, {data = []}).

proper_poe() ->
    ?FORALL(Cmds, commands(?MODULE),
            ?TRAPEXIT(
               begin
                   test_setup(),
                   {History, State, Result} = run_commands(?MODULE, Cmds),
                   test_teardown('_'),
                   ?WHENFAIL(io:format("History: ~p\nState: ~p\nResult: ~p\n",
                                       [History, State, Result]),
                             aggregate(command_names(Cmds), Result =:= ok))
                end)
	).

initial_state() ->
     #proper_state{}.

topic() ->
	elements([<<"topic1">>, <<"topic2">>, <<"topic3">>, <<"topic4">>, <<"topic5">>]).


command(_S) ->
    oneof([
    	{call, ?MODULE, proper_test_put, [topic(), binary()]}
        , {call, ?MODULE, proper_test_get_all_by_next, [topic()]}
        , {call, ?MODULE, proper_test_create_partition, [topic()]}
	]).

precondition(State, {call, ?MODULE, proper_test_get_all_by_next, [Topic]}) ->
	case proplists:get_value(Topic, State#proper_state.data, []) of
		[] ->
			false;
		_ ->
			true
	end;

precondition(State, {call, ?MODULE, proper_test_put, [Topic, Data]}) ->
	byte_size(Topic) > 0 andalso byte_size(Data) > 0;

precondition(_, _) ->
    true.

next_state(State, _, {call, _, proper_test_put, [Topic, Data]}) ->
	DataTopic = proplists:get_value(Topic, State#proper_state.data, []),
	DataNew1 = proplists:delete(Topic, State#proper_state.data),
	DataNew2 = [{Topic, [Data|DataTopic]}|DataNew1],
    State#proper_state{data = DataNew2};

next_state(S, _, _) ->
    S.

postcondition(_, {call, _, proper_test_put, [_, _]}, Result) ->
    is_integer(Result);

postcondition(_, {call, _, proper_test_create_partition, [_]}, Result) ->
    is_pid(Result);

postcondition(State, {call, _, proper_test_get_all_by_next, [Topic]}, Result) ->
    Result =:= proplists:get_value(Topic, State#proper_state.data, []).

proper_test_put(Topic, Data) ->
	poe:put(Topic, Data).

proper_test_get_all_by_next(Topic) ->
	lists:reverse(proper_test_get_all_by_next(Topic, 0)).

proper_test_get_all_by_next(Topic, Pointer) ->
	case poe:next(Topic, Pointer) of
		{PointerNew, Data} ->
			[Data|proper_test_get_all_by_next(Topic, PointerNew)];
		not_found ->
			[]
	end.

proper_test_create_partition(Topic) ->
	poe_server:create_partition(Topic).

-endif.