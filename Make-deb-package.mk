# Excerpt for Makefile to build .deb file https://wiki.debian.org/Packaging
.PHONY: all deb package orig-tar prerelease release package-bin clean

NAME ?= helium-packet-router
SHORT_NAME ?= hpr
SNAKE_NAME := $(shell echo ${NAME} | sed 's/-/_/g')

# For late Decemeber git tag queried in early January, set $RELEASE in env.
CURRENT_YEAR ?= $(shell date +"%Y")
RELEASE_TAG ?= $(shell git tag -l ${CURRENT_YEAR}'*' | sort | tail -1)

# ${DEST} filepath will be created beneath ./release subdirectory.
DEST ?= /opt/${SHORT_NAME}
RUNTIME_USER ?= helium

# Optionally set PACKAGE_BUILD env var to next sequence number,
# which should be only necessary for new .deb on same RELEASE_TAG.
PACKAGE_BUILD ?= 1
REVISION := ${RELEASE_TAG}-${PACKAGE_BUILD}
DEBIAN_PACKAGE_NAME := ${NAME}
ORIG_SRC_TAR := ${NAME}_${RELEASE_TAG}.orig.tar.gz

# `rebar` is Erlang's build system.
REBAR_BUILD_DIR := _build/default/rel
REBAR_RELEASE_DIR := ${REBAR_BUILD_DIR}/${SNAKE_NAME}
REBAR_LAUNCH_SCRIPT := ${REBAR_RELEASE_DIR}/bin/${NAME}
REBAR_VERSIONED_SCRIPT := ${REBAR_RELEASE_DIR}/bin/${NAME}-${RELEASE_TAG}

DEB_ARCH := $(shell dpkg --print-architecture)

all: package

deb: package

package: prerelease orig-tar release package-bin

# Preliminary to the packaging workflow
orig-tar: ${ORIG_SRC_TAR}

${ORIG_SRC_TAR}:
	tar cfz "${ORIG_SRC_TAR}" $(shell git ls-files --exclude-standard)

# Confirm running on Debian-based Linux distro; e.g., Ubuntu.
# Replace relx -> 'release' version string in rebar.config before build.
prerelease:
	@[ -f /etc/debian_version ] || \
	  (echo "\n This requires a Debian-based Linux distro. \n"; false)
	@[ "${RELEASE_TAG}" ] || \
	  (echo "\n Please set RELEASE_TAG env var manually. \n"; false)
	@which rsync || \
	  (echo "\n rsync not installed or missing from PATH \n"; false)
	sed -i_ORIG \
	  's%.release, .${SHORT_NAME}, ".*"., .${SHORT_NAME}..,%{release, {${SHORT_NAME}, "${RELEASE_TAG}"}, [${SHORT_NAME}]},%' \
	  rebar.config

# TODO accommodate: `./rebar3 as ${BUILD_NET} release`
# with BUILD_NET=mainnet or testnet, etc.
# which generates _build/${BUILD_NET}/rel/${NAME}/
# See router's Dockerfile
# However, this affects value of ${REBAR_BUILD_DIR}
${REBAR_VERSIONED_SCRIPT}:
	$(MAKE) rel

release: | ${REBAR_VERSIONED_SCRIPT}
	@[ -f ${REBAR_VERSIONED_SCRIPT} ] || \
	  (echo "\n Please run: make rel \n"; false)
	rm -rf release
	mkdir -p release${DEST}/bin
	mkdir -p release${DEST}/var/log
	mkdir -p release${DEST}/var/run
	cp -p ${REBAR_VERSIONED_SCRIPT} release${DEST}/bin/${SHORT_NAME}.sh

