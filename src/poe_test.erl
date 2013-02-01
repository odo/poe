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
        , {"test creation of partitions", fun test_partition/0}
        , {"test crash", fun test_crash/0}
        , {"properties", timeout, 300, fun test_properties/0}
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
	?assertEqual([?TESTTOPIC, ?TESTTOPIC2], poe:topics()),
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
	?assertEqual(Reader1, poe_server:read_pid(?TESTTOPIC, 0)),
	Reader1 = poe_server:read_pid(?TESTTOPIC, Pointer - 1),
	Reader2 = poe_server:read_pid(?TESTTOPIC, Pointer),
	Writer2 = poe_server:write_pid(?TESTTOPIC),
	?assert(Writer1 =/= Writer2),
	?assert(Reader1 =/= Reader2),
	poe:put(?TESTTOPIC, ?TESTDATA2),
	{Pointer,  ?TESTDATA} = poe:next(?TESTTOPIC, Pointer - 1),
	{Pointer2, ?TESTDATA2} = poe:next(?TESTTOPIC, Pointer),
	not_found = poe:next(?TESTTOPIC, Pointer2).

test_crash() ->
	Pointer = poe:put(?TESTTOPIC, ?TESTDATA),
	?assertEqual({Pointer, ?TESTDATA}, poe:next(?TESTTOPIC, 0)),
	Pid = poe_server:write_pid(?TESTTOPIC),
	Info1 = appendix_server:info(Pid),
	crash(Pid),
	?assertEqual(Info1, appendix_server:info(poe_server:write_pid(?TESTTOPIC))),
	?assertEqual({Pointer, ?TESTDATA}, poe:next(?TESTTOPIC, 0)),
	Pid2 = poe_server:create_partition(?TESTTOPIC),
	Pointer2 = poe:put(?TESTTOPIC, ?TESTDATA),
	crash(Pid),
	?assertEqual({Pointer, ?TESTDATA}, poe:next(?TESTTOPIC, 0)),
	?assertEqual({Pointer2, ?TESTDATA}, poe:next(?TESTTOPIC, Pointer)),
	crash(Pid2),
	?assertEqual({Pointer, ?TESTDATA}, poe:next(?TESTTOPIC, 0)),
	?assertEqual({Pointer2, ?TESTDATA}, poe:next(?TESTTOPIC, Pointer)),
	crash(Pid),
	crash(Pid2),
	?assertEqual({Pointer, ?TESTDATA}, poe:next(?TESTTOPIC, 0)),
	?assertEqual({Pointer2, ?TESTDATA}, poe:next(?TESTTOPIC, Pointer)).

crash(Pid) ->
	try
		appendix_server:sync_and_crash(Pid)
	catch
		exit:_ -> noop
	end.


test_properties() ->
	?assert(proper:quickcheck(proper_poe(), [{to_file, user}, {numtests, 250}])).

-record(proper_state, {data = []}).

proper_poe() ->
    ?FORALL(Cmds, commands(?MODULE),
            ?TRAPEXIT(
               begin
                   test_setup(),
                   {History, State, Result} = run_commands(?MODULE, Cmds),
                   test_teardown('_'),
                   ?WHENFAIL(io:format(":Result ~p\nState: ~p\nHistory: ~p\n",
                                       [Result, State, History]),
                             aggregate(command_names(Cmds), Result =:= ok))
                end)
	).

initial_state() ->
     #proper_state{}.

topic() ->
	elements([<<"topic1">>, <<"topic2">>, <<"topic3">>, <<"topic4">>, <<"topic5">>]).

limit() ->
	elements([2, 10, 100, 1000]).

command(_S) ->
    oneof([
    	{call, ?MODULE, proper_test_put, [topic(), binary()]}
    	, {call, ?MODULE, proper_test_put_by_socket, [topic(), [binary()]]}
        , {call, ?MODULE, proper_test_get_all_by_next, [topic()]}
        , {call, ?MODULE, proper_test_get_all_by_socket, [topic(), limit()]}
        % , {call, ?MODULE, proper_test_create_partition, [topic()]}
        , {call, ?MODULE, proper_test_kill_server, [topic()]}
	]).

