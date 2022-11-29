#!/usr/bin/env bash

set -euo pipefail

cd $GITHUB_WORKSPACE

git config --global --add safe.directory "$GITHUB_WORKSPACE"

if [ -z "$GITHUB_REF" ]; then
    VERSION=$(git describe)
else
    VERSION=$(echo "$GITHUB_REF" | sed 's|refs/tags/||')
fi

export CARGO_BUILD_RUSTFLAGS="-C target-feature=-crt-static"
./rebar3 get-deps
make grpc
./rebar3 release -n "hpr" -v "${VERSION}"

if [ ! -d /opt/hpr/etc ]; then
    mkdir -p /opt/hpr/etc
fi

if [ ! -f /opt/hpr/etc/local.conf ]; then
    touch /opt/hpr/etc/local.conf
fi

fpm -n "packet-router" \
    -v "${VERSION}" \
    -s dir \
    -t deb \
    --depends libssl1.1 \
    --depends libsodium23 \
    --depends libncurses5 \
    --depends dbus \
    --depends libstdc++6 \
    --deb-systemd deb/hpr.service \
    --before-install deb/before_install.sh \
    --after-install deb/after_install.sh \
    --after-remove deb/after_remove.sh \
    --before-upgrade deb/before_upgrade.sh \
    --after-upgrade deb/after_upgrade.sh \
    --deb-no-default-config-files \
    --deb-systemd-enable \
    --deb-systemd-auto-start \
    --deb-systemd-restart-after-upgrade \
    --deb-user helium \
    --deb-group helium \
    --config-files "/opt/hpr/etc/local.conf" \
    _build/default/rel/=/opt

