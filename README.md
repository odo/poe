# Poe, a kafkaesque server written in Erlang

The state of this library is experimental.

Poe is a queuing server inspired by Kafka (http://kafka.apache.org/).
Poe is based on appendix (https://github.com/odo/appendix).
Poe manages sets of appendix servers and provides a socket interface.

It has the following characteristics:

* messages are binaries
* messages are identified by 56 bit integers ("pointers")
* messages are grouped by topics
* pretty high write rates
* very high read rates
* producers push messages onto the queue
* consumers pull messages from the queue
* two interfaces: Erlang & socket

## Installation

appendix requires rebar: https://github.com/basho/rebar

Building:
```
git clone git://github.com/odo/poe.git
cd poe/
rebar get-deps
make
```

## Usage
### Erlang

```erlang
plattfisch:poe odo$ rm -r /tmp/poe; make console
CONFIG=private/app.config erl -pz ebin deps/*/ebin
Erlang R16A (erts-5.10) [source] [smp:4:4] [async-threads:10] [hipe] [kernel-poll:false]

Eshell V5.10  (abort with ^G)
1> poe:start().

=INFO REPORT==== 15-Feb-2013::23:37:10 ===
Loading configuration from "private/app.config".

=INFO REPORT==== 15-Feb-2013::23:37:10 ===
starting with options: [{port,5555},
                        {check_interval,0.5},
                        {count_limit,100000},
                        {size_limit,67108864},
                        {buffer_count_max,100},
                        {worker_timeout,1},
                        {max_age,infinity}]
ok
2> P1 = poe:put(<<"the_topic">>, <<"hello">>).

=INFO REPORT==== 15-Feb-2013::23:37:10 ===
starting empty appendix server writing to "/tmp/poe/topics/the_topic/1360967830251960".
1360967830264661
3> P2 = poe:put(<<"the_topic">>, <<"world!">>).
1360967830265279
```

So when writing the first message to a topic, poe starts a new server to manage that topic.
When writing a message, poe returns a pointer which identifies that message and is also a timestamp in microseconds after unix epoch.

Messages are retrieved by iteration via next/2, starting with pointer 0:

```erlang
4> {P1, <<"hello">>} = poe:next(<<"the_topic">>, 0).
{1360967830264661,<<"hello">>}
5> {P2, <<"world!">>} = poe:next(<<"the_topic">>, P1).
{1360967830265279,<<"world!">>}
6> poe:next(<<"the_topic">>, P2).
not_found
7> poe:status().
[{<<"the_topic">>,[{<0.52.0>,w}]}]
```

poe:info/0 provides information about the appendix_server managed by poe.

Types are:

|symbol|type|meaning|
|---|---|---|
|w|writer|Active server with the most recent data. Writes to this topic are dispatched to this server.| 
|r|reader|Active server with older data accepting reads.|
|h|hybernating reader|A reader in an inactive state which needs to wake up before accepting reads.|

We can make poe start an additional server by exceeding count_limit (currently 100 000):

```erlang
8> [poe:put(<<"another_topic">>, <<"test">>)||N<-lists:seq(1, 100001)].

=INFO REPORT==== 15-Feb-2013::23:37:10 ===
starting empty appendix server writing to "/tmp/poe/topics/another_topic/1360967830273290".
[1360967830274163,1360967830274202,1360967830274232,
 1360967830274269,1360967830274301,1360967830274333,
 1360967830274361,1360967830274393,1360967830274424,
 1360967830274452,1360967830274484,1360967830274514,
 1360967830274550,1360967830274625,1360967830274692,
 1360967830274747,1360967830274800,1360967830274865,
 1360967830274914,1360967830274963,1360967830275014,
 1360967830275067,1360967830275118,1360967830275168,
 1360967830275219,1360967830275267,1360967830275330,
 1360967830275379,1360967830275429|...]
9> 
=INFO REPORT==== 15-Feb-2013::23:37:13 ===
starting new server for topic <<"another_topic">>

=INFO REPORT==== 15-Feb-2013::23:37:13 ===
starting empty appendix server writing to "/tmp/poe/topics/another_topic/1360967833719403".
```

So a second server has been startet for the topic <<"another_topic">> and after a few moments, the first one enters hibernation.

```erlang
=ERROR REPORT==== 15-Feb-2013::23:37:14 ===
syncing and sleeping.

=ERROR REPORT==== 15-Feb-2013::23:37:14 ===
appendix server <0.61.0> goes into hibernation ...
poe:status().
[{<<"another_topic">>,[{<0.61.0>,h},{<0.72.0>,w}]},
 {<<"the_topic">>,[{<0.52.0>,w}]}]
10> poe:print_status().
another_topic   :hw
the_topic       :w
[ok,ok]
11> 
```

# Configuration

Poe expects a few configuration parameters to be set.
There are three ways for the to be determined, ordered by descending priority:

* in the Options-argument of poe:start/1
* via a environment config file ("erl -config ...")
* as a hard coded default

## Parameters

|name|type|unit|default|meaning|
|---|---|---|---|---|
|dir|list or 'undefined'||undefined|the base directory where poe keeps its data|
|check_interval|number|seconds|0.5|The interval at which checks if the appendix_servers are "full"|
|count_limit|integer|number of messages|100000|the capacity of a single appendix_server before a new one is started. The actual number might be a littel higher, depending on check_interval|
|size_limit|integer|bytes|67108864 (64 MB)|the capacity of a single appendix_server before a new one is started. The actual number might be a littel higher, depending on check_interval|
|buffer_count_max|integer|number of messages|100|number of messages before the data is written to disk|
|worker_timeout|number|seconds|Time without a request until an appendix_server goes into hubernation|
|port|integer|port|5555|The port the socket server listens|
|max_age|number or 'infinity'|seconds|infinity|The age after which data is deleted|

# Memory consumption

The Erlang VM with an empty Poe server takes about 8MB of RAM.
When adding data, Poe starts appendix_server instances. An empty or hibernating one takes about 10KB.
As they "fill up", each message takes 12 Byte of RAM so 100 000 messages (the default capacity) takes about 1,14 MB.
When writing there is an buffer holding messages that are not written to disk yet (default size is 100). Those unwritten messages are also kept in RAM.

# Performance

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

```
make test
```

