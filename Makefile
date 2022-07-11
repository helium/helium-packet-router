.PHONY: compile clean test rel run

REBAR=./rebar3

compile: |
	$(REBAR) compile 
	$(REBAR) format

clean:
	git clean -dXfffffffffff

test: |
	$(REBAR) fmt --verbose --check rebar.config
	$(REBAR) fmt --verbose --check "{src,include,test}/**/*.{hrl,erl,app.src}" --exclude-files "src/grpc/autogen/**/*"
	$(REBAR) fmt --verbose --check "config/{test,sys}.{config,config.src}"
	$(REBAR) xref
	$(REBAR) eunit
	$(REBAR) ct --readable=true
	$(REBAR) dialyzer

rel: $(REBAR) release

run: |
	_build/default/rel/hpr/bin/hpr foreground

# Pass all unknown targets straight to rebar3 (e.g. `make dialyzer`)
%:
	$(REBAR) $@
