# Poe, a kafkaesque server written in Erlang

The state of this library is experimental.

Poe is a queuing server inspired by Kafka (http://kafka.apache.org/).
Poe is also a  is based on appendix (https://github.com/odo/appendix).

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

## Tests:

```
make test
```
