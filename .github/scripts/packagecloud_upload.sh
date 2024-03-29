#!/usr/bin/env bash

set -euo pipefail

cd $GITHUB_WORKSPACE

for deb in *.deb
do
    curl -u "${PACKAGECLOUD_API_KEY}:" \
         -F "package[distro_version_id]=210" \
         -F "package[package_file]=@$deb" \
         https://packagecloud.io/api/v1/repos/helium/packet_router/packages.json
done
