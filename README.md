# Helium Packet Router

## [Routing](docs/routing.md)

## Releases
As releases are tagged on github, debian packages will be automatically built
and uploaded to a [repo here][1].

### Debian

The debian package installs the release in `/opt/hpr` - there is also a systemd
unit, so the service should be managed using the systemd tool `systemctl` like
any other systemd service.

#### Configuration

The default configuration is set upstream by the development team. But local
configuration parameters can be configured in `/opt/hpr/etc/local.conf`. This
file is loaded last by Erlang/OTP so any settings in that file will override
the default configuration.

The format of the configuration file is the standard Erlang [file:consult/1][2]
style like the other Erlang configuration formats.

This file is marked by the debian package system as a "config file" so it
will not get clobbered when upgraded debian packages are installed.

Other configuration parameters handled through environment variables can be
set or handled through the [environment facility in systemd unit files][3].

[1]: https://packagecloud.io/helium/packet_router
[2]: https://www.erlang.org/doc/man/file.html#consult-1
[3]: https://www.freedesktop.org/software/systemd/man/systemd.exec.html#Environment
