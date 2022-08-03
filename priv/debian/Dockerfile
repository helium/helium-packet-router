FROM amd64/debian:testing-slim

ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && apt-get install -y procps && rm -rf /var/lib/apt/lists/*

# See ../../Make-deb-package.mk for short name of .deb being a
# hard-link (ln) to ${DEBIAN_PACKAGE_NAME}_${REVISION}_${DEB_ARCH}.deb
COPY hpr.deb .

RUN dpkg -i hpr.deb
RUN dpkg --audit

WORKDIR /opt/hpr/hpr

CMD ["/opt/hpr/hpr/bin/hpr", "versions"]
