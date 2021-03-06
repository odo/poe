%% @doc: server managing instances of appendix_server
%% and dispatching read and write requests.

-module(poe_server).
-author('Florian Odronitz <odo@mac.com>').
-behaviour(gen_server2).

%% API
-export([start_link/1, stop/1]).
-export([
    maybe_create_new_partitions/0
    , maybe_destroy_partitions/0
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

%% Profiling
-export([
    eprofile_writer/1, eprofile_writer/2
    , fprofile_writer/2, fprofile_reader/2
    ]).

-ifdef(TEST).
-export([crash_appendix_server/1, create_partition/1]).
-endif.

-define(SERVER, ?MODULE).
-record(state, {base_dir, topics, options}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(BaseDir) ->
    gen_server2:start_link({local, ?SERVER}, ?MODULE, [BaseDir], []).

stop(Pid) ->
    gen_server2:call(Pid, stop).

-spec topics() -> [poe:topic()].
topics() ->
    gen_server2:call(?SERVER, {topics}).

-spec maybe_create_new_partitions() -> [pid()].
maybe_create_new_partitions() ->
    gen_server2:call(?SERVER, {maybe_create_new_partitions}).

-spec maybe_destroy_partitions() -> ok.
maybe_destroy_partitions() ->
    gen_server2:call(?SERVER, {maybe_destroy_partitions}).

-spec read_pid(poe:topic(), poe:pointer()) -> pid() | not_found.
read_pid(Topic, Timestamp) ->
    gen_server2:call(?SERVER, {read_pid, Topic, Timestamp}).

-spec write_pid(poe:topic()) -> pid().
write_pid(Topic) ->
    gen_server2:call(?SERVER, {write_pid, Topic}).

%%%===================================================================
%%% gen_server2 callbacks
%%%===================================================================

init([BaseDir]) ->
    % we are trapping exits here to monitor the appendix_servers
    process_flag(trap_exit, true),
    ets:new(poe_server_tracker, [bag, named_table, protected]),
    ets:new(poe_server_dir, [ordered_set, named_table, protected]),
    mkdir(BaseDir),
    mkdir(topics_dir(BaseDir)),
    Options = options(),
    error_logger:info_msg("starting with options: ~p\n", [Options]),
    Topics = lists:usort(start_from_dir(BaseDir, Options)),
    timer:apply_interval(round(option(check_interval, Options) * 1000), poe_server, maybe_create_new_partitions, []),
    case option(max_age, Options) of
        infinity ->
            noop;
        MaxAge ->
            timer:apply_interval(round(min(MaxAge / 10.0, 600) * 1000), poe_server, maybe_destroy_partitions, [])
    end,
    {ok, #state{base_dir = BaseDir, topics = Topics, options = Options}}.

prioritise_info({'EXIT', _Pid, _Reason}, _State) ->
    1;

prioritise_info(_Msg, _State) ->
    0.

handle_call({read_pid, Topic, Timestamp}, _From, State) ->
    {reply, read_pid_internal(Topic, Timestamp), State};

handle_call({write_pid, Topic}, _From, State = #state{topics = Topics, base_dir = BaseDir, options = Options}) ->
    {Pid, TopicsNew} =
    case write_pid_internal(Topic) of
        not_found ->
            {create_partition_internal(Topic, BaseDir, Options), lists:usort([Topic|Topics])};
        P ->
            {P, Topics}
    end,
    {reply, Pid, State#state{topics = TopicsNew}};

handle_call({create_partition, Topic}, _From, State = #state{topics = Topics, base_dir = BaseDir, options = Options}) ->
    Pid = create_partition_internal(Topic, BaseDir, Options),
    {reply, Pid, State#state{topics = lists:usort([Topic|Topics])}};
 
handle_call({maybe_create_new_partitions}, _From, State = #state{topics = Topics, base_dir = BaseDir, options = Options}) ->
    WritePidsAndTopics = [{write_pid_internal(T), T}||T<-Topics],
    MaybeCreteNewPartition = fun(WriterPid, Topic) ->
        Info = appendix_server:info(WriterPid),
        case proplists:get_value(count, Info) >= option(count_limit, Options) orelse proplists:get_value(size, Info) >= option(size_limit, Options) of
            true ->
                error_logger:info_msg("starting new server for topic ~p\n", [Topic]),
                WriterPidNew = create_partition_internal(Topic, BaseDir, Options),
                appendix_server:sync(WriterPid),
                WriterPidNew;
            false ->
                noop
        end
    end,
    PidsNewAndNoop = lists:foldl(fun({P, T}, Acc) -> [MaybeCreteNewPartition(P, T)|Acc] end, [], WritePidsAndTopics),
    PidsNew = [PNAN||PNAN<-PidsNewAndNoop, is_pid(PNAN)],
    {reply, PidsNew, State};

handle_call({maybe_destroy_partitions}, _From, State = #state{topics = Topics, options = Options}) ->
    MaxAge = option(max_age, Options),
    lists:map(
        fun(Topic) ->
            WritePid = write_pid_internal(Topic),        
            ReadPids = [Pid||[{{T, _TS}, Pid}]<-ets:match(poe_server_dir, '$1'), T =:= Topic, Pid =/= WritePid],
            [maybe_destroy_partition(Pid, MaxAge)||Pid<-ReadPids]
        end,
        Topics
    ),
    {reply, ok, State};

handle_call({topics}, _From, State = #state{topics = Topics}) ->
    {reply, lists:usort(Topics), State};

handle_call({crash_appendix_server, Pid}, _From, State) ->
    try
        appendix_server:sync_and_crash(Pid)
    catch
        exit:_ -> noop
    end,
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State = #state{options = Options}) when Reason =/= normal ->
    error_logger:info_msg("~p: appendix_server ~p just died with reason ~p. Restarting...\n", [?MODULE, Pid, Reason]),
    [{Pid, {Topic, Path, _}}] = ets:lookup(poe_server_tracker, Pid),
    unregister_server(Pid),
    appendix_server:repair(Path),
    _PidNew = start_and_register_server(Topic, Path, Options),
    {noreply, State};

handle_info(Msg, State) ->
    error_logger:info_msg("~p got message: ~p\n", [?MODULE, Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% server registration and lookup
%%%===================================================================

start_and_register_server(Topic, Path, Options) ->
    reregister_writer(Topic),
    {ok, Pid} = poe_appendix_sup:start_child(Topic, Path, option(buffer_count_max, Options), round(option(worker_timeout, Options) * 1000)),
    register_server(Pid, Topic, Path),
    Pid.

register_server(Pid, Topic, Path) ->
    link(Pid),
    Info = appendix_server:info(Pid),
    DirInfo = {proplists:get_value(id, Info), proplists:get_value(pointer_high, Info)},
    ets:insert(poe_server_tracker, {Pid, {Topic, Path, DirInfo}}),
    ets:insert(poe_server_dir, {DirInfo, Pid}).

unregister_server(Pid) ->
    [{Pid, {_, _, DirInfo}}] = ets:lookup(poe_server_tracker, Pid),
    ets:delete(poe_server_tracker, Pid),
    ets:delete(poe_server_dir, DirInfo).

reregister_server(Pid) ->
    [{Pid, {Topic, Path, _}}] = ets:lookup(poe_server_tracker, Pid),
    unregister_server(Pid),
    register_server(Pid, Topic, Path).

% we have to update the current write server so it
% can receive reads
reregister_writer(Topic) ->
    case write_pid_internal(Topic) of
        Pid when is_pid(Pid) ->
            reregister_server(Pid);
        _ ->
            noop
    end.

read_pid_internal(Topic, Timestamp) ->
    case ets:next(poe_server_dir, {Topic, Timestamp}) of
        Key = {Topic, _} ->
            [{_, Pid}] = ets:lookup(poe_server_dir, Key), 
            Pid;
        _ ->
            write_pid_internal(Topic)
    end.

write_pid_internal(Topic) ->
    case ets:prev(poe_server_dir, {Topic, <<>>}) of
        Key = {Topic, _} ->
            [{_, Pid}] = ets:lookup(poe_server_dir, Key), 
            Pid;
        _ ->
            not_found
    end.

maybe_destroy_partition(Pid, MaxAge) ->
    {MegaSecs,Secs,MicroSecs} = now(),
    Now = (MegaSecs*1000000 + Secs)*1000000 + MicroSecs,
    case proplists:get_value(pointer_high, appendix_server:info(Pid)) of
        P when P < Now - (MaxAge * 1000000)  ->
            unregister_server(Pid),
            appendix_server:destroy(Pid);
        _ ->
            noop
    end.

%%%===================================================================
%%% utilities
%%%===================================================================


options() ->
    Keys = [port, check_interval, count_limit, size_limit, buffer_count_max, worker_timeout, max_age],
    Env = application:get_all_env(poe),
    [{K, proplists:get_value(K, Env)}||K<-Keys].

option(Key, Options) ->
    proplists:get_value(Key, Options).

create_partition_internal(Topic, BaseDir, Options) ->
    mkdir(BaseDir),
    mkdir(topics_dir(BaseDir)),
    TopicDir = topics_dir(BaseDir) ++ binary_to_list(Topic),
    mkdir(TopicDir),
    FileName = TopicDir ++ "/" ++ integer_to_list(timestamp()),
    start_and_register_server(Topic, FileName, Options).

mkdir(Dir) ->
    case file:make_dir(Dir) of
        ok ->
            ok;
        {error, eexist} ->
            ok
    end.

topics_dir(BaseDir) ->
    BaseDir ++ "/" ++ "topics/".

start_from_dir(BaseDir, Options) ->
    TopicsAndPaths = find_topics_and_paths(BaseDir),
    Register = fun(Topic, Path) ->
        start_and_register_server(Topic, Path, Options),
        Topic
    end,   
    [Register(Topic, Path)||{Topic, Path}<-TopicsAndPaths],
    [Topic||{Topic, _Path}<-TopicsAndPaths].

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

%% ===================================================================
%% Profiling
%% ===================================================================

eprofile_writer(Topic) ->
    eprofile_writer(Topic, 10).

eprofile_writer(Topic, Duration) ->
    eprof:start(),
    eprof:start_profiling([poe_server:write_pid(Topic)]),
    error_logger:info_msg("Profiling writer for topic ~p for ~p s.\n", [Topic, Duration]),
    timer:sleep(Duration * 1000),
    eprof:stop_profiling(),
    eprof:analyze().

fprofile_writer(Topic, Calls) ->
    Seq = lists:seq(1, Calls),
    File = "/tmp/poe_server_profile",
    os:cmd("rm " ++ File),
    fprof:trace([start, {procs, [poe_server:write_pid(Topic)]},{file, File}]),
    [poe:put(Topic, <<"this is some little bit of data...">>)||_<-Seq],
    fprof:profile({file, File}),
    fprof:analyse().

fprofile_reader(Topic, Calls) ->
    Seq = lists:seq(1, Calls),
    File = "/tmp/poe_server_profile",
    os:cmd("rm " ++ File),
    Server = poe_server:read_pid(Topic, 0),
    fprof:trace([start, {procs, [Server]},{file, File}]),
    [appendix_server:file_pointer_lax(Server, 0, 1000001)||_<-Seq],
    fprof:profile({file, File}),
    fprof:analyse().

%% ===================================================================
%% Tests
%% ===================================================================

-ifdef(TEST).

create_partition(Topic) ->
    gen_server2:call(?SERVER, {create_partition, Topic}).

crash_appendix_server(Pid) ->
    gen_server2:call(?SERVER, {crash_appendix_server, Pid}).

-endif.
