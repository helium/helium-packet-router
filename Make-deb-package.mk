# Excerpt for Makefile to build .deb file https://wiki.debian.org/Packaging
.PHONY: all deb package orig-tar prerelease package-bin clean
.PHONY: docker-test vm-test vm-ssh vm-relx

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
REBAR_RELEASE_DIR := ${REBAR_BUILD_DIR}/${SHORT_NAME}
REBAR_LAUNCH_SCRIPT := ${REBAR_RELEASE_DIR}/bin/${SHORT_NAME}
REBAR_VERSIONED_SCRIPT := ${REBAR_RELEASE_DIR}/bin/${SHORT_NAME}-${RELEASE_TAG}

DEB_ARCH := $(shell dpkg --print-architecture)
DEB_FILE := ${DEBIAN_PACKAGE_NAME}_${REVISION}_${DEB_ARCH}.deb

TAR_FILES := $(shell git ls-files --exclude-standard)

all: package

deb: package

package: prerelease orig-tar package-bin

${DEB_FILE}: package

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

	[ -f ${REBAR_VERSIONED_SCRIPT} ] || \
	  (echo "\n Please run, or run again: make rel \n"; false)

# TODO both GENESIS_PATH and EXTRA_PATHS are required only for the
# back-port to router.
package-bin:
	rm -rf _release
	[ -z "${DEST}" ] || mkdir -p _release${DEST}/log
	mkdir -p _release/DEBIAN
	mkdir -p _release/etc/default
	mkdir -p _release/etc/init.d
	mkdir -p _release/etc/systemd/system
	find _release -type d | xargs chmod 0755

	[ "${DEST}" ] || \
	  (mkdir _release/usr/bin/ && \
	   cp ${REBAR_LAUNCH_SCRIPT} _release/usr/bin/ && \
	   find _release/usr/bin -type f | xargs chmod 0755)

	[ -z "${GENESIS_PATH}" ] || \
	  (mkdir _release${DEST}/priv && \
	   cp ${GENESIS_PATH} _release${DEST}/priv/genesis)
	[ -z "${EXTRA_PATHS}" ] || \
	  rsync -a ${EXTRA_PATHS} _release${DEST}/

	cp priv/debian/etc/default/${NAME} _release/etc/default/
	cp priv/debian/etc/init.d/${SHORT_NAME} _release/etc/init.d/
	find _release/etc/init.d -type f | xargs chmod 0755

	sed 's%^\(Exec\S*\)\s*=\s*%\1=${WORKDIR}%; s%^\(WorkingDirectory\)\s*=\s*.*$$%\1=${WORKDIR}%' \
	  < priv/debian/etc/systemd/system/${SHORT_NAME}.service \
	  > _release/etc/systemd/system/${SHORT_NAME}.service

	sed \
	  's%Version: 1.0-1%Version: ${REVISION}%; s%Architecture: all%Architecture: ${DEB_ARCH}%' \
	  < priv/debian/deb-control.txt \
	  > _release/DEBIAN/control

	echo '#! /bin/sh' > _release/DEBIAN/postinst
	echo 'set -e' >> _release/DEBIAN/postinst
	echo 'set -x' >> _release/DEBIAN/postinst
	echo 'useradd --system --user-group --shell /sbin/nologin ${RUNTIME_USER}' \
	  >> _release/DEBIAN/postinst
	[ -z "${DEST}" ] || \
	  echo 'chown -R ${RUNTIME_USER}:${RUNTIME_USER} ${DEST}' \
	    >> _release/DEBIAN/postinst
	[ "${DEST}" ] || \
	  echo 'chown -R ${RUNTIME_USER}:${RUNTIME_USER} ${WORKDIR}' \
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
	echo 'set -e' >> _release/DEBIAN/prerm
	echo 'set -x' >> _release/DEBIAN/prerm
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
	echo '[ -f ${DEST}/log/${NAME}.log ] && rm -f ${DEST}/log/${NAME}.log*' \
	  >> _release/DEBIAN/prerm
	echo 'rm -f /etc/init.d/${NAME}' >> _release/DEBIAN/prerm
	echo 'rm -f /etc/rc?.d/*${SHORT_NAME}' >> _release/DEBIAN/prerm
	echo 'userdel -r ${RUNTIME_USER}' >> _release/DEBIAN/prerm

	chmod 0755 _release/DEBIAN/postinst _release/DEBIAN/prerm

	rsync -a --link-dest=$(shell pwd)/${REBAR_BUILD_DIR} \
	  ${REBAR_BUILD_DIR}/ _release${DEST}/

	dpkg-deb --build _release "${DEB_FILE}"
	ls -lh ${DEBIAN_PACKAGE_NAME}_*.deb

