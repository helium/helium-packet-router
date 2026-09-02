.PHONY: compile clean test ct test-compile rel run grpc docker-build docker-test docker-run

grpc_services_directory=src/grpc/autogen

REBAR=./rebar3
TEST_COMPOSE=docker compose -f docker-compose-test.yaml
# Detached `up` streams nothing, so docker-test replays each check's output
# afterwards: everything for a failure, this many trailing lines for a pass
# (enough to show eunit's and ct's own result summary).
LOG_TAIL=12

# Two C dependencies do not build on current toolchains. Neither is about HPR's
# own code; both are build-environment workarounds for pinned deps, and both are
# needed on Linux as well as macOS -- gcc 14 (the Alpine image) and clang 16+
# made the same change.
#
#   * enacl: ERL_NIF_INIT is handed enacl_crypto_upgrade, whose signature does
#     not match the slot it lands in, and both compilers now make that an error.
#     Spelled "incompatible-pointer-types" because gcc does not recognise
#     clang's narrower "incompatible-function-pointer-types", and -Wno-error=
#     rather than -Wno- so the diagnostic still appears in the build log if it
#     ever spreads to another NIF.
#   * h3: c_src/CMakeLists.txt declares cmake_minimum_required(VERSION 3.3) and
#     CMake 4 dropped compatibility below 3.5. Only bites on CMake 4+ hosts; it
#     is an unused variable on the 3.31 the Alpine image ships, so it is set
#     unconditionally rather than probed for.
#
# Prepended/defaulted rather than assigned outright, so `make CFLAGS=...` or a
# value exported from the shell still wins.
CFLAGS := -Wno-error=incompatible-pointer-types $(CFLAGS)
CMAKE_POLICY_VERSION_MINIMUM ?= 3.5
export CFLAGS
export CMAKE_POLICY_VERSION_MINIMUM

# Use `make compile` initially for ensuring grpc auto-gen,
# but then use `rebar3 compile` directly for rapid iterations.
# Therefore, this target depends on $(grpc_services_directory),
# but rebar.config omits `grpc` in `pre_hooks`.
compile: | $(grpc_services_directory)
	$(REBAR) compile
	$(REBAR) format

clean:
	rm -rf src/grpc/autogen/
	rm -rf _build/

test: | $(grpc_services_directory)
	$(REBAR) fmt --verbose --check rebar.config
	$(REBAR) fmt --verbose --check "{src,include,test}/**/*.{hrl,erl,app.src}" --exclude-files "src/grpc/autogen/**/*"
	$(REBAR) fmt --verbose --check "config/{ct,sys,grpc_server_gen,grpc_client_gen}.{config,config.src}"
	$(REBAR) xref
	$(REBAR) dialyzer
	$(REBAR) release
	$(REBAR) eunit -v
	docker compose up -d --wait;
	$(REBAR) ct --readable=true
	docker compose down -v

# Reporter suites need rustfs; ct.config already points at localhost:9000.
test-aws:
	docker compose up -d --wait;
	$(REBAR) ct --readable=true --suite=hpr_packet_reporter_SUITE,hpr_gateway_liveness_reporter_SUITE;
	docker compose down -v


# Common Test on its own, assuming rustfs is already up. The `test` target
# above brings its own up and tears it down; this one is for callers that
# already provide it -- docker-compose-test.yaml, or a shell where you have run
# `docker compose up -d --wait` yourself. xref/eunit/dialyzer need no target of
# their own, the catch-all at the bottom forwards them to rebar3.
ct: | $(grpc_services_directory)
	$(REBAR) ct --readable=true $(if $(SUITE),--suite=$(SUITE))

# Compiles the test profile without running anything. Baked into the builder
# image so the per-suite containers start from an already-built test tree
# instead of each repeating the same compile.
test-compile: | $(grpc_services_directory)
	$(REBAR) as test compile

rel: | $(grpc_services_directory)
	$(REBAR) release

run: | $(grpc_services_directory)
	_build/default/rel/hpr/bin/hpr foreground

docker-build:
	docker build --force-rm -t quay.io/team-helium/hpr:local .

# Every check in its own container against a real rustfs; see
# docker-compose-test.yaml. The old recipe here ran `make test` inside the
# shipped image, which cannot work: the runner stage carries only the release,
# no source, no make.
#
# `docker compose up` on its own never returns, because rustfs is a fixture and
# does not exit -- so this waits on the checks instead, then tears down. The
# verdict is read from the exit codes because `docker compose wait` returns 0
# even when a container it waited on exited non-zero.
docker-test:
	-$(TEST_COMPOSE) up --build --detach
	@CHECKS=$$($(TEST_COMPOSE) config --services | grep -vE '^(rustfs|rustfs-init|results)$$' | sort); \
	$(TEST_COMPOSE) wait $$CHECKS > /dev/null 2>&1 || true; \
	FAILED=""; \
	for c in $$CHECKS; do \
	    code=$$($(TEST_COMPOSE) ps -a --format '{{.Service}} {{.ExitCode}}' | awk -v s=$$c '$$1==s {print $$2}'); \
	    [ -n "$$code" ] || code="did-not-run"; \
	    if [ "$$code" = "0" ]; then \
	        echo "===== $$c: passed (last $(LOG_TAIL) lines) ====="; \
	        $(TEST_COMPOSE) logs --no-log-prefix $$c 2>/dev/null | tail -n $(LOG_TAIL); \
	    else \
	        echo "===== $$c: FAILED ($$code) ====="; \
	        $(TEST_COMPOSE) logs --no-log-prefix $$c 2>/dev/null; \
	        FAILED="$$FAILED $$c"; \
	    fi; \
	done; \
	$(TEST_COMPOSE) down; \
	if [ -n "$$FAILED" ]; then echo "FAILED:$$FAILED"; exit 1; fi; \
	echo "All checks passed"

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
