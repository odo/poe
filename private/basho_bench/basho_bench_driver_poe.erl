-module(basho_bench_driver_poe).

-export([new/1,
         run/4]).

-include("basho_bench.hrl").

-record(state, { read_pointer, read_socket, write_socket, server}).

%% ====================================================================
%% API
%% ====================================================================

new(_Id) ->
    observer:start(),
    application:set_env(poe, dir, "/tmp/poe_benchmark"),
    poe:start(),
    % we are doind one write, so if the first command is a read, it won't fail
    poe_protocol:write(<<"t">>, [<<"hello">>], poe_protocol:socket("127.0.0.1", 5555)),
    State = #state{
        read_socket = poe_protocol:socket("127.0.0.1", 5555)
        , write_socket = poe_protocol:socket("127.0.0.1", 5555)
        , read_pointer = 0
        , server = poe_server:write_pid(<<"t">>)
    },
    {ok, State}.

run(read, _KeyGen, _ValueGen, State) ->
    ReadPointerNew =
    case poe_protocol:read(<<"t">>, State#state.read_pointer, 100, State#state.read_socket) of
        [] ->
            error_logger:info_msg("reader wrapping\n", []),
            0;
        Data ->
            {P2, _} = lists:last(Data),
            P2
    end,
    {ok, State#state{read_pointer = ReadPointerNew}};

run(write, _KeyGen, ValueGen, State) ->
    Msg = ValueGen(),
    Msgs = lists:foldl(fun(_, L) -> [Msg|L] end, [], lists:seq(1, 100)),
    poe_protocol:write(<<"t">>, Msgs, State#state.write_socket),
    {ok, State};

run(write_straigt, _KeyGen, ValueGen, State) ->
    Msg = ValueGen(),
    appendix_server:put(State#state.server, Msg),
    {ok, State};

run(write_pid, _KeyGen, ValueGen, State) ->
    poe_server:write_pid(<<"t">>),
    {ok, State}.
