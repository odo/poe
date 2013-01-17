%% @doc: server managing instances of appendix_server
%% and dispatching read and write requests.

-module(poe_server).
-behaviour(gen_server).

%% API
-export([start_link/1, stop/1]).
-export([
    create_partition/1
    , maybe_create_new_partitions/0
    , topics/0
    , write_pid/1
    , read_pid/2
    ]).

%% gen_server callbacks
-export([
    init/1
    , handle_call/3
    , handle_cast/2
    , handle_info/2
    , terminate/2
    , code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {base_dir, pid_table, ref_table, topics}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(BaseDir) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [BaseDir], []).

create_partition(Topic) ->
    gen_server:call(?SERVER, {create_partition, Topic}).

topics() ->
    gen_server:call(?SERVER, {topics}).

maybe_create_new_partitions() ->
    gen_server:call(?SERVER, {maybe_create_new_partitions}).

stop(Pid) ->
    gen_server:call(Pid, stop).

% server  1           2
%         |-----|     |-------|
% A       !   ? 
% B                ?  !
% C                   !          ?
% D ?     !
read_pid(Topic, Timestamp) ->
    case prev_server(Topic, Timestamp) of
        PidPrev when is_pid(PidPrev) ->
            case pointer_high(PidPrev) > Timestamp of
                % case A
                true ->
                    PidPrev;
                false ->
                    case next_server(Topic, Timestamp) of
                        % case B
                        PidNext when is_pid(PidNext) ->
                            PidNext;
                        % case C
                        not_found ->
                            PidPrev
                    end
            end;
        not_found ->
            % case D
            next_server(Topic, Timestamp)
    end.

prev_server(Topic, Timestamp) ->
    case ets:prev(poe_ref_table, {Topic, Timestamp}) of
        Key = {Topic, _} ->
            [{Key, Pid}] = ets:lookup(poe_ref_table, Key),
            Pid;
        _ -> 
            not_found
        end.

next_server(Topic, Timestamp) ->
    case ets:next(poe_ref_table, {Topic, Timestamp}) of
        Key = {Topic, _} ->
            [{Key, Pid}] = ets:lookup(poe_ref_table, Key),
            Pid;
        _ -> 
            not_found
        end.

pointer_high(Pid) ->
    Key = {{p,l,appendix_server},Pid},
    [{Key, Pid, Data}] = ets:lookup(gproc, Key),
    proplists:get_value(pointer_high, Data).

write_pid(Topic) ->
    % see if we have that topic, if not, create a writer
    case ets:match(poe_ref_table, {{Topic, '_'}, '$1'}) of
        [] ->
            create_partition(Topic);
        Pids ->
            hd(lists:last(Pids))
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([BaseDir]) ->
    file:make_dir(BaseDir),
    file:make_dir(topics_dir(BaseDir)),
    PidTable = ets:new(poe_pid_table, [set, protected, named_table]),
    RefTable = ets:new(poe_ref_table, [ordered_set, protected, named_table]),
    start_from_dir(BaseDir),
    {ok, #state{base_dir = BaseDir, pid_table = PidTable, ref_table = RefTable, topics = []}}.

handle_call({create_partition, Topic}, _From, State = #state{topics = Topics}) ->
    Now = timestamp(),
    Signature = {Topic, Now},
    TopicsDir = topics_dir(State#state.base_dir),
    TopicDir = TopicsDir ++ binary_to_list(Topic),
    file:make_dir(TopicsDir),
    file:make_dir(TopicDir),
    Pid = start_and_register_server(TopicDir ++ "/" ++ integer_to_list(Now), Signature),
    {reply, Pid, State#state{topics = [Topic|Topics]}};

handle_call({maybe_create_new_partitions}, _From, State = #state{topics = Topics}) ->
    Servers = appendix_server:servers(),
    MCNP = fun(T, Acc) ->
        case maybe_create_new_partition(T, Servers) of
            true ->
                [T|Acc];
            false ->
                Acc
        end
    end, 
    TopicsWithNewPartitions = lists:foldl(MCNP, [], Topics),
    {reply, TopicsWithNewPartitions, State};

handle_call({topics}, _From, State = #state{topics = Topics}) ->
    {reply, Topics, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% utilities
%%%===================================================================

topics_dir(BaseDir) ->
    BaseDir ++ "/" ++ "topics/".

start_and_register_server(Path, Signature) ->
    {ok, Pid} = poe_appendix_sup:start_child(Path),
    ets:insert(poe_pid_table, {Pid, Signature}),
    ets:insert(poe_ref_table, {Signature, Pid}),
    Pid.

start_from_dir(BaseDir) ->
    PathsAndSigs = find_paths_and_signatures(BaseDir),
    Register = fun(Path, Signature = {Topic, _}) ->
        start_and_register_server(Path, Signature),
        Topic
    end,   
    [Register(Path, Signature)||{Path, Signature}<-PathsAndSigs].

find_paths_and_signatures(BaseDir) ->
    TopicsDir = topics_dir(BaseDir),
    {ok, Topics} = file:list_dir(TopicsDir),
    PathAndSigFromTopic = fun(Topic) ->
        {ok, Files} = file:list_dir(TopicsDir ++ Topic),
        PathAndSig = fun(File, Acc) ->
            case binary:split(list_to_binary(File), <<"_">>) of
                [Time, <<"index">>] ->
                    [{TopicsDir ++ Topic ++ "/" ++ binary_to_list(Time), {list_to_binary(Topic), list_to_integer(binary_to_list(Time))}}, Acc];
                _ ->
                    Acc
            end
        end,
        lists:foldl(PathAndSig, [], Files)
    end,
    lists:flatten([PathAndSigFromTopic(T)||T<-Topics]).

timestamp() ->
    {MegaSecs, Secs, MicroSecs} = now(),
    (MegaSecs * 1000000 + Secs) * 1000000 + MicroSecs.

maybe_create_new_partition(Topic, Servers) ->
    io:format("Servers:~p\n", [Servers]),
    ServerData = [Data||{Data, Pid}<-Servers, Pid =:= write_pid(Topic)],
    io:format("ServerData for ~p :~p\n", [Topic, ServerData]),
    true.

