# Use the images

The images are development and test infrastructure. They run as root and
need capabilities a hardened workload would never get. Run them on trusted
development machines and CI runners, never a shared or production host
([security](../security.md)).

## Docker

```bash
docker run -d --name box \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  ghcr.io/denyka/osnova/debian13:latest
docker exec box systemctl is-system-running --wait
```

The image's command is `/sbin/init`, so none is given. The wait prints
`running` when the system is up.

| Flag | Why |
| --- | --- |
| `--cgroupns=host` | systemd manages its own hierarchy; a private namespace does not boot |
| `-v /sys/fs/cgroup:/sys/fs/cgroup:rw` | systemd needs the cgroup tree writable |
| `--cap-add SYS_ADMIN` | the one capability systemd needs beyond Docker's defaults; without it Debian boots `degraded` |
| `--security-opt apparmor=unconfined` | Docker's default AppArmor profile denies every mount and systemd mounts `/run` at boot; without it PID 1 exits on a Debian or Ubuntu host, and a host without AppArmor ignores the option |

The host must run cgroup v2; a cgroup v1 host is not supported
([SPEC 7.1](../SPEC.md)).

## What the images do at boot

- Each container generates a fresh machine id on its first boot; the image
  carries none, so two containers never share one.
- The units that touch hardware or kernel interfaces and four maintenance
  timers (`apt-daily.timer`, `apt-daily-upgrade.timer`, `dpkg-db-backup.timer`,
  `fstrim.timer`) are masked, so a clean image reaches `running` and no
  background `apt-get update` races your tooling for the dpkg lock
  ([images](../reference/images.md)).
- The Ubuntu images carry no `ubuntu` user: uid 1000 is free for the users
  your tooling creates.

The pull path is `ghcr.io/denyka/osnova/<image>:<tag>`; the image names
are in [images](../reference/images.md).

## Molecule

Molecule's docker driver expresses the same contract with
`privileged: true`. That is the only reason the compatibility form exists
([SPEC 7.2](../SPEC.md)):

```yaml
platforms:
  - name: instance
    image: ghcr.io/denyka/osnova/debian13:latest
    pre_build_image: true
    command: /sbin/init
    privileged: true
    cgroupns_mode: host
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
```

`privileged: true` gives the container every capability and host device
and removes the seccomp and AppArmor confinement. Container root is
roughly host root. Use it only on a machine you trust with that.

## Podman

Podman detects an init image and runs it in systemd mode with no flags:

```bash
podman run -d ghcr.io/denyka/osnova/debian13:latest
```

CI never exercises Podman. To check an image locally, load it from Docker
and run the smoke suite, which boots under Podman only when
`podman image exists` is true:

```bash
docker save ghcr.io/denyka/osnova/debian13:latest | podman load
make smoke IMAGE=ghcr.io/denyka/osnova/debian13:latest
```

## The apt cache

The `deb` images ship without package lists. Run `apt-get update` before
the first `apt-get install`. The `el` images use `microdnf`, which needs no
such step.

## Pinning

| Pin | Form | Lasts |
| --- | --- | --- |
| Latest | `debian13:latest` | moves on every release |
| Dated tag | `debian13:2026.10.19` | ninety days, and in any case while it is one of the five newest releases |
| Digest | `debian13@sha256:<digest>` | as long as the dated tag it came from exists |

Retention deletes a dated tag once it is older than ninety days and five
newer releases exist ([tags](../reference/tags.md)). To pin for longer,
mirror the image into a registry you control. Digests are listed in the
release notes and in `record.json` ([verify a release](verify_a_release.md)).
