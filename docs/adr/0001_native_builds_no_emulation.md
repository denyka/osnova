# 0001. Native builds, no emulation

- Status: accepted
- Date: 2026-10-19

## Context

The images ship for `linux/amd64` and `linux/arm64`. One runner can build both through QEMU, but the images boot systemd, and the build and the smoke suite must run the real thing.

## Decision

Every build and every test runs on a runner of the architecture it targets: `ubuntu-24.04` for amd64, `ubuntu-24.04-arm` for arm64. Emulation is refused anywhere ([SPEC 3](../SPEC.md), principle 5; invariant in SPEC 15).

## Options considered

- Emulated arm64 build on an amd64 runner. Rejected: emulated systemd does not initialise its cgroup hierarchy, so `systemctl is-system-running` never answers and the smoke suite cannot prove the contract.
- Build under emulation, test natively. Rejected: two mechanisms, and the image that was built is not the image that was tested.
- Native runner per architecture. Accepted.

## Consequences

- Two build jobs per run, one per architecture, each taking every image in turn.
- The release depends on GitHub's hosted arm64 runners being available.
- `tests/workflows.sh` refuses `qemu`, `DOCKER_DEFAULT_PLATFORM` and a foreign platform on a runner.