package-bin:
	mkdir -p release/DEBIAN
	mkdir -p release/etc/default
	mkdir -p release/etc/init.d
	mkdir -p release/etc/systemd/system
	find release -type d | xargs chmod 0755

	cp priv/systemd/${SHORT_NAME}.service release/etc/systemd/system/
	cp priv/debian/etc/default/${NAME} release/etc/default/
	cp priv/debian/init.d/${SHORT_NAME} release/etc/init.d/

	sed 's/Version: 1.0-1/Version: ${REVISION}/' < priv/debian/deb-control.txt | sed 's/Architecture: all/Architecture: ${DEB_ARCH}/' > release/DEBIAN/control

	echo '#! /bin/sh' > release/DEBIAN/postinst
	echo 'useradd --system --user-group --shell /sbin/nologin ${RUNTIME_USER}' \
	  >> release/DEBIAN/postinst

	echo 'if [ "$$(ps --no-headers -o comm 1)" = "systemd" ]; then' \
	  >> release/DEBIAN/postinst
	echo '  systemctl daemon-reload' \
	  >> release/DEBIAN/postinst
	echo '  systemctl enable ${SHORT_NAME}.service' \
	  >> release/DEBIAN/postinst
	echo '  systemctl start ${SHORT_NAME}.service' \
	  >> release/DEBIAN/postinst
	echo '  systemctl is-active ${SHORT_NAME}.service' \
	  >> release/DEBIAN/postinst
	echo 'else' \
	  >> release/DEBIAN/postinst
	echo '  ln -s /etc/init.d/${NAME} /etc/rc3.d/S40${SHORT_NAME}' \
	  >> release/DEBIAN/postinst
	echo '  ln -s /etc/init.d/${NAME} /etc/rc1.d/K40${SHORT_NAME}' \
	  >> release/DEBIAN/postinst
	echo '  echo To manually start via init.d scripts, use:' \
	  >> release/DEBIAN/postinst
	echo '  echo sudo -u ${RUNTIME_USER} /etc/init.d/${NAME} start' \
	  >> release/DEBIAN/postinst
	echo 'fi' \
	  >> release/DEBIAN/postinst

	echo '#! /bin/sh' > release/DEBIAN/prerm
	echo 'if [ "$$(which systemctl)" ]; then' >> release/DEBIAN/prerm
	echo '  systemctl stop ${SHORT_NAME}.service' >> release/DEBIAN/prerm
	echo '  systemctl disable ${SHORT_NAME}.service' >> release/DEBIAN/prerm
	echo '  rm -f /etc/systemd/system/${SHORT_NAME}.service' \
	  >> release/DEBIAN/prerm
	echo '  systemctl daemon-reload' >> release/DEBIAN/prerm
	echo 'fi' >> release/DEBIAN/prerm
	echo '${DEST}/bin/${NAME}.sh stop || true' >> release/DEBIAN/prerm
	echo '${DEST}/bin/${NAME}.sh kill || true' >> release/DEBIAN/prerm
	echo '${DEST}/bin/${NAME}.sh clean-logs || true' >> release/DEBIAN/prerm
	echo 'rm -f ${DEST}/var/log/${NAME}.log*' >> release/DEBIAN/prerm
	echo 'rm -f /etc/init.d/${NAME}' >> release/DEBIAN/prerm
	echo 'rm -f /etc/rc?.d/*${SHORT_NAME}' >> release/DEBIAN/prerm
	echo 'userdel -r ${RUNTIME_USER}' >> release/DEBIAN/prerm

	chmod 0755 release/DEBIAN/postinst release/DEBIAN/prerm

	rsync -a --link-dest=$(shell pwd)/${REBAR_BUILD_DIR} \
	  ${REBAR_BUILD_DIR}/ release${DEST}/

	dpkg-deb --build release ${DEBIAN_PACKAGE_NAME}_${REVISION}_${DEB_ARCH}.deb
	ls -lh ${NAME}_*.deb

/etc/systemd/system/${SHORT_NAME}.service: priv/systemd/${SHORT_NAME}.service
	[ -d /etc/systemd/system/ ] || \
	  (echo "\n This requires Debian-based Linux with systemd. \n"; false)
	@echo "Invoking sudo to configure systemd"
	sudo cp ${SHORT_NAME}.service /etc/systemd/system/
	sudo systemctl daemon-reload
	sudo systemctl enable ${SHORT_NAME}.service
	sudo systemctl start ${SHORT_NAME}.service
	sudo systemctl is-active ${SHORT_NAME}.service

/usr/local/bin/${SHORT_NAME}: | $(REBAR_VERSIONED_SCRIPT)
	@echo "Invoking sudo to install an executable"
	sudo cp ${REBAR_VERSIONED_SCRIPT} /usr/local/bin/${SHORT_NAME}

clean:
	rm -rf release ${NAME}_*.deb