precondition(State, {call, ?MODULE, proper_test_get_all_by_next, [Topic]}) ->
	case proplists:get_value(Topic, State#proper_state.data, []) of
		[] ->
			false;
		_ ->
			true
	end;

precondition(State, {call, ?MODULE, proper_test_get_all_by_socket, [Topic, _]}) ->
	case proplists:get_value(Topic, State#proper_state.data, []) of
		[] ->
			false;
		_ ->
			true
	end;

precondition(State, {call, ?MODULE, proper_test_kill_server, [Topic]}) ->
	case proplists:get_value(Topic, State#proper_state.data, []) of
		[] ->
			false;
		_ ->
			true
	end;

precondition(_, {call, ?MODULE, proper_test_put, [Topic, Data]}) ->
	byte_size(Topic) > 0 andalso byte_size(Data) > 0;

precondition(_, {call, ?MODULE, proper_test_put_by_socket, [Topic, Messages]}) ->
	byte_size(Topic) > 0 andalso lists:all( fun(M) -> byte_size(M) > 0 end, Messages);

precondition(_, _) ->
    true.

next_state(State, _, {call, _, proper_test_put, [Topic, Data]}) ->
	DataTopic = proplists:get_value(Topic, State#proper_state.data, []),
	DataNew1 = proplists:delete(Topic, State#proper_state.data),
	DataNew2 = [{Topic, [Data|DataTopic]}|DataNew1],
    State#proper_state{data = DataNew2};

next_state(State, _, {call, _, proper_test_put_by_socket, [Topic, Messages]}) ->
	DataTopic = proplists:get_value(Topic, State#proper_state.data, []),
	DataNew1 = proplists:delete(Topic, State#proper_state.data),
	DataNew2 = [{Topic, lists:concat([Messages, DataTopic])}|DataNew1],
    State#proper_state{data = DataNew2};

next_state(S, _, _) ->
    S.

postcondition(_, {call, _, proper_test_put, [_, _]}, Result) ->
    is_integer(Result);

postcondition(_, {call, _, proper_test_put_by_socket, [_, _]}, Result) ->
    is_integer(Result);

% postcondition(_, {call, _, proper_test_create_partition, [_]}, Result) ->
%     Result =:= noop orelse is_pid(Result);

postcondition(State, {call, _, proper_test_get_all_by_socket, [Topic, _]}, Result) ->
	match_or_log(Result, proplists:get_value(Topic, State#proper_state.data, []), {proper_test_get_all_by_socket, Topic});

postcondition(State, {call, _, proper_test_get_all_by_next, [Topic]}, Result) ->
	match_or_log(Result, proplists:get_value(Topic, State#proper_state.data, []), {proper_test_get_all_by_next, Topic});

postcondition(_State, {call, _, proper_test_kill_server, [_Topic]}, _Result) ->
    true.

match_or_log(Result, Expected, Label) ->
	case Result =:= Expected of
		true ->
			true;
		false ->
			error_logger:info_msg("Postcondition mismatch:\n", []),
			error_logger:info_msg("~p Result: ~p\n", [Label, Result]),
			error_logger:info_msg("~p Expected: ~p\n", [Label, Expected]),
			false
	end.

proper_test_put(Topic, Data) ->
	poe:put(Topic, Data).

proper_test_put_by_socket(Topic, Messages) ->
	Socket = poe_protocol:socket("127.0.0.1", 5555),
	Pointer = poe_protocol:write(Topic, Messages, Socket),
	gen_tcp:close(Socket),
	Pointer.


proper_test_get_all_by_next(Topic) ->
	lists:reverse(proper_test_get_all_by_next(Topic, 0)).

proper_test_get_all_by_next(Topic, Pointer) ->
	case poe:next(Topic, Pointer) of
		{PointerNew, Data} ->
			[Data|proper_test_get_all_by_next(Topic, PointerNew)];
		not_found ->
			[]
	end.

proper_test_get_all_by_socket(Topic, Limit) ->
	Socket = poe_protocol:socket("127.0.0.1", 5555),
	Ret = lists:reverse(lists:flatten(proper_test_get_all_by_socket(Topic, Limit, 0, Socket))),
	gen_tcp:close(Socket),
	Ret.

proper_test_get_all_by_socket(Topic, Limit, Pointer, Socket) ->
	case poe_protocol:read(Topic, Pointer, Limit, Socket) of
		[] ->
			[];
		Data ->
			{PointerNew, _} = lists:last(Data),
			error_logger:info_msg("Data in proper_test_get_all_by_socket: ~p\n", [Data]),
			[[D||{_P, D} <-Data]|proper_test_get_all_by_socket(Topic, Limit, PointerNew, Socket)]
	end.

% proper_test_create_partition(Topic) ->
% 	% we are not creating a new partion when the latest one is empty
% 	poe_serserver(Topic, timestamp()),
% 	case proplists:get_value(count, appendix_server:info(poe_server:write_pid(Topic))) of
% 		0 ->
% 			noop;
% 		_ ->
% 			poe_server:create_partition(Topic)
% 	end.

proper_test_kill_server(Topic) ->
	Pids = [P||[{P, {T, _, _}}]<-ets:match(poe_server_tracker, '$1'), T =:= Topic],
	% Pids = [P||{_Data, P}<-appendix_server:servers(Topic)],
	% there might be no server
	case length(Pids) of
		0 ->
			noop;
		_ ->
			Pid = lists:nth(round(random:uniform() * (length(Pids) - 1)) + 1, Pids),
			crash(Pid)
	end.

-endif.