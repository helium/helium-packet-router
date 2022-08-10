FROM erlang:24.3-alpine AS builder

RUN apk add --no-cache --update \
    autoconf automake bison build-base bzip2 cmake curl \
    dbus-dev flex git gmp-dev libsodium-dev libtool linux-headers lz4 \
    openssl-dev pkgconfig protoc sed tar wget vim

# Alpine Linux uses MUSL libc instead of the more common GNU libc
# (glibc). MUSL is generally meant for static linking, and rustc
# follows that convention. However, rustc cannot compile crates into
# dylibs when statically linking to MUSL. Rust NIFs are .so's
# (dylibs), therefore we force the compiler to dynamically link to
# MUSL by telling it to not statically link (the minus sign before
# crt-static means negate the following option).
ENV CARGO_BUILD_RUSTFLAGS="-C target-feature=-crt-static"

# Install Rust toolchain
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /opt/hpr

# Build app depencies
COPY Makefile Makefile
COPY rebar3 rebar3
COPY rebar.config rebar.config
COPY rebar.lock rebar.lock
COPY config/ config/
RUN ./rebar3 get-deps
RUN make compile

# Build app
COPY include/ include/
COPY src/ src/
RUN make compile

# Build release
RUN make release

CMD ["make", "run"]

FROM builder AS tester

COPY --from=builder /opt/hpr .
# Bring over exe like make
COPY --from=builder /usr/bin /usr/bin

# Add tests
COPY test/ test/
RUN ./rebar3 compile as test

CMD ["make", "run"]

FROM builder AS runner
WORKDIR /opt/hpr

# Copy the built release
COPY --from=builder /opt/hpr .
# Bring over exe like make
COPY --from=builder /usr/bin /usr/bin

CMD ["make", "run"]
