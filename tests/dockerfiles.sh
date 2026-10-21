#!/usr/bin/env bash
# The build contract of SPEC 6.3 line by line, the masked set of 6.4 identical
# in both families, the static labels of 6.5, nothing forbidden.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
cd "${T_ROOT}" || exit 1

masked="dev-hugepages.mount sys-fs-fuse-connections.mount systemd-logind.service getty.target console-getty.service systemd-udevd.service systemd-udev-trigger.service systemd-modules-load.service apt-daily.timer apt-daily-upgrade.timer dpkg-db-backup.timer fstrim.timer"
final_env="ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root"
for family in el deb; do
    f="images/${family}/Dockerfile"
    t_assert_file "${f}"
    t_assert_grep '^ARG BASE_IMAGE=[a-z]+:[a-z0-9.-]+$' "${f}"
    t_assert_grep '^FROM \$\{BASE_IMAGE\} AS build$' "${f}"
    # the final stage is the build stage's tree alone: no base layer under it
    t_assert_grep '^FROM scratch$' "${f}"
    t_assert_not_grep '^FROM \$\{BASE_IMAGE\}$' "${f}"
    t_assert_eq 2 "$(grep -cE '^FROM ' "${f}")" "${f}: two stages"
    t_assert_eq "FROM scratch" "$(grep -E '^FROM ' "${f}" | tail -1)" "${f}: the last stage is scratch"
    # the init-image statement stands directly above the final stage (HQ SPEC 14, SPEC 6.3)
    t_assert_eq "# init image: PID 1 runs as root" "$(grep -B1 -E '^FROM scratch$' "${f}" | head -1)" "${f}: the init statement above FROM scratch"
    t_assert_grep '^COPY --from=build / /$' "${f}"
    # scratch carries no config: PATH and HOME are explicit
    t_assert_eq "${final_env}" "$(grep -E '^ENV ' "${f}")" "${f}: the one ENV line is exactly PATH and HOME"
    t_assert_eq 0 "$(sed '/^FROM scratch$/,$d' "${f}" | grep -cE '^ENV ')" "${f}: no ENV in the build stage"
    # after the scratch copy only ENV, LABEL, STOPSIGNAL and CMD may follow
    after="$(sed -n '/^COPY --from=build \/ \/$/,$p' "${f}" | sed 1d | grep -E '^[A-Z]+ ' | cut -d' ' -f1 | sort -u | paste -sd' ' -)"
    t_assert_eq "CMD ENV LABEL STOPSIGNAL" "${after}" "${f}: only ENV, LABEL, STOPSIGNAL, CMD follow the copy"
    # stripping: caches, documentation (copyright kept), manuals, locale, logs
    t_assert_grep '^    && rm -rf .*/usr/share/man' "${f}"
    t_assert_grep '^    && rm -rf .*/usr/share/locale/\*' "${f}"
    t_assert_grep '^    && rm -rf .*/var/log/\*' "${f}"
    t_assert_grep "find /usr/share/doc .*! -name copyright -delete" "${f}"
    t_assert_grep 'find /usr/share/doc -mindepth 1 -depth -type d -empty -delete' "${f}"
    t_assert_not_grep 'rm -rf .*/usr/share/doc' "${f}"
    # a fresh machine id on every first boot
    t_assert_grep '^    && : > /etc/machine-id \\$' "${f}"
    t_assert_grep '^    && rm -f /var/lib/dbus/machine-id' "${f}"
    t_assert_eq 0 "$(sed -n '/^FROM scratch$/,$p' "${f}" | grep -c '^RUN ')" "${f}: nothing runs after the copy (one layer)"
    t_assert_grep '^STOPSIGNAL SIGRTMIN\+3$' "${f}"
    t_assert_grep '^CMD \["/sbin/init"\]$' "${f}"
    t_assert_grep 'org\.opencontainers\.image\.licenses="MIT"' "${f}"
    t_assert_grep 'org\.opencontainers\.image\.vendor="denyka"' "${f}"
    t_assert_grep 'org\.opencontainers\.image\.description=' "${f}"
    t_assert_not_grep '^USER ' "${f}"
    t_assert_not_grep 'pam\.d|sudoers' "${f}"
    t_assert_not_grep 'curl .*\| *(ba)?sh|wget ' "${f}"
    t_assert_not_grep '(install|-y)[^#]*[[:space:]]curl([[:space:]]|\\|$)' "${f}"
    t_assert_not_grep '^# syntax=' "${f}"
    t_assert_not_grep 'ENV .*(TOKEN|SECRET|PASSWORD)' "${f}"
    t_assert_grep 'ln -sf /dev/null' "${f}"
    for u in ${masked}; do t_assert_grep "^[[:space:]]+${u//./\\.} \\\\$" "${f}"; done
    # every hadolint ignore carries its reason on the line above
    while IFS= read -r ln; do
        prev="$(sed -n "$((ln - 1))p" "${f}")"
        if [[ "${prev}" =~ ^#\ .+ && ! "${prev}" =~ hadolint ]]; then t_ok "${f}:${ln}: ignore has a reason"; else t_fail "${f}:${ln}: hadolint ignore without a reason comment above it"; fi
    done < <(grep -nE '^# hadolint ignore=' "${f}" | cut -d: -f1)
done
t_assert_grep 'microdnf upgrade -y' images/el/Dockerfile
# the one shadow change of SPEC 6.3: el only, mode 0600, nothing else under /etc/shadow
t_assert_grep '^    && chmod 0600 /etc/shadow$' images/el/Dockerfile
t_assert_eq 1 "$(grep -c '^[^#].*/etc/shadow' images/el/Dockerfile | tr -d ' ')" "el: /etc/shadow is touched once"
t_assert_not_grep '/etc/shadow' images/deb/Dockerfile
t_assert_grep 'rm -rf /var/cache/dnf /var/cache/yum' images/el/Dockerfile
t_assert_grep 'microdnf install -y systemd python3 python3-dnf sudo ca-certificates \\$' images/el/Dockerfile
t_assert_grep 'apt-get upgrade -y' images/deb/Dockerfile
t_assert_grep 'apt-get install -y --no-install-recommends systemd systemd-sysv python3 python3-apt sudo ca-certificates \\$' images/deb/Dockerfile
t_assert_grep 'rm -f /usr/bin/pebble' images/deb/Dockerfile
t_assert_grep 'rm -rf /var/lib/apt/lists/\* /var/cache/apt/\*' images/deb/Dockerfile
t_assert_grep '^ARG DEBIAN_FRONTEND=noninteractive$' images/deb/Dockerfile
t_assert_not_grep 'DEBIAN_FRONTEND' images/el/Dockerfile
t_assert_grep 'if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi' images/deb/Dockerfile
# the masked list is byte-identical in both files
el="$(sed -n '/for unit in/,/done/p' images/el/Dockerfile)"; deb="$(sed -n '/for unit in/,/done/p' images/deb/Dockerfile)"
t_assert_eq "${el}" "${deb}" "masked-unit loop identical in both families"
for family in el deb; do
    listed="$(sed -n '/for unit in/,/done/p' "images/${family}/Dockerfile" | grep -oE '[a-z0-9_-]+\.(mount|service|target|timer)' | paste -sd' ' -)"
    t_assert_eq "${masked}" "${listed}" "images/${family}: the masked set is SPEC 6.4's twelve units, in order, and nothing beyond"
done
# bake: labels from the base variable, the pipeline variables, no platform pin
t_assert_grep '^variable "REGISTRY"' docker-bake.hcl
t_assert_grep 'default = "ghcr.io/denyka/osnova"' docker-bake.hcl
for v in TAG PLATFORMS REVISION CREATED VERSION; do t_assert_grep "^variable \"${v}\"" docker-bake.hcl; done
t_assert_grep 'org.opencontainers.image.base.digest' docker-bake.hcl
t_assert_grep 'org.opencontainers.image.source" *= *"https://github.com/denyka/osnova"' docker-bake.hcl
t_assert_not_grep 'linux/(amd64|arm64)' docker-bake.hcl
t_finish
