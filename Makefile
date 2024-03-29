.PHONY: compile clean test rel run grpc docker-build docker-test docker-run

grpc_services_directory=src/grpc/autogen

REBAR=./rebar3

# Use `make compile` initially for ensuring grpc auto-gen,
# but then use `rebar3 compile` directly for rapid iterations.
# Therefore, this target depends on $(grpc_services_directory),
# but rebar.config omits `grpc` in `pre_hooks`.
compile: | $(grpc_services_directory)
	$(REBAR) compile
	$(REBAR) format

clean:
	git clean -dXfffffffffff

test: | $(grpc_services_directory)
	$(REBAR) fmt --verbose --check rebar.config
	$(REBAR) fmt --verbose --check "{src,include,test}/**/*.{hrl,erl,app.src}" --exclude-files "src/grpc/autogen/**/*"
	$(REBAR) fmt --verbose --check "config/{ct,sys,grpc_server_gen,grpc_client_gen}.{config,config.src}"
	$(REBAR) xref
	$(REBAR) dialyzer
	$(REBAR) release
	$(REBAR) eunit -v
	$(REBAR) ct --readable=true

test-aws:
	docker compose -f docker-compose-ct.yaml up -d;
	HPR_PACKET_REPORTER_LOCAL_HOST=localhost $(REBAR) ct --readable=true --suite=hpr_packet_reporter_SUITE;
	docker compose -f docker-compose-ct.yaml down


rel: | $(grpc_services_directory)
	$(REBAR) release

run: | $(grpc_services_directory)
	_build/default/rel/hpr/bin/hpr foreground

docker-build:
	docker build --force-rm -t quay.io/team-helium/hpr:local .

docker-test:
	docker run --rm -it --init --name=helium_packet_router_test quay.io/team-helium/hpr:local make test

docker-run:
	docker run --rm -it --init --name=helium_packet_router quay.io/team-helium/hpr:local

grpc:
	REBAR_CONFIG="config/grpc_gen.config" $(REBAR) grpc gen

$(grpc_services_directory): config/grpc_gen.config
	@echo "grpc service directory $(directory) does not exist, generating services"
	$(REBAR) get-deps
	$(MAKE) grpc

# Pass all unknown targets straight to rebar3 (e.g. `make dialyzer`)
%:
	$(REBAR) $@
