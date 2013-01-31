%% @doc: server managing instances of appendix_server
%% and dispatching read and write requests.

-module(poe_server).
-behaviour(gen_server2).

%% API
-export([start_link/1, stop/1]).
-export([
    create_partition/1
    , maybe_create_new_partitions/0
    , topics/0
    , write_pid/1
    , read_pid/2
    ]).

%% gen_server2 callbacks
-export([
    init/1
    , prioritise_info/2
    , handle_call/3
    , handle_cast/2
    , handle_info/2
    , terminate/2
    , code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {base_dir, topics}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(BaseDir) ->
    gen_server2:start_link({local, ?SERVER}, ?MODULE, [BaseDir], []).

create_partition(Topic) ->
    gen_server2:call(?SERVER, {create_partition, Topic}).

topics() ->
    gen_server2:call(?SERVER, {topics}).

maybe_create_new_partitions() ->
    gen_server2:call(?SERVER, {maybe_create_new_partitions}).

stop(Pid) ->
    gen_server2:call(Pid, stop).

read_pid(Topic, Timestamp) ->
    gen_server2:call(?SERVER, {read_pid, Topic, Timestamp}).

write_pid(Topic) ->
    gen_server2:call(?SERVER, {write_pid, Topic}).

%%%===================================================================
%%% gen_server2 callbacks
%%%===================================================================

init([BaseDir]) ->
    % we are trapping exits here to monitor the appendix_servers
    process_flag(trap_exit, true),
    ets:new(poe_server_tracker, [bag, named_table, protected]),
    mkdir(BaseDir),
    mkdir(topics_dir(BaseDir)),
    start_from_dir(BaseDir),
    {ok, #state{base_dir = BaseDir, topics = []}}.

prioritise_info({'EXIT', _Pid, _Reason}, _State) ->
    1;

prioritise_info(_Msg, _State) ->
    0.

handle_call({read_pid, Topic, Timestamp}, _From, State) ->
    Pid = appendix_server:server(Timestamp, Topic),
    {reply, Pid, State};

handle_call({write_pid, Topic}, _From, State = #state{topics = Topics, base_dir = BaseDir}) ->
    {Pid, TopicsNew} =
    case appendix_server:server(timestamp(), Topic) of
        not_found ->
            {create_partition_internal(Topic, BaseDir), [Topic|Topics]};
        P ->
            {P, Topics}
    end,
    {reply, Pid, State#state{topics = TopicsNew}};

handle_call({create_partition, Topic}, _From, State = #state{topics = Topics, base_dir = BaseDir}) ->
    Pid = create_partition_internal(Topic, BaseDir),
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

handle_info({'EXIT', Pid, _Reason}, State) ->
    error_logger:info_msg("~p: ~p just died. Restarting...\n", [?MODULE, Pid]),
    [{_Pid, {Topic, Path}}] = ets:lookup(poe_server_tracker, Pid),
    ets:delete(poe_server_tracker, Pid),
    appendix_server:repair(Path),
    _PidNew = start_and_register_server(Topic, Path),
    {noreply, State};

handle_info(Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% utilities
%%%===================================================================

create_partition_internal(Topic, BaseDir) ->
    mkdir(BaseDir),
    mkdir(topics_dir(BaseDir)),
    TopicDir = topics_dir(BaseDir) ++ binary_to_list(Topic),
    mkdir(TopicDir),
    FileName = TopicDir ++ "/" ++ integer_to_list(timestamp()),
    start_and_register_server(Topic, FileName).

mkdir(Dir) ->
    case file:make_dir(Dir) of
        ok ->
            ok;
        {error, eexist} ->
            ok
    end.

topics_dir(BaseDir) ->
    BaseDir ++ "/" ++ "topics/".

start_and_register_server(Topic, Path) ->
    {ok, Pid} = poe_appendix_sup:start_child(Topic, Path),
    link(Pid),
    ets:insert(poe_server_tracker, {Pid, {Topic, Path}}),
    Pid.

start_from_dir(BaseDir) ->
    TopicsAndPaths = find_topics_and_paths(BaseDir),
    Register = fun(Topic, Path) ->
        start_and_register_server(Topic, Path),
        Topic
    end,   
    [Register(Topic, Path)||{Topic, Path}<-TopicsAndPaths].

find_topics_and_paths(BaseDir) ->
    TopicsDir = topics_dir(BaseDir),
    {ok, Topics} = file:list_dir(TopicsDir),
    TopicAndPathFromTopic = fun(Topic) ->
        {ok, Files} = file:list_dir(TopicsDir ++ Topic),
        TopicAndPath = fun(File, Acc) ->
            case binary:split(list_to_binary(File), <<"_">>) of
                [Time, <<"index">>] ->
                    [{list_to_binary(Topic), TopicsDir ++ Topic ++ "/" ++ binary_to_list(Time)}, Acc];
                _ ->
                    Acc
            end
        end,
        lists:foldl(TopicAndPath, [], Files)
    end,
    lists:flatten([TopicAndPathFromTopic(T)||T<-Topics]).

timestamp() ->
    {MegaSecs, Secs, MicroSecs} = now(),
    (MegaSecs * 1000000 + Secs) * 1000000 + MicroSecs.

maybe_create_new_partition(Topic, Servers) ->
    io:format("Servers:~p\n", [Servers]),
    ServerData = [Data||{Data, Pid}<-Servers, Pid =:= write_pid(Topic)],
    io:format("ServerData for ~p :~p\n", [Topic, ServerData]),
    true.

