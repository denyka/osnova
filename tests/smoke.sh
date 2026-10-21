#!/usr/bin/env bash
# The run contract (SPEC 7.4): the image boots to `running` under the
# documented contract and under the compatibility form; python3 and sudo
# work as root; the family package manager installs a service systemd then
# runs; PID 1 is systemd; the machine id is fresh and differs per container;
# no pebble, full curl or ubuntu user. The same list is asserted under both
# contracts. Skipped only when OSNOVA_SMOKE_IMAGE is unset, so a checkout
# without Docker keeps a green gate (SPEC 11); an image named while Docker
# does not answer fails. Also boots under Podman when it is present.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

image="${OSNOVA_SMOKE_IMAGE:-}"
if [[ -z "${image}" ]]; then
    t_ok "skipped: OSNOVA_SMOKE_IMAGE is unset (make smoke IMAGE=<ref> runs it)"
    t_finish
    exit $?
fi
if ! docker info >/dev/null 2>&1; then
    t_fail "Docker does not answer but OSNOVA_SMOKE_IMAGE names ${image}"
    t_finish
    exit $?
fi
# one line on the host, so a failure can be read against the engine that produced it
docker info --format 'host: docker {{.ServerVersion}}, kernel {{.KernelVersion}}, cgroup v{{.CgroupVersion}} ({{.CgroupDriver}}), storage {{.Driver}}, security {{.SecurityOptions}}' >&2 || true

containers=()
podman_containers=()
machine_ids=()
errdir="$(mktemp -d)"
cleanup() {
    local c
    for c in "${containers[@]:-}"; do
        [[ -n "${c}" ]] && docker rm -f "${c}" >/dev/null 2>&1
    done
    for c in "${podman_containers[@]:-}"; do
        [[ -n "${c}" ]] && podman rm -f "${c}" >/dev/null 2>&1
    done
    rm -rf "${errdir}"
    return 0
}
# Chained with the harness trap: remove containers, keep the failure guarantee.
trap 'cleanup; [[ "${_T_FAILED}" -eq 0 ]] || exit 1' EXIT

# wait_running CONTAINER: true when systemd reports running within 60 s
wait_running() {
    local i state=""
    for i in $(seq 1 30); do
        state="$(docker exec "$1" systemctl is-system-running 2>/dev/null || true)"
        case "${state}" in
            running) return 0 ;;
            degraded | starting | initializing | "") sleep 2 ;;
            *) break ;;
        esac
    done
    printf 'state: %s\n' "${state:-unreachable}" >&2
    docker exec "$1" systemctl --failed --no-pager --no-legend 2>/dev/null >&2 || true
    return 1
}

boot() { # $1 label, $2... docker run flags; sets $c
    c="osnova-smoke-$$-${RANDOM}"
    containers+=("${c}")
    if docker run -d --pull=never --name "${c}" "${@:2}" "${image}" >/dev/null 2>"${errdir}/${c}.err"; then
        if wait_running "${c}"; then
            t_ok "$1: systemd is running"
            return 0
        fi
        t_fail "$1: systemd did not reach running"
        docker inspect -f 'container: {{.State.Status}}, exit code {{.State.ExitCode}}' "${c}" >&2 2>/dev/null || true
        docker logs --tail 20 "${c}" >&2 2>&1 || true
        return 1
    fi
    t_fail "$1: docker run refused: $(head -c 200 "${errdir}/${c}.err")"
    return 1
}

