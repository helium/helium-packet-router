.PHONY: compile clean test rel deb run docker-build docker-test docker-run

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

deb:
	$(MAKE) -f Make-deb-package.mk

run: |
	_build/default/rel/hpr/bin/hpr foreground

docker-build:
	docker build -f Dockerfile --force-rm -t quay.io/team-helium/hpr:local .

docker-test:
	docker run --rm -it --init --name=helium_router_test quay.io/team-helium/hpr:local make test

docker-run:
	docker run --rm -it --init --network=host --name=helium_packet_router quay.io/team-helium/hpr:local

# Pass all unknown targets straight to rebar3 (e.g. `make dialyzer`)
%:
	$(REBAR) $@
