all: deps compile

compile:
	rebar compile ski_deps=true

deps:
	rebar get-deps

clean:
	rebar clean

test:
	rebar skip_deps=true eunit

console:
	erl -config private/app -pz ebin deps/*/ebin

start:
	erl -config private/app -pz ebin deps/*/ebin -s poe

xref: compile
	rebar xref skip_deps=true

check: compile
	dialyzer -Wno_undefined_callbacks ebin/*.beam deps/*/ebin/*.beam