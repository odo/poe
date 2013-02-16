-module(basho_bench_driver_poe).

-export([new/1,
         run/4]).

-include("basho_bench.hrl").

-record(state, {read_pointers, read_socket, write_socket, server}).

-define(NOTOPICS, 3).

%% ====================================================================
%% API
%% ====================================================================

topic() ->
    list_to_binary(integer_to_list(round(random:uniform() * (?NOTOPICS - 1)))).

new(_Id) ->
    State = #state{
        read_socket = poe_protocol:socket("127.0.0.1", 5555)
        , write_socket = poe_protocol:socket("127.0.0.1", 5555)
        , read_pointers = []
    },
    {ok, State}.

run(read, _KeyGen, _ValueGen, State) ->
    read(false, State);
run(read_wrap, _KeyGen, _ValueGen, State) ->
    read(true, State);

run(write, _KeyGen, ValueGen, State) ->
    Msg = ValueGen(),
    Msgs = lists:foldl(fun(_, L) -> [Msg|L] end, [], lists:seq(1, 100)),
    poe_protocol:write(topic(), Msgs, State#state.write_socket),
    {ok, State};

run(write_mini, _KeyGen, _ValueGen, State) ->
    Msg = <<"o">>,
    Msgs = lists:foldl(fun(_, L) -> [Msg|L] end, [], lists:seq(1, 100)),
    poe_protocol:write(topic(), Msgs, State#state.write_socket),
    {ok, State}.

read(Wrap, State) ->
    Topic = topic(),
    Pointers = State#state.read_pointers,
    Pointer = proplists:get_value(Topic, Pointers, 0),
    ReadPointerNew =
    case poe_protocol:read(Topic, Pointer, 100, State#state.read_socket) of
        [] ->
            case Wrap of
                true ->
                    error_logger:error_msg("reader wrapping\n", []),
                    0;
                false ->
                    error_logger:error_msg("reader starving\n", []),
                    Pointer
            end;
        Data ->
            {P2, _} = lists:last(Data),
            P2
    end,
    {ok, State#state{read_pointers = [{Topic, ReadPointerNew}|proplists:delete(Topic, Pointers)]}}.
