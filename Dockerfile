FROM erlang:24.3-alpine AS builder

RUN apk add --no-cache --update \
    autoconf automake bison build-base bzip2 cmake curl \
    dbus-dev flex git gmp-dev libsodium-dev libtool linux-headers lz4 \
    openssl-dev pkgconfig protoc sed tar wget vim

# Install Rust toolchain
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /opt/hpr

# Build app depencies
COPY Makefile Makefile
COPY rebar3 rebar3
COPY rebar.config rebar.config
COPY rebar.lock rebar.lock
RUN ./rebar3 get-deps
RUN make compile

# Build app
COPY include/ include/
COPY src/ src/
RUN make compile

# Build release
COPY config/ config/
RUN make release

# Build stage 1
FROM erlang:24.3-alpine
WORKDIR /opt/hpr

# Copy the built release
COPY --from=builder /opt/hpr .
# Bring over exe like make
COPY --from=builder /usr/bin /usr/bin

CMD ["make", "run"]
