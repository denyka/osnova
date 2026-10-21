# Images

The matrix is `matrix.yml`: name, family and base tag, no digest
([SPEC 6.1](../SPEC.md)). Every image is a multi-architecture index
(`linux/amd64`, `linux/arm64`).

## Matrix

| Image | Family | Base tag | Package manager | Pull |
| --- | --- | --- | --- | --- |
| `almalinux9` | `el` | `almalinux:9-minimal` | microdnf | `docker pull ghcr.io/denyka/osnova/almalinux9:latest` |
| `almalinux10` | `el` | `almalinux:10-minimal` | microdnf | `docker pull ghcr.io/denyka/osnova/almalinux10:latest` |
| `debian12` | `deb` | `debian:12-slim` | apt | `docker pull ghcr.io/denyka/osnova/debian12:latest` |
| `debian13` | `deb` | `debian:13-slim` | apt | `docker pull ghcr.io/denyka/osnova/debian13:latest` |
| `ubuntu2404` | `deb` | `ubuntu:24.04` | apt | `docker pull ghcr.io/denyka/osnova/ubuntu2404:latest` |
| `ubuntu2604` | `deb` | `ubuntu:26.04` | apt | `docker pull ghcr.io/denyka/osnova/ubuntu2604:latest` |

The matrix carries two majors per distribution. Adding one retires the
oldest ([add a distro](../how_to/add_a_distro.md)).

## Baseline

| Package | `el` | `deb` | Purpose |
| --- | --- | --- | --- |
| systemd | yes | yes | PID 1 |
| systemd-sysv | no | yes | the `/sbin/init` link |
| python3 | yes | yes | interpreter for configuration tooling |
| `python3-dnf` or `python3-apt` | `python3-dnf` | `python3-apt` | the tooling's package modules |
| sudo | yes | yes | privilege escalation for tooling that calls it |
| ca-certificates | yes | yes | TLS validation |

Nothing else: no editors, no users, no SSH.

`curl` differs by family. EL10 has no separate `curl-minimal` package: its
`curl` package provides `curl-minimal`, is built on `libcurl-minimal` and
is required by `rpm`. `el9` ships `curl-minimal`. Neither family ships the
full-protocol libcurl, and the `deb` images ship no `curl`. The smoke
suite asserts exactly that.

Two quirks of the Ubuntu bases are undone by the `deb` Dockerfile:
`ubuntu:26.04` ships `pebble`, an unmanaged binary outside apt's reach,
which is removed; and the Ubuntu bases ship an `ubuntu` user at uid 1000,
which is removed, because a test container is where tooling creates its own
users and uid 1000 is the one they take. The smoke suite asserts neither is
present.

## One layer

Each image is one layer. The build stage upgrades the base, installs the
baseline and strips:

- package caches and logs
- documentation, except every `copyright` file under `/usr/share/doc`,
  which redistribution requires
- manuals
- locale catalogues

The final stage is `FROM scratch` with the build stage's whole tree copied
in, so no base layer sits underneath, superseded package payloads never ship
and every delete in the build stage is a delete in the image. Build-time
settings such as `DEBIAN_FRONTEND` are `ARG`s of the build stage, never an
`ENV`. [SPEC 6.3](../SPEC.md) states this form.

## Shadow mode on `el`

The `el` images set `/etc/shadow` to mode 0600; the base ships 0000. pam_unix
reads the file through the setuid helper `unix_chkpwd`, and a host whose
AppArmor confines that helper by path, as Ubuntu 24.04 does, denies it the
capability a 0000 file needs, so `sudo` fails even for root, in a privileged
container too. The file stays root-only; the `deb` family's `0640 root:shadow`
needs no change ([SPEC 6.3](../SPEC.md)).

## Machine id

`/etc/machine-id` is empty and `/var/lib/dbus/machine-id` is removed, so
systemd generates a fresh id on every first boot. Two containers of one
image never share an id; the smoke suite asserts a 32-hex id and that two
containers differ.

## Masked units

Twelve units, masked in every image by linking to `/dev/null`, identical
across families ([SPEC 6.4](../SPEC.md)). A mask for a unit a family does
not ship is a dangling link systemd ignores.

Hardware and kernel interfaces a container does not have, masked so a clean
image boots `running` rather than `degraded`:

| Unit |
| --- |
| `dev-hugepages.mount` |
| `sys-fs-fuse-connections.mount` |
| `systemd-logind.service` |
| `getty.target` |
| `console-getty.service` |
| `systemd-udevd.service` |
| `systemd-udev-trigger.service` |
| `systemd-modules-load.service` |

Unattended maintenance a test container must not start on its own (a
background `apt-get update` races the tooling under test over the dpkg
lock):

| Unit |
| --- |
| `apt-daily.timer` |
| `apt-daily-upgrade.timer` |
| `dpkg-db-backup.timer` |
| `fstrim.timer` |

## Labels

| Label | Comes from | Value |
| --- | --- | --- |
| `org.opencontainers.image.title` | `docker-bake.hcl` | the image name |
| `org.opencontainers.image.description` | Dockerfile | family description |
| `org.opencontainers.image.licenses` | Dockerfile | `MIT` |
| `org.opencontainers.image.vendor` | Dockerfile | `denyka` |
| `org.opencontainers.image.source` | `docker-bake.hcl` | `https://github.com/denyka/osnova` |
| `org.opencontainers.image.url` | `docker-bake.hcl` | the image's package page |
| `org.opencontainers.image.revision` | pipeline (`REVISION`) | the commit built |
| `org.opencontainers.image.created` | pipeline (`CREATED`) | RFC 3339 UTC |
| `org.opencontainers.image.version` | pipeline (`VERSION`) | the dated tag |
| `org.opencontainers.image.base.name` | `docker-bake.hcl` | the base tag |
| `org.opencontainers.image.base.digest` | `docker-bake.hcl` | the resolved base digest |

A local `make build` sets `revision` to the current commit and `version`
to `dev`.

## Environment

The final `ENV` is exactly
`PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` and
`HOME=/root`, set explicitly because `scratch` carries no configuration;
nothing else is in the environment. `STOPSIGNAL SIGRTMIN+3`, which systemd
reads as a request to halt, so `docker stop` shuts it down cleanly.
`CMD ["/sbin/init"]`. No `USER`: an init image runs as root.