# When debugging this test, *manually* install .deb from `vagrant ssh`
# and then run: `${WORKDIR}/bin/${SHORT_NAME} console_clean`
# to confirm that a minimal viable Erlang shell runs.
vm-test:
	@[ "${RELEASE_TAG}" ] || \
	  (echo "\n Please set RELEASE_TAG env var manually. \n"; false)
	[ -f "${DEB_FILE}" ] || \
	  (echo "\n please run: make deb \n" ; false)
	[ "$(shell which vagrant)" ] || \
	  (echo "\n Requires vagrant:" ; \
	   echo " https://www.VagrantUP.com/downloads \n" ; \
	   false)
	[ "$(shell which virtualbox)" ] || \
	  (echo "\n Vagrant needs a provider:" ; \
	   echo " https://www.virtualbox.org/wiki/Linux_Downloads \n" ; \
	   false)
	[ -d _release/vm/ ] || mkdir _release/vm
	cp -p priv/debian/Vagrantfile _release/vm/
	[ -f _release/vm/${SHORT_NAME}.deb ] || \
	  ln "${DEB_FILE}" _release/vm/${SHORT_NAME}.deb
	(cd _release/vm/ && vagrant up)
	@echo "Sleeping for VM to catch-up..."
	sleep 2
	(cd _release/vm/ && vagrant ssh -c 'sudo dpkg -i /vagrant/${SHORT_NAME}.deb')
	(cd _release/vm/ && vagrant ssh -c 'sudo dpkg --audit')
	(cd _release/vm/ && vagrant ssh -c 'sudo dpkg --status helium-router' | \
	                    grep -c "Status: install ok installed")
	(cd _release/vm/ && vagrant ssh -c 'sudo systemctl start ${SHORT_NAME}')
	(cd _release/vm/ && \
	 vagrant ssh -c 'sudo systemctl status ${SHORT_NAME} --no-pager --full')
	(cd _release/vm/ && vagrant ssh -c '${WORKDIR}/bin/${SHORT_NAME} status')
	(cd _release/vm/ && vagrant halt)
	@echo '${SHORT_NAME} successfully installed and ran from .deb'

# For debugging systemd & init.d startup configs generated from .deb
vm-ssh:
	[ -d _release/vm/ ] || \
	  (echo "\n Please run: make vm-test \n"; false)
	@echo "\n Try: sudo journalctl -u ${SHORT_NAME}.service \n"
	(cd _release/vm/ && vagrant ssh)

# Confirm bits generated by `relx` are runnable without involving .deb;
# e.g., `make compile rel` and then invoke this target.
vm-relx:
	@[ "${RELEASE_TAG}" ] || \
	  (echo "\n Please set RELEASE_TAG env var manually. \n"; false)
	[ -d ${REBAR_BUILD_DIR} ] || \
	  (echo "\n Please run: make rel \n"; false)
	sed 's%^\s*apt[- ].*$$%%; s%"${SHORT_NAME}_deb"%"${SHORT_NAME}_relx"%' \
	  < priv/debian/Vagrantfile \
	  > ${REBAR_BUILD_DIR}/Vagrantfile
	(cd ${REBAR_BUILD_DIR} && vagrant up)

	@echo "\n See subdirectories under /vagrant \n"
	(cd ${REBAR_BUILD_DIR} && vagrant ssh)

	(cd ${REBAR_BUILD_DIR} && vagrant destroy --force)
	rm ${REBAR_BUILD_DIR}/Vagrantfile

# Container used only for extracting .deb into a pristine image.
# Unsuitable for deployment, would require: --env-file=.env
docker-test:
	[ -f "${DEB_FILE}" ] || \
	  (echo "\n Please run: make deb \n"; false)
	[ -d _build/deb_test/ ] || mkdir _build/deb_test
	ln -f "${DEB_FILE}" _build/deb_test/${SHORT_NAME}.deb
	docker build -f priv/debian/Dockerfile --force-rm \
	  -t ${SHORT_NAME}_deb_test _build/deb_test/
	rm -f _build/deb_test/${SHORT_NAME}.deb
	docker run --rm -it \
	  --init --network=host \
	  --name=${SHORT_NAME}_deb_test \
	  ${SHORT_NAME}_deb_test
	@echo '${SHORT_NAME} successfully installed from .deb'

clean:
	[ -z "$(wildcard ${NAME}_*.deb)" ] || rm -rf ${NAME}_*.deb
	rm -f "${ORIG_SRC_TAR}"
	(cd _release/vm/ && vagrant destroy --force) || true
	(cd ${REBAR_BUILD_DIR} && vagrant destroy --force > /dev/null 2>&1) || true
	rm -f ${REBAR_BUILD_DIR}/Vagrantfile
	rm -rf _release
