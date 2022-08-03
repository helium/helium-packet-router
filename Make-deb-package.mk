# Excerpt for Makefile to build .deb file https://wiki.debian.org/Packaging
.PHONY: all deb package orig-tar prerelease package-bin deb-test clean

NAME ?= helium-packet-router
SHORT_NAME ?= hpr
SNAKE_NAME := $(shell echo ${NAME} | sed 's/-/_/g')

# For late Decemeber git tag queried in early January, set $RELEASE in env.
CURRENT_YEAR ?= $(shell date +"%Y")
RELEASE_TAG ?= $(shell git tag -l ${CURRENT_YEAR}'*' | sort | tail -1)

# ${DEST} filepath will be created beneath ./release subdirectory.
DEST ?= /opt/${SHORT_NAME}
RUNTIME_USER ?= helium
WORKDIR ?= ${DEST}/${SHORT_NAME}

# Optionally set PACKAGE_BUILD env var to next sequence number,
# which should be only necessary for new .deb on same RELEASE_TAG.
PACKAGE_BUILD ?= 1
REVISION := ${RELEASE_TAG}-${PACKAGE_BUILD}
DEBIAN_PACKAGE_NAME := ${NAME}
ORIG_SRC_TAR := ${NAME}_${RELEASE_TAG}.orig.tar.xz

# `rebar` is Erlang's build system.
REBAR_BUILD_DIR := _build/default/rel
REBAR_RELEASE_DIR := ${REBAR_BUILD_DIR}/${SNAKE_NAME}
REBAR_LAUNCH_SCRIPT := ${REBAR_RELEASE_DIR}/bin/${NAME}
REBAR_VERSIONED_SCRIPT := ${REBAR_RELEASE_DIR}/bin/${NAME}-${RELEASE_TAG}

DEB_ARCH := $(shell dpkg --print-architecture)

TAR_FILES := $(shell git ls-files --exclude-standard)

all: package

deb: package

package: prerelease orig-tar package-bin

${DEBIAN_PACKAGE_NAME}_${REVISION}_${DEB_ARCH}.deb: package

# Preliminary to the packaging workflow
orig-tar: ${ORIG_SRC_TAR}

${ORIG_SRC_TAR}: | ${TAR_FILES}
	tar cfJ "${ORIG_SRC_TAR}" ${TAR_FILES}

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

	@[ -f ${REBAR_VERSIONED_SCRIPT} ] || \
	  (echo "\n Please run: make rel \n"; false)

