# 0002. The reduced run contract

- Status: accepted
- Date: 2026-10-19

## Context

Booting systemd in Docker is commonly done with `--privileged`. A spike on a cgroup v2 host tried the smaller settings:

| Setting | Result |
| --- | --- |
| Private cgroup namespace (Docker's default) | Exits at once |
| Host cgroup namespace, cgroup mount read-write, no added capability | Boots `degraded` on Debian |
| The same with `SYS_ADMIN` | `running` |
| `--privileged` | `running`, with far more exposure |

## Decision

The documented contract is `--cgroupns=host`, the read-write cgroup mount and `--cap-add SYS_ADMIN` ([SPEC 7.1](../SPEC.md)). `--privileged` is kept only as the compatibility form for Molecule's docker driver ([SPEC 7.2](../SPEC.md)). The smoke suite boots both.

## Options considered

- Private cgroup namespace. Rejected: the container exits at once.
- Host namespace without a capability. Rejected: Debian boots `degraded`, which the smoke suite treats as a failure.
- `--privileged` as the documented form. Rejected: roughly host root for a need that one capability meets.
- Host namespace, mount and `SYS_ADMIN`. Accepted.

## Consequences

- The exposure is smaller than `--privileged` and still not isolation; [security](../security.md) states it.
- The contract is stated for cgroup v2 hosts.
- Molecule needs the privileged platform block, documented with its warning in [use the images](../how_to/use_the_images.md).

## Addendum, 2026-10-20

Docker's proposed `--security-opt writable-cgroups=true`, which would let
systemd boot in a private cgroup namespace without the host mount, was
tried on Docker 29.8.2: the client refuses the option. The contract above
stands; the option is re-tried when a Docker release documents it.

## Addendum, 2026-10-21

The first gate run on GitHub's Ubuntu runners did not boot the contract:
PID 1 exited before the first unit. Docker's default AppArmor profile
denies every `mount`, whatever the capability set, and systemd mounts a
tmpfs on `/run` at boot. Reproduced locally by refusing `mount` through a
seccomp profile: the same exit. With `/run` pre-mounted by Docker, systemd
starts but `systemd-sysusers` and `systemd-tmpfiles-setup` fail their own
mount sandboxing and the system is `degraded`, so a `--tmpfs` is not a
fix. The spike above ran on Docker Desktop, whose kernel has no AppArmor,
which is why the flag was not found then. `--security-opt
apparmor=unconfined` joins the contract: it lifts the profile and nothing
else, a host without AppArmor ignores it, and `--privileged` implied it
already. A profile of the project's own was rejected: it would have to be
installed on every host before the first run.