# assert_contract CONTAINER LABEL: the SPEC 7.4 list on one booted container
assert_contract() {
    local pid1 init svc mid out
    pid1="$(docker exec "${1}" sh -c 'tr -d "\0" < /proc/1/comm')"
    t_assert_eq "systemd" "${pid1}" "${2}: PID 1 is systemd"
    init="$(docker exec "${1}" readlink -f /sbin/init)"
    if [[ "${init}" == */systemd ]]; then t_ok "${2}: /sbin/init resolves to systemd (${init})"; else t_fail "${2}: /sbin/init resolves to ${init}"; fi
    if out="$(docker exec "${1}" python3 --version 2>&1)"; then t_ok "${2}: python3 present"; else t_fail "${2}: python3 missing: ${out:-no output}"; fi
    if out="$(docker exec "${1}" sudo -n true 2>&1)"; then
        t_ok "${2}: sudo -n true as root"
    else
        t_fail "${2}: sudo as root failed: ${out:-no output}"
        # what sudo's PAM stack saw: the caller, its capabilities, the shadow file and the lookup
        docker exec "${1}" sh -c 'id; grep -E "^(CapEff|NoNewPrivs|Seccomp):" /proc/self/status; ls -ln /etc/shadow /etc/passwd; getent shadow root >/dev/null 2>&1; echo "getent shadow root: exit $?"; grep -E "^(passwd|shadow):" /etc/nsswitch.conf; grep -c selinuxfs /proc/filesystems; findmnt -n -o FSTYPE,OPTIONS /' >&2 2>&1 || true
    fi
    if docker exec "${1}" sh -c 'command -v microdnf' >/dev/null 2>&1; then
        docker exec "${1}" microdnf install -y cronie >/dev/null 2>&1 && svc=crond || svc=""
    else
        docker exec "${1}" sh -c 'apt-get update -qq && apt-get install -y -qq cron' >/dev/null 2>&1 && svc=cron || svc=""
    fi
    if [[ -n "${svc}" ]]; then
        t_ok "${2}: package manager installed ${svc}"
        docker exec "${1}" systemctl enable --now "${svc}" >/dev/null 2>&1 || true
        t_assert_eq "enabled" "$(docker exec "${1}" systemctl is-enabled "${svc}" 2>/dev/null)" "${2}: ${svc} enabled"
        t_assert_eq "active" "$(docker exec "${1}" systemctl is-active "${svc}" 2>/dev/null)" "${2}: ${svc} active"
    else
        t_fail "${2}: the package manager could not install a service"
    fi
    if docker exec "${1}" test -e /usr/bin/pebble; then t_fail "${2}: pebble present"; else t_ok "${2}: no unmanaged pebble binary"; fi
    if docker exec "${1}" sh -c 'command -v rpm' >/dev/null 2>&1; then
        if ! docker exec "${1}" rpm -q libcurl-minimal >/dev/null 2>&1; then
            t_fail "${2}: libcurl-minimal is not installed"
        elif docker exec "${1}" rpm -q libcurl >/dev/null 2>&1; then
            t_fail "${2}: full libcurl present"
        else
            t_ok "${2}: no full curl (libcurl-minimal only)"
        fi
    else
        if docker exec "${1}" test -e /usr/bin/curl; then t_fail "${2}: full curl present"; else t_ok "${2}: no full curl"; fi
    fi
    mid="$(docker exec "${1}" cat /etc/machine-id 2>/dev/null || true)"
    if [[ "${mid}" =~ ^[0-9a-f]{32}$ ]]; then t_ok "${2}: machine id is 32 hex"; else t_fail "${2}: machine id is not 32 hex: '${mid}'"; fi
    machine_ids+=("${mid}")
    if docker exec "${1}" id ubuntu >/dev/null 2>&1; then t_fail "${2}: ubuntu user present"; else t_ok "${2}: no ubuntu user"; fi
}

# 1. the documented contract (SPEC 7.1)
if boot "documented contract" --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --cap-add SYS_ADMIN --security-opt apparmor=unconfined; then
    assert_contract "${c}" "documented contract"
fi

# 2. the compatibility form (SPEC 7.2): the same assertions
if boot "compatibility form" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw; then
    assert_contract "${c}" "compatibility form"
fi
if [[ "${#machine_ids[@]}" -eq 2 && -n "${machine_ids[0]}" && "${machine_ids[0]}" != "${machine_ids[1]}" ]]; then
    t_ok "the two containers hold different machine ids"
else
    t_fail "the two containers do not hold two different machine ids"
fi

# 3. Podman when present (SPEC 7.3): no flags
if ! command -v podman >/dev/null 2>&1 || ! podman info >/dev/null 2>&1; then
    t_ok "podman not present: skipped"
elif ! podman image exists "${image}" >/dev/null 2>&1; then
    t_ok "podman has no ${image}: skipped (podman load from docker save runs it)"
else
    p="osnova-smoke-podman-$$"
    podman_containers+=("${p}")
    if podman run -d --pull=never --name "${p}" "${image}" >/dev/null 2>&1; then
        state=""
        for _ in $(seq 1 30); do
            state="$(podman exec "${p}" systemctl is-system-running 2>/dev/null || true)"
            [[ "${state}" == running ]] && break
            sleep 2
        done
        t_assert_eq "running" "${state}" "podman: systemd is running"
        podman rm -f "${p}" >/dev/null 2>&1 || true
    else
        t_fail "podman run refused the image"
    fi
fi
t_finish
