# Debian and Ubuntu family (SPEC 6.3). BASE_IMAGE is passed digest-pinned
# (<tag>@sha256:...) by docker-bake.hcl from tools/resolve_bases.sh; the
# default below only makes the file lint and build on its own.
ARG BASE_IMAGE=debian:13-slim
FROM ${BASE_IMAGE} AS build
ARG DEBIAN_FRONTEND=noninteractive

# Patch the pinned base, then the baseline of SPEC 6.2. Package versions are
# deliberately unpinned and the upgrade is deliberate: the build exists to
# apply upstream fixes on top of a base whose digest is recorded with the
# release (DL3008). Base quirks of SPEC 6.2: ubuntu:26.04 ships
# pebble, an unmanaged binary outside apt's reach, and the Ubuntu bases ship
# an ubuntu user at uid 1000; both are removed, and the final stage is this
# stage's tree alone, so deleting them here deletes them from the image.
# Stripping keeps every copyright file (redistribution needs it) and empties
# the machine id so systemd generates a fresh one on each first boot (6.3).
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends systemd systemd-sysv python3 python3-apt sudo ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /usr/share/man/* /usr/share/locale/* /var/log/* \
    && find /usr/share/doc \( -type f -o -type l \) ! -name copyright -delete \
    && find /usr/share/doc -mindepth 1 -depth -type d -empty -delete \
    && : > /etc/machine-id \
    && rm -f /var/lib/dbus/machine-id \
    && rm -f /usr/bin/pebble \
    && if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi

# Mask the units of SPEC 6.4 (container-hostile, then unattended maintenance)
# offline: systemd is not running at build time, and a /dev/null link is the
# offline form of `systemctl mask`. Without it a clean image boots degraded.
RUN for unit in \
        dev-hugepages.mount \
        sys-fs-fuse-connections.mount \
        systemd-logind.service \
        getty.target \
        console-getty.service \
        systemd-udevd.service \
        systemd-udev-trigger.service \
        systemd-modules-load.service \
        apt-daily.timer \
        apt-daily-upgrade.timer \
        dpkg-db-backup.timer \
        fstrim.timer \
    ; do ln -sf /dev/null "/etc/systemd/system/${unit}"; done

# One layer and nothing under it: the final stage starts from scratch, so the
# image is exactly the build stage's tree. Superseded package payloads and
# anything the build stage deleted never ship (the base layer is not kept).
# init image: PID 1 runs as root
FROM scratch
# The whole tree is the point: it flattens the patched filesystem into one layer.
# hadolint ignore=DL3067
COPY --from=build / /
# scratch carries no image config, so the environment is set explicitly.
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
LABEL org.opencontainers.image.description="Slim Debian or Ubuntu base image that boots systemd as PID 1" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="denyka"
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
