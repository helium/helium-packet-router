# Excerpt for Makefile to build .deb file https://wiki.debian.org/Packaging
.PHONY: all package orig-tar prerelease release package-bin clean

NAME ?= helium-packet-router
SHORT_NAME ?= hpr
SNAKE_NAME=$(shell echo ${NAME} | sed 's/-/_/g')

CURRENT_YEAR ?= $(shell date +"%Y")
RELEASE ?= $(shell git tag -l ${CURRENT_YEAR}'*' | sort | tail -1)

# ${DEST} filepath will be created beneath ./release subdirectory.
DEST ?= /opt/${SHORT_NAME}
RUNTIME_USER ?= helium

# Before upload to Debian repo, manually change date to next sequence number:
PACKAGE_BUILD=`date +%Y%m%d.%H%M%S`
REVISION=${RELEASE}-${PACKAGE_BUILD}
DEBIAN_PACKAGE_NAME=${NAME}
ORIG_SRC_TAR="${NAME}_${RELEASE}.orig.tar.gz"

# `rebar` is Erlang's build system.
REBAR_BUILD_DIR=_build/default/rel
REBAR_RELEASE_DIR=${REBAR_BUILD_DIR}/${SNAKE_NAME}
REBAR_LAUNCH_SCRIPT=${REBAR_RELEASE_DIR}/bin/${NAME}
REBAR_VERSIONED_SCRIPT=${REBAR_RELEASE_DIR}/bin/${NAME}-${RELEASE}

DEB_ARCH=$(shell dpkg --print-architecture)

all: package

package: orig-tar prerelease release package-bin

# Preliminary to the packaging workflow
orig-tar: ${ORIG_SRC_TAR}

${ORIG_SRC_TAR}:
	tar cfz ${ORIG_SRC_TAR} $(shell git ls-files --exclude-standard)

# Confirm running on Debian-based Linux distro; e.g., Ubuntu.
# Replace relx -> 'release' version string in rebar.config before build.
prerelease:
	@[ -f /etc/debian_version ] || \
	  (echo "This requires a Debian-based Linux distro."; false)
	sed -i_ORIG \
	  's%.release, .${SHORT_NAME}, ".*"., .${SHORT_NAME}..,%{release, {${SHORT_NAME}, "${RELEASE}"}, [${SHORT_NAME}]},%' \
	  rebar.config

# TODO accommodate: `./rebar3 as ${BUILD_NET} release`
# with BUILD_NET=mainnet or testnet, etc.
# which generates _build/${BUILD_NET}/rel/${NAME}/
# See router's Dockerfile
# However, this affects value of ${REBAR_BUILD_DIR}
${REBAR_VERSIONED_SCRIPT}:
	make rel

release: | ${REBAR_VERSIONED_SCRIPT}
	@[ -f ${REBAR_VERSIONED_SCRIPT} ] || (echo "Please run: make rel"; false)
	rm -rf release
	mkdir -p release${DEST}/bin
	mkdir -p release${DEST}/var/log
	mkdir -p release${DEST}/var/run
	cp -p ${REBAR_VERSIONED_SCRIPT} release${DEST}/bin/${NAME}.sh

# FIXME: also accommodate systemd
package-bin:
	mkdir -p release/DEBIAN
	find release -type d | xargs chmod 755

	sed "s/Version: 1.0-1/Version: ${REVISION}/" < priv/debian/deb-control.txt | sed "s/Architecture: all/Architecture: ${DEB_ARCH}/" > release/DEBIAN/control

	echo "#! /bin/sh" > release/DEBIAN/postinst
	echo 'useradd --system --user-group --shell /sbin/nologin ${RUNTIME_USER}' \
	  >> release/DEBIAN/postinst
	echo "ln -s ${DEST}/bin/${NAME}.sh /etc/init.d/" \
	  >> release/DEBIAN/postinst
	echo "ln -s ${DEST}/bin/${NAME}.sh /etc/rc3.d/S40${NAME}" \
	  >> release/DEBIAN/postinst
	echo "ln -s ${DEST}/bin/${NAME}.sh /etc/rc1.d/K40${NAME}" \
	  >> release/DEBIAN/postinst
	echo "echo To manually start, use:" >> release/DEBIAN/postinst
	echo "echo su - ${RUNTIME_USER} ${DEST}/bin/${NAME}.sh start" \
	  >> release/DEBIAN/postinst

	echo "#! /bin/sh" > release/DEBIAN/prerm
	echo "${DEST}/bin/${NAME}.sh stop" >> release/DEBIAN/prerm
	echo "${DEST}/bin/${NAME}.sh unkind-stop" >> release/DEBIAN/prerm
	echo "${DEST}/bin/${NAME}.sh clean-logs" >> release/DEBIAN/prerm
	echo "rm -f ${DEST}/var/log/${NAME}.log*" >> release/DEBIAN/prerm
	echo "rm -f /etc/init.d/${NAME}.sh" >> release/DEBIAN/prerm
	echo "rm -f /etc/rc?.d/*${NAME}" >> release/DEBIAN/prerm
	chmod 755 release/DEBIAN/p*

	rsync -a --link-dest=$(shell pwd)/${REBAR_BUILD_DIR} \
	  ${REBAR_BUILD_DIR}/ release${DEST}/

	dpkg-deb --build release
	mv release.deb ${DEBIAN_PACKAGE_NAME}_${REVISION}_${DEB_ARCH}.deb
	ls -lh ${NAME}_*.deb

clean:
	rm -rf release ${NAME}_*.deb
