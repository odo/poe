# Poe, a kafkaesque server written in Erlang

Poe is a queuing server inspired by Kafka (http://kafka.apache.org/).
Poe is based on appendix (https://github.com/odo/appendix).
Poe manages sets of appendix servers and provides a socket interface.

The state of this software is experimental.

It has the following characteristics:

* messages are binaries
* messages are identified by 56 bit integers ("pointers")
* messages are grouped by topics
* producers push messages onto the queue
* consumers pull messages from the queue
* pretty high write rates
* very high read rates
* uses file:sendfile/5
* two interfaces: Erlang & socket

## Installation

poe requires rebar: https://github.com/basho/rebar

Building:
```
git clone git://github.com/odo/poe.git
cd poe/
rebar get-deps
make
```

## Usage
### Erlang interface

```erlang
plattfisch:poe odo$ make console
erl -config private/app -pz ebin deps/*/ebin
Erlang R16A (erts-5.10) [source] [smp:4:4] [async-threads:10] [hipe] [kernel-poll:false]

Eshell V5.10  (abort with ^G)
1> poe:start().

=INFO REPORT==== 16-Feb-2013::20:38:21 ===
starting with options: [{port,5555},
                        {check_interval,0.5},
                        {count_limit,100000},
                        {size_limit,67108864},
                        {buffer_count_max,100},
                        {worker_timeout,1},
                        {max_age,infinity}]
ok
2> P1 = poe:put(<<"the_topic">>, <<"hello">>).

=INFO REPORT==== 16-Feb-2013::20:38:24 ===
starting empty appendix server writing to "/tmp/poe/topics/the_topic/1361043504873813".
1361043504888939
3> P2 = poe:put(<<"the_topic">>, <<"world!">>).
1361043508064575
```

So when writing the first message to a topic, poe starts a new server to manage that topic.
When writing a message, poe returns a pointer which identifies that message and is also a timestamp in microseconds after unix epoch.

Messages are retrieved by iteration via next/2, starting with pointer 0:

```erlang
4> {P1, <<"hello">>} = poe:next(<<"the_topic">>, 0).
{1361043504888939,<<"hello">>}
5> {P2, <<"world!">>} = poe:next(<<"the_topic">>, P1).
{1361043508064575,<<"world!">>}
6> poe:next(<<"the_topic">>, P2).
not_found
7> poe:status().
[{<<"the_topic">>,[{<0.79.0>,w}]}]
```

poe:info/0 provides information about the appendix_server managed by poe.

Types are:

|symbol|type|meaning|
|---|---|---|
|w|writer|Active server with the most recent data. Writes to the topic are dispatched to this server.| 
|r|reader|Active server with older data accepting reads.|
|h|hibernating reader|A reader in an inactive state which needs to wake up before accepting reads.|

We can make poe start an additional server by exceeding count_limit (currently 100 000):

```erlang
8> [poe:put(<<"another_topic">>, <<"test">>)||N<-lists:seq(1, 100001)].

=INFO REPORT==== 16-Feb-2013::20:40:54 ===
starting empty appendix server writing to "/tmp/poe/topics/another_topic/1361043654923317".
[1361043654924292,1361043654924338,1361043654924372,
 1361043654924419,1361043654924458,1361043654924492,
 1361043654924529,1361043654924566,1361043654924599,
 1361043654924629,1361043654924667,1361043654924703,
 1361043654924737,1361043654924775,1361043654924819,
 1361043654924852,1361043654924883,1361043654924931,
 1361043654924963,1361043654924993,1361043654925035,
 1361043654925068,1361043654925099,1361043654925131,
 1361043654925175,1361043654925205,1361043654925237,
 1361043654925275,1361043654925308|...]
9> 
=INFO REPORT==== 16-Feb-2013::20:40:58 ===
starting new server for topic <<"another_topic">>

=INFO REPORT==== 16-Feb-2013::20:40:58 ===
starting empty appendix server writing to "/tmp/poe/topics/another_topic/1361043658314914".
```

So a second server has been startet for the topic <<"another_topic">> and after a few moments, the first one enters hibernation.

```erlang
=ERROR REPORT==== 16-Feb-2013::20:40:59 ===
syncing and sleeping.

=ERROR REPORT==== 16-Feb-2013::20:40:59 ===
appendix server <0.388.0> goes into hibernation ...
poe:status().
[{<<"another_topic">>,[{<0.388.0>,h},{<0.399.0>,w}]},
 {<<"the_topic">>,[{<0.79.0>,w}]}]
10> poe:print_status().
another_topic   :hw
the_topic       :w
ok
```

We need to quit the shell (in contrast to killing it with ctrl-c) so Poe can write data to disk and remove locks.

```erlang
11> q().
ok
12> 
=ERROR REPORT==== 16-Feb-2013::20:41:07 ===
received: {'EXIT',<0.68.0>,shutdown}

=ERROR REPORT==== 16-Feb-2013::20:41:07 ===
received: {'EXIT',<0.68.0>,shutdown}

=INFO REPORT==== 16-Feb-2013::20:41:07 ===
unlocking "/tmp/poe/topics/the_topic/1361043504873813"

=INFO REPORT==== 16-Feb-2013::20:41:07 ===
unlocking "/tmp/poe/topics/another_topic/1361043658314914"

=ERROR REPORT==== 16-Feb-2013::20:41:07 ===
received: {'EXIT',<0.68.0>,shutdown}

=INFO REPORT==== 16-Feb-2013::20:41:07 ===
unlocking "/tmp/poe/topics/another_topic/1361043654923317"
```

### Socket interface

Given Poe is running on port 5555:

```erlang
1> Socket = poe_protocol:socket("127.0.0.1", 5555).
#Port<0.828>
2> poe_protocol:write(<<"my_shiny_topic">>, [<<"msg1">>, <<"msg2">>, <<"msg3">>], Socket).
1361045443917303
3> poe_protocol:write(<<"my_shiny_topic">>, [<<"msg4">>, <<"msg5">>], Socket).
1361045443918321
4> poe_protocol:read(<<"my_shiny_topic">>, 0, 2, Socket).
[{1361045443917231,<<"msg1">>},
 {1361045443917270,<<"msg2">>}]
5> poe_protocol:read(<<"my_shiny_topic">>, 1361045443917270, 10, Socket).
[{1361045443917303,<<"msg3">>},
 {1361045443918295,<<"msg4">>},
 {1361045443918321,<<"msg5">>}]
6> poe_protocol:read(<<"my_shiny_topic">>, 1361045443918321, 10, Socket).
[]
```

# Configuration

Poe expects a few configuration parameters to be set.
There are three ways for them to be determined, ordered by descending priority:

* in the Options-argument of poe:start/1
* via poes application environment (e.g. "erl -config ...")
* as a hard coded default

## Parameters

|name|type|unit|default|meaning|
|---|---|---|---|---|
|dir|list or 'undefined'||undefined|the base directory where poe keeps its data|
|check_interval|number|seconds|0.5|the interval at which checks are done whether the appendix_servers have reached their capacity|
|count_limit|integer|number of messages|100000|the capacity of a single appendix_server before a new one is started. The actual number might be a littel higher, depending on check_interval|
|size_limit|integer|bytes|67108864 (64 MB)|the capacity of a single appendix_server before a new one is started. The actual number might be a littel higher, depending on check_interval|
|buffer_count_max|integer|number of messages|100|number of messages before the data is written to disk|
|worker_timeout|number|seconds|1|time without a request until an appendix_server goes into hibernation|
|port|integer|port|5555|the port the socket server listens|
|max_age|number or 'infinity'|seconds|infinity|the age after which data is deleted|

# Memory consumption

The Erlang VM with an empty Poe server takes about 8MB of RAM.
When adding data, Poe starts appendix_server instances. An empty or hibernating one takes about 10 KB.
As they "fill up", each message takes 12 Byte of RAM so 100 000 messages (the default capacity) take about 1,14 MB.
When writing there is an buffer holding messages that are not written to disk yet (default size is 100). Those unwritten messages are also kept in RAM.

# Benchmarks

## Setup

Performance was tested using basho_bench (https://github.com/basho/basho_bench/).
Reads and writes were done via the socket interface with 100 messages in each call, each message 100 bytes long. Basho bench was also run on the system under test so the parsing of received messages also consumed CPU time.

Poe configuration:

```erlang
[{port,5555},
{check_interval,0.5},
{count_limit,100000},
{size_limit,67108864},
{buffer_count_max,100},
{worker_timeout,1},
{max_age,infinity}]
```

The tests where performed on two different types of hardware:

|Name|CPU Type|Locical Cores|CPU Freq|RAM|Disk|Erlang|OS|
|---|---|---|---|---|---|---|---|
|desktop|Intel Pentium|2|2.0 GHz|3 GB|HD, Seagate Barracuda 7200.10 ST3160815AS|R15B01|Ubuntu 11.10|
|server|Intel Core i7|12|3.2 GHz|40 GB|SSD, OCZ-VERTEX3|R15B03|Ubuntu 12.04.1 LTS|

## Results

|hardware|cuncurrent test processes|topics|type|calls/s|messages/s|
|---|---|---|---|---|---|---|
|desktop|6|1|write|400|40 000|
|desktop|6|1|read|4000|400 000|
|desktop|6|1|alternating write/read|600| 60 000|
|desktop|6|100|write|400|40 000|
|desktop|6|100|read|4000|400 000|
|desktop|6|100|alternating write/read|700|70 000
|server|20|1|write|600|60 000|
|server|20|1|read|33 000|3 300 000|
|server|20|1|alternating write/read|1 200|120 000|
|server|20|100|write|500|50 000|
|server|20|100|read|35 000|3 500 000|
|server|20|100|alternating write/read|1 200|120 000|

## Tests:

eunit and proper:
```
make test
```
dialyzer:
```
make check
```

