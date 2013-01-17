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
	CONFIG=private/app.config erl -pz ebin deps/*/ebin

start:
	CONFIG=private/app.config erl -pz ebin deps/*/ebin -s poe

xref: compile
	rebar xref skip_deps=true

analyze: compile
	dialyzer ebin/*.beam deps/*/ebin/*.beam