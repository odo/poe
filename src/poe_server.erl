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

-record(state, {base_dir, topics}).

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

read_pid(Topic, Timestamp) ->
    appendix_server:server(Timestamp, Topic).

write_pid(Topic) ->
    case appendix_server:server(timestamp(), Topic) of
        not_found ->
            create_partition(Topic);
        Pid ->
            Pid
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([BaseDir]) ->
    file:make_dir(BaseDir),
    file:make_dir(topics_dir(BaseDir)),
    start_from_dir(BaseDir),
    {ok, #state{base_dir = BaseDir, topics = []}}.

handle_call({create_partition, Topic}, _From, State = #state{topics = Topics}) ->
    TopicsDir = topics_dir(State#state.base_dir),
    TopicDir = TopicsDir ++ binary_to_list(Topic),
    file:make_dir(TopicsDir),
    file:make_dir(TopicDir),
    Pid = start_and_register_server(Topic, TopicDir ++ "/" ++ integer_to_list(timestamp())),
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

start_and_register_server(Topic, Path) ->
    {ok, Pid} = poe_appendix_sup:start_child(Topic, Path),
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