package-bin:
	rm -rf _release
	mkdir -p _release${DEST}/var/log
	mkdir -p _release${DEST}/var/run
	mkdir -p _release/DEBIAN
	mkdir -p _release/etc/default
	mkdir -p _release/etc/init.d
	mkdir -p _release/etc/systemd/system
	find _release -type d | xargs chmod 0755

	@[ "${DEST}" ] || \
	  (cp ${REBAR_LAUNCH_SCRIPT} _release/bin/ && \
	   find _release/bin -type f | xargs chmod 0755)

	cp priv/debian/etc/default/${NAME} _release/etc/default/
	cp priv/debian/etc/init.d/${SHORT_NAME} _release/etc/init.d/
	find _release/etc/init.d -type f | xargs chmod 0755

	sed 's%^ExecStart\s*=\s*%ExecStart=${WORKDIR}%; s%^WorkingDirectory\s*=\s*.*$$%WorkingDirectory=${WORKDIR}%' \
	  < priv/debian/etc/systemd/system/${SHORT_NAME}.service \
	  > _release/etc/systemd/system/${SHORT_NAME}.service

	sed \
	  's%Version: 1.0-1%Version: ${REVISION}%; s%Architecture: all%Architecture: ${DEB_ARCH}%' \
	  < priv/debian/deb-control.txt \
	  > _release/DEBIAN/control

	echo '#! /bin/sh' > _release/DEBIAN/postinst
	echo 'useradd --system --user-group --shell /sbin/nologin ${RUNTIME_USER}' \
	  >> _release/DEBIAN/postinst

	echo 'if [ "$$(ps --no-headers -o comm 1)" = "systemd" ]; then' \
	  >> _release/DEBIAN/postinst
	echo '  systemctl daemon-reload' \
	  >> _release/DEBIAN/postinst
	echo '  systemctl enable ${SHORT_NAME}.service' \
	  >> _release/DEBIAN/postinst
	echo '  systemctl start ${SHORT_NAME}.service' \
	  >> _release/DEBIAN/postinst
	echo '  systemctl is-active ${SHORT_NAME}.service' \
	  >> _release/DEBIAN/postinst
	echo 'else' \
	  >> _release/DEBIAN/postinst
	echo '  ln -s /etc/init.d/${NAME} /etc/rc3.d/S40${SHORT_NAME}' \
	  >> _release/DEBIAN/postinst
	echo '  ln -s /etc/init.d/${NAME} /etc/rc1.d/K40${SHORT_NAME}' \
	  >> _release/DEBIAN/postinst
	echo '  echo To manually start via init.d scripts, use:' \
	  >> _release/DEBIAN/postinst
	echo '  echo sudo -u ${RUNTIME_USER} /etc/init.d/${NAME} start' \
	  >> _release/DEBIAN/postinst
	echo 'fi' \
	  >> _release/DEBIAN/postinst

	echo '#! /bin/sh' > _release/DEBIAN/prerm
	echo 'if [ "$$(ps --no-headers -o comm 1)" = "systemd" ]; then' \
	   >> _release/DEBIAN/prerm
	echo '  systemctl stop ${SHORT_NAME}.service' >> _release/DEBIAN/prerm
	echo '  systemctl disable ${SHORT_NAME}.service' >> _release/DEBIAN/prerm
	echo '  rm -f /etc/systemd/system/${SHORT_NAME}.service' \
	  >> _release/DEBIAN/prerm
	echo '  systemctl daemon-reload' >> _release/DEBIAN/prerm
	echo 'else' >> _release/DEBIAN/prerm
	echo '  /etc/init.d/${NAME} stop || true' >> _release/DEBIAN/prerm
	echo '  /etc/init.d/${NAME} kill || true' >> _release/DEBIAN/prerm
	echo '  /etc/init.d/${NAME} clean-logs || true' >> _release/DEBIAN/prerm
	echo 'fi' >> _release/DEBIAN/prerm
	echo 'rm -f ${DEST}/var/log/${NAME}.log*' >> _release/DEBIAN/prerm
	echo 'rm -f /etc/init.d/${NAME}' >> _release/DEBIAN/prerm
	echo 'rm -f /etc/rc?.d/*${SHORT_NAME}' >> _release/DEBIAN/prerm
	echo 'userdel -r ${RUNTIME_USER}' >> _release/DEBIAN/prerm

	chmod 0755 _release/DEBIAN/postinst _release/DEBIAN/prerm

	rsync -a --link-dest=$(shell pwd)/${REBAR_BUILD_DIR} \
	  ${REBAR_BUILD_DIR}/ _release${DEST}/

	dpkg-deb --build \
	  _release "${DEBIAN_PACKAGE_NAME}_${REVISION}_${DEB_ARCH}.deb"
	ls -lh ${DEBIAN_PACKAGE_NAME}_*.deb

# TODO container used for extrating .deb into a pristine image.
# For actual run, provide to running container: --env-file=.env
deb-test:
	@[ -f "${DEBIAN_PACKAGE_NAME}_${REVISION}_${DEB_ARCH}.deb" ] || \
	  (echo "\n Please run: make deb \n"; false)
	@[ -d _build/deb_test/ ] || mkdir -p _build/deb_test
	@ln -f "${DEBIAN_PACKAGE_NAME}_${REVISION}_${DEB_ARCH}.deb" \
	    _build/deb_test/${SHORT_NAME}.deb
	docker build -f priv/debian/Dockerfile --force-rm \
	  -t ${SHORT_NAME}_deb_test _build/deb_test/
	@rm -f _build/deb_test/${SHORT_NAME}.deb
	docker run --rm -it \
	  --init --network=host \
	  --name=${SHORT_NAME}_deb_test \
	  ${SHORT_NAME}_deb_test
	@echo '${SHORT_NAME} successfully installed from .deb'

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
	rm -rf _release ${NAME}_*.deb
