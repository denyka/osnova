# osnova Specification

| Field | Value |
| --- | --- |
| Version | 2026.10.21 |
| Status | APPROVED by owner, 2026-10-19; revision 2026-10-20 proposed after the first review and revision 2026-10-21 after the first gate run, both pending the owner's approval |
| Owner | Denys Neichev |
| Scope | The whole `osnova` repository, the images it publishes and the pipeline that publishes them |

This document is the single source of truth for osnova. Anything in the
repository that disagrees with it is wrong and is corrected to match it.
Changes to this document need the owner's explicit approval before they are
made, and no change in the repository lands ahead of the SPEC change that
describes it. Every feature, mechanism and state of the repository has its
place here.

The standards the repository is held to come from HQ, the owner's
headquarters repository: its hygiene, documentation, forge and Claude layer
templates apply byte for byte, and its audits run against this tree. Where
osnova deviates from an HQ standard, section 14 says so and why; nothing
deviates silently.

## 1. Purpose

osnova (Ukrainian: foundation) publishes slim, multi-architecture base
images that boot real systemd as PID 1. They serve two audiences:

- people testing configuration tooling such as Ansible, Molecule and
  anything else that expects a manageable systemd system to converge
  against
- anyone who needs a minimal, patched, verifiable systemd system inside a
  container as the base of something else

Success means a stranger can pull an image, verify its signature and
provenance, read one page and use it correctly, and that the repository
itself reads as a model of how a public image project is built and run.

### 1.1 Out of scope

- Application images. osnova ships the base and nothing on top of it.
- Isolation. The images run as root and need capabilities a hardened
  workload would never get (section 7). They are development and test
  infrastructure, and the documentation says so wherever they are run.
- Any registry but GHCR, any architecture but `linux/amd64` and
  `linux/arm64`, any init but systemd.

## 2. Governance

- **Source of truth.** `docs/SPEC.md` wins over code, docs, skills,
  `CLAUDE.md` and any conversation. When they disagree, the other side is
  fixed.
- **Approval.** A SPEC change is proposed as a diff, approved by the owner,
  then applied. Implementation follows, never precedes.
- **Roles.** The owner steers, approves every SPEC change and alone pushes,
  merges and changes the repository settings. The lead plans against this
  file, dispatches the work and reviews every diff. Implementers write
  code and commit locally. The release pipeline (section 8) is the one
  actor that creates tags and releases, and it does so unattended.
- **Version.** This file's version is its revision date, in the form of
  the image tags of section 8.2. Image releases are dated builds and are
  not revisions of this file, and a release bumps nothing here; a change
  to this file that changes what an image contains reaches consumers in
  the next dated release (section 17).

## 3. Principles

1. **Security first.** Where security conflicts with convenience, size,
   speed or style, security wins. This is the fleet's rule and osnova's.
2. **Unattended by default, human for change.** Patching, rebuilding,
   tagging and releasing need no human. Changing what an image is, what
   the pipeline does or what this file says needs one.
3. **One mechanism per problem.** No second mechanism where one rule
   solves the problem. The bake file is the one build definition, locally
   and in CI; the smoke suite is the one boot test, locally and in CI.
4. **Reproducible from the release record.** Every published image states
   exactly what it was built from: the base digest, the commit, the
   workflow. The record lives with the release, not in git, signed as a
   blob by the same workflow identity that signs the images, on a release
   the repository setting makes immutable (section 8.4).
5. **Native only.** Every build and every test runs on the architecture it
   targets. No emulation, anywhere, ever (ADR 0001).
6. **Evidence over recollection.** Every claim about a contract is proven
   by a test on every build. A rule enters this file only with a check that
   enforces it (section 15).
7. **snake_case** for files, make targets, workflow names and skills.
8. **Development process lives in `.dev/`.** Plans, ledgers, findings and
   anything else about how the repository is developed are written under
   a gitignored `.dev/`; `.tmp/` is throwaway and `make clean` deletes it.
   Nothing about the process is tracked, only its outcome.
9. **Lean on runners.** Hosted runners are free for a public repository
   but shared and limited across the owner's account. A workflow runs
   only when its result can change, a job does as much as it can on one
   runner, every job has a timeout, and nothing is built twice for the
   same answer (section 8.10).

## 4. Threat model and data classification

### 4.1 Assets, threats, controls

| Asset | Threat | Control |
| --- | --- | --- |
| A published image | A consumer pulls something other than what the pipeline built | Keyless cosign signature on every index, bound to this repository's release workflow identity, and verified by the pipeline itself before `latest` moves; a GitHub artifact attestation on every index; SBOM and SLSA provenance attached per architecture; the record signed as a blob on an immutable release; digest table in the release notes |
| The build input | A compromised or stale upstream base | Base resolved to its index digest at build time and recorded in labels, provenance and the release, with its per-architecture digests; upstream patches applied at build; Trivy gate on fixable HIGH and CRITICAL before any push; the daily watch rebuilds when a fix exists |
| The pipeline | A third-party action or tool runs code it did not yesterday | Every action pinned to a commit SHA with its version in a comment; the BuildKit and SBOM generator images pinned by digest; Trivy verified against a sha256 pinned in the tree; `persist-credentials: false` on every checkout the project writes (section 14 for HQ's lint workflow); least-privilege permissions per job; third-party actions kept to the minimum section 8.9 lists |
| The publish path | Someone other than the pipeline publishes under the project's name | Only the release workflow holds package write scope; the registry login happens only after the image has been scanned and booted, immediately before the push, and is logged out after it (the job token itself exists for the whole job: section 4.2); the cosign identity names that workflow, so a consumer's `cosign verify` refuses anything else; the pushed image is asserted to be the scanned one by config digest; no long-lived registry credential exists |
| The repository | A secret or a credential enters the tree | No secret exists in this repository: the only credential is the job-scoped `GITHUB_TOKEN`; gitleaks and private-key detection in pre-commit and CI over tree and history; the ignore rules refuse files named like secrets |
| The default branch | A change merges without the gate | Ruleset from the forge: linear history, signed commits, no force push, no deletion; a pull request required for every change and the lint and image gates required on it, all from the forge module |
| The consumer's host | The run contract gives the container more than it needs | The documented contract is the least that boots systemd under Docker (section 7); the privileged form is documented only for Molecule's driver; the exposure is stated in `docs/security.md`, not hidden |

### 4.2 Accepted exposures

- The reduced run contract shares the host cgroup namespace and mounts the
  cgroup tree read-write. A process in the container can read and write
  the host's cgroup hierarchy. It cannot reach host devices, keeps the
  default seccomp and AppArmor profiles and holds one added capability.
  This is far less than `--privileged` and still not isolation; the images
  are for trusted development machines and CI runners.
- The privileged compatibility form makes container root roughly host
  root. It exists because Molecule's docker driver cannot express the
  reduced contract on every host; it is documented with that warning.
- The images run as root and carry `sudo` for tooling that expects it.
  Root does not need a password for `sudo`, which is stock behaviour, not
  a change this project makes.
- Unattended releases publish images no human reviewed. The gates, the
  signature and the record are the review. A gate failure publishes
  nothing and opens an issue (section 8.6).
- Retention deletes a dated tag once it is older than ninety days and at
  least five newer releases exist (section 8.7). A consumer's pin older
  than that stops resolving. The alternative, serving images with known
  unfixed vulnerabilities indefinitely, is the worse exposure. GHCR refuses
  to delete a public version with more than five thousand downloads; such
  a version stays, is reported, and is not a failure.
- A tag or a release can be created by anyone with write access to the
  repository, which is the owner and the pipeline. The repository has no
  other collaborators; adding one changes section 4.1 first.
- The smoke suite boots the freshly built image, upstream content
  included, under `--privileged` on the runner that then pushes it. A
  privileged container is roughly host root on the runner: it can reach
  the BuildKit daemon, and it can read the memory of the runner process,
  which holds the job's `GITHUB_TOKEN` with `packages: write` for the
  whole job, whether or not a registry login has happened. The login
  placement of section 8.3 step 5 keeps the credential out of the Docker
  configuration a container would read first; it does not remove the
  token from the runner. Pushing from a job that never runs the image
  would move every image between jobs as an artifact, which principle 9
  declines, and dropping the privileged boot from the release build would
  leave the compatibility form proven only by the pull request gate. The
  pipeline asserts that the pushed image's config digest is the scanned
  and booted image's; a tampered BuildKit cache that kept the config
  intact would pass that check. The exposure needs a compromised official
  upstream base image, in which case every consumer of that base is
  already compromised, and is accepted; the signed record and the
  signature identity would still show what this pipeline pushed.
- A release is one set: the build jobs fail fast and nothing publishes
  until every image passed. One distribution whose mirror lacks the fix
  for a fixable finding blocks the other five until upstream catches up,
  and the watch re-dispatches once a day, each run commenting on the open
  issue. Per-image publication would give `latest` and the record two
  meanings; the daily bound and the issue are accepted instead.
- GitHub disables the schedules of a public repository after sixty days
  without activity. The watch re-enables both scheduled workflows on every
  run (section 9), which resets that clock daily while the watch runs; a
  watch that was itself disabled is re-enabled by the owner
  (`docs/how_to/run_a_release.md`). Nothing in the repository can notice
  that state from inside; the owner's calendar is the backstop.
- A publish that fails part way leaves a dated tag with no release naming
  it, signed or not (section 8.6). It is never `latest`, a re-run of the
  failed jobs completes it, and retention deletes it once no release names
  it.

### 4.3 Data classification

| Class | Meaning | In this repository | Tracked |
| --- | --- | --- | --- |
| **P** public | Could be published without harm | every tracked file: the repository is public | yes |
| **I** internal | Configuration and design, not credentials | the owner's process and scratch under `.dev/` and `.tmp/` | never |
| **S** secret | Keys, tokens, passwords, certificates | none exist (section 4.1); the ignore rules refuse files named like them | never |

There is no class of tracked file that could not be published.

## 5. Repository layout

```text
osnova/
├── images/
│   ├── el/Dockerfile          AlmaLinux family
│   └── deb/Dockerfile         Debian and Ubuntu family
├── matrix.yml                 the image matrix: name, family, base tag
├── docker-bake.hcl            the one build definition, local and CI
├── tools/
│   ├── resolve_bases.sh       base tag → index digest, for bake and CI
│   ├── release_notes.sh       the generated notes of a release
│   └── retain.sh              retention over the registry after a publish
├── tests/                     suites run by make test (section 12)
│   ├── lib/harness.sh         HQ's test harness, verbatim
│   └── run.sh                 HQ's suite runner, verbatim
├── docs/                      SPEC, security, ADRs, how-tos, reference
├── .github/
│   ├── workflows/
│   │   ├── lint.yml           HQ's lint workflow, verbatim
│   │   ├── ci.yml             native build, scan and boot on pull requests
│   │   ├── release.yml        the unattended release (section 8)
│   │   └── watch.yml          daily drift and CVE watch (section 9)
│   ├── actions/build_and_verify/   the steps ci.yml and release.yml share
│   ├── ci_changes.sh          the changes classifier of ci.yml (section 8.10)
│   ├── trivy.sha256           the pinned Trivy version and its tarball digests (section 8.9)
│   ├── dependabot.yml, CODEOWNERS, ISSUE_TEMPLATE/, pull_request_template.md
│   └── requirements.txt       the pinned pre-commit for CI
├── .trivyignore.yaml          the one declared Trivy exemption, scoped and stated (section 14)
├── .claude/                   settings and skills (section 13)
├── .dev/, .tmp/               gitignored process and scratch
├── Makefile                   self-documenting entry points
├── CLAUDE.md                  thin pointer; AGENTS.md links it
└── README, CHANGELOG, LICENSE, SECURITY, CONTRIBUTING, CODE_OF_CONDUCT
```

Root hygiene files from HQ: `.editorconfig`, `.gitignore`,
`.markdownlint.yaml`, `.pre-commit-config.yaml`, `.shellcheckrc`,
`.yamllint.yaml`, `.hadolint.yaml`, `.dockerignore` (inert: the bake
contexts are the family directories, which hold only a Dockerfile).

## 6. Images

### 6.1 Matrix

| Image | Family | Base tag | Package manager |
| --- | --- | --- | --- |
| `almalinux9` | `el` | `almalinux:9-minimal` | microdnf |
| `almalinux10` | `el` | `almalinux:10-minimal` | microdnf |
| `debian12` | `deb` | `debian:12-slim` | apt |
| `debian13` | `deb` | `debian:13-slim` | apt |
| `ubuntu2404` | `deb` | `ubuntu:24.04` | apt |
| `ubuntu2604` | `deb` | `ubuntu:26.04` | apt |

`matrix.yml` is the single source of the matrix and holds exactly these
three facts per image: name, family, base tag. It holds no digest: the
digest is a build-time input resolved by `tools/resolve_bases.sh` and
recorded with the release (section 8.4). Every image name is lower-case
letters and digits, the distribution and its major with no separator.

**Version policy: two majors per family.** The matrix carries exactly the
two newest majors of each distribution, LTS releases only for Ubuntu.
Adding a new major retires the oldest of that distribution in the same
change (`docs/how_to/add_a_distro.md`). A retired image keeps its dated
tags on the registry forever; it simply stops receiving builds.

### 6.2 Baseline

Each image is the upstream minimal base, patched, plus the smallest set
that makes a manageable systemd system:

| Package | `el` | `deb` | Purpose |
| --- | --- | --- | --- |
| systemd | yes | yes | PID 1 |
| systemd-sysv | no | yes | the `/sbin/init` link |
| python3 | yes | yes | interpreter for configuration tooling |
| package-manager bindings | `python3-dnf` | `python3-apt` | the tooling's package modules |
| sudo | yes | yes | privilege escalation for tooling that calls it |
| ca-certificates | yes | yes | TLS validation |

Nothing else. No editors, no full `curl` (the `el` minimal base ships the
distribution's minimal curl: `curl-minimal` on 9, and on 10 the `curl`
package itself, built on `libcurl-minimal` and required by `rpm`; neither
family ships the full-protocol libcurl), no users, no SSH. Two base
quirks are undone by the `deb` Dockerfile and are documented as quirks,
not rules for other images: `ubuntu:26.04` ships `pebble`, an unmanaged
binary outside apt's reach, which is removed; and the Ubuntu bases ship
an `ubuntu` user at uid 1000, which is removed, because a test container
is where tooling creates its own users and uid 1000 is the one they take.

### 6.3 Build contract

Both Dockerfiles follow the same shape, and `tests/dockerfiles.sh` holds
every line of it:

- `ARG BASE_IMAGE` with the family's newest base tag as the default, so
  the Dockerfile lints and builds on its own; every real build passes
  `BASE_IMAGE=<tag>@sha256:<digest>` from the bake file.
- A build stage that upgrades the base, installs the baseline, strips
  package caches, documentation (keeping every `copyright` file under
  `/usr/share/doc`, which redistribution requires), manuals, locale
  catalogues and logs, empties `/etc/machine-id` and removes
  `/var/lib/dbus/machine-id` so that systemd generates a fresh machine id
  on every first boot, and masks the units in section 6.4 by linking them
  to `/dev/null`. Anything the build stage needs in its environment, such
  as `DEBIAN_FRONTEND`, is an `ARG` of that stage and never an `ENV`.
- A final stage `FROM scratch` that copies the build stage's root, so the
  image is one layer and superseded package payloads from the upgrade
  never ship. A final stage from the base would keep the base layer under
  the copy, and the build stage's deletions would never reach it.
- `ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  HOME=/root` set explicitly (scratch carries no configuration) and
  nothing else in the environment, `STOPSIGNAL SIGRTMIN+3`,
  `CMD ["/sbin/init"]`.
- Static OCI labels: description, licenses `MIT`, vendor `denyka`. The
  per-image labels come from the bake file and the pipeline (section 6.5).
- No `USER` instruction: an init image runs as root (section 14).
- No PAM or sudoers change, and one shadow change, in the `el` stage
  only: `/etc/shadow` is set to mode 0600. The base ships it as 0000,
  readable only through `CAP_DAC_READ_SEARCH`; pam_unix has run the
  setuid helper `unix_chkpwd` for every shadow lookup since its fix for
  CVE-2024-10041, and a host whose AppArmor confines that helper by path
  (Ubuntu 24.04 ships such a profile without that capability, and the
  profile attaches inside any unconfined container, `--privileged`
  included) refuses it the read, so `sudo` fails for root. Mode 0600
  keeps the file root-only and lets its owner read it with no
  capability; the `deb` family's 0640 `root:shadow` already does. The
  smoke suite proves it on the gate's Ubuntu runners. No network fetch
  other than the package manager. No secret in any form.

### 6.4 Masked units

Masked in every image, identical across families, because they touch
hardware or kernel interfaces a container does not have and would
otherwise leave systemd `degraded` for reasons that are not the
consumer's:

`dev-hugepages.mount`, `sys-fs-fuse-connections.mount`,
`systemd-logind.service`, `getty.target`, `console-getty.service`,
`systemd-udevd.service`, `systemd-udev-trigger.service`,
`systemd-modules-load.service`.

Also masked, identical across families, because they run unattended
package or filesystem maintenance that a test container must not start on
its own (a background `apt-get update` races the tooling under test over
the dpkg lock):

`apt-daily.timer`, `apt-daily-upgrade.timer`, `dpkg-db-backup.timer`,
`fstrim.timer`.

A mask for a unit a family does not ship is a dangling link systemd
ignores; the set stays identical so that `tests/dockerfiles.sh` can hold
it as one list.

### 6.5 Labels

| Label | Source | Value |
| --- | --- | --- |
| `org.opencontainers.image.title` | bake file | the image name |
| `org.opencontainers.image.description` | Dockerfile | family description |
| `org.opencontainers.image.licenses` | Dockerfile | `MIT` |
| `org.opencontainers.image.vendor` | Dockerfile | `denyka` |
| `org.opencontainers.image.source` | bake file | `https://github.com/denyka/osnova` |
| `org.opencontainers.image.url` | bake file | the image's package page |
| `org.opencontainers.image.revision` | pipeline | the commit built |
| `org.opencontainers.image.created` | pipeline | RFC 3339 UTC |
| `org.opencontainers.image.version` | pipeline | the dated tag |
| `org.opencontainers.image.base.name` | bake file | the base tag |
| `org.opencontainers.image.base.digest` | bake file | the resolved base digest |

## 7. Run contract

### 7.1 The documented contract

```bash
docker run -d --name box \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  ghcr.io/denyka/osnova/debian13:latest
```

The image's command is `/sbin/init`, so no command is given. Each flag is
required: the host cgroup namespace and the read-write cgroup mount let
systemd manage its hierarchy; `SYS_ADMIN` is the one capability systemd
needs beyond Docker's defaults. Without it the Debian family boots
`degraded`. `apparmor=unconfined` lifts Docker's default AppArmor
profile, which denies every `mount` whatever the capability set: systemd
mounts a tmpfs on `/run` before its first unit, and with that mount
refused PID 1 exits; a `/run` that Docker mounts instead gets systemd up
only to `degraded`, because `systemd-sysusers` and
`systemd-tmpfiles-setup` sandbox themselves with mounts of their own. A
host without AppArmor accepts the option and ignores it; a Debian or
Ubuntu host, the gate's runners included, needs it (ADR 0002, second
addendum). This is the least Docker needs to boot systemd on a cgroup v2
host (ADR 0002); a private cgroup namespace does not boot at all, and the
`writable-cgroups` security option proposed for Docker is refused by
Docker 29.8 (ADR 0002, first addendum). A cgroup v1 host is not
supported. The gate runs on Ubuntu runners, which carry AppArmor, so
every pull request proves the contract on an AppArmor host.

### 7.2 The compatibility form

Molecule's docker driver expresses the same contract with `privileged:
true`, which lifts the AppArmor profile among everything else it grants,
`cgroupns_mode: host` and the cgroup volume. The how-to gives that
platform block verbatim and states what `--privileged` adds. Nothing in
the images depends on it.

### 7.3 Podman

Podman detects an init image and runs it in systemd mode with no flags.
The how-to documents the plain `podman run` and the smoke suite runs under
Podman when it is present.

### 7.4 What the smoke suite proves

`tests/smoke.sh` boots the image under the documented contract and, on
the same image, under the compatibility form, and asserts the same list
on each:

1. `systemctl is-system-running` reaches `running` within sixty seconds.
   `degraded` fails: the masked set exists so that a clean image is
   `running`, and a regression there is a regression.
2. `python3` and `sudo` are present, and `sudo -n true` succeeds as root.
3. The family package manager installs a service (`cronie` on `el`,
   `cron` on `deb`), `systemctl enable --now` starts it, and it reports
   `enabled` and `active`.
4. PID 1 is systemd and `/sbin/init` resolves to it.
5. `/etc/machine-id` holds a fresh 32-hex id, and the two containers of
   the run hold different ones.
6. No `pebble` binary, no full curl (section 6.2), no `ubuntu` user.

The suite runs the same way locally (`make smoke`), on every pull request
and on every release build, on both architectures. When
`OSNOVA_SMOKE_IMAGE` names an image and Docker does not answer, the suite
fails; it reports itself skipped only when no image is named
(section 11).

## 8. Release pipeline

### 8.1 Triggers

`release.yml` runs on three events and no other:

| Trigger | When |
| --- | --- |
| schedule | the first day of every month |
| dispatch from the watch | an upstream base moved or a fixable CVE appeared (section 9) |
| manual dispatch | the owner |

There is no push trigger and no pull request trigger: merging a change
to `main` publishes nothing until the next run, and the next run picks up
every merged change.

### 8.2 Versioning

Calendar versioning by build date: the git tag is `vYYYY.MM.DD`, the image
tag `YYYY.MM.DD`, both from the UTC date of the run. Every run also moves
`latest`. A dated tag is immutable for as long as it exists and is removed
only by retention (section 8.7). A run on a day whose git tag already exists,
or whose image tag already exists on the registry (a run that failed after
publishing), stops before building and does nothing else; a second release
on one day is not a case the project supports. Recovery is re-running the
failed jobs of that run, which keeps its resolved bases and its artifacts
for seven days (section 8.10), or the next day, which is never far. The
changelog heading for a release is the image tag in brackets,
`## [YYYY.MM.DD]` (section 16).

Nothing in a base image is an interface with breaking changes: the
distribution major is in the image name, so the only thing a version says
is how fresh the image is, and a date says that exactly (ADR 0003).

### 8.3 Steps

One run; one prepare job; one build job per architecture on its native
runner (`ubuntu-24.04` for `linux/amd64`, `ubuntu-24.04-arm` for
`linux/arm64`, both pinned to one OS release so the two architectures
never diverge), each taking every image of the matrix in turn through
steps 2 to 5; then one publish job, one release job, one promote job and
one retain job over all images:

1. **Prepare**, once per run. `tools/resolve_bases.sh` reads
   `matrix.yml`, resolves each base tag to its index digest and to the
   digests of its `linux/amd64` and `linux/arm64` manifests with
   `docker buildx imagetools inspect`, and emits the bake variables and
   the JSON the record carries. A base that cannot be resolved fails the
   run; an unreachable registry must never read as "unchanged". The job
   fixes the run's `created` timestamp once, so that both architectures,
   the labels and the index annotations carry one value and a re-run of
   the failed jobs reproduces byte-identical indexes: a dated tag never
   moves on a re-run (section 8.2). The job then refuses a dated tag that
   already exists as a git tag or on the registry (section 8.2); a package
   that does not exist yet reads as absent through the Packages API, any
   other registry failure fails the run.
2. **Build.** `docker buildx bake` the target for this architecture from
   `BASE_IMAGE=<tag>@<digest>`, loaded locally, nothing pushed, and
   without a layer cache: a cached upgrade layer would skip the patches
   the release exists to apply. No registry login exists yet.
3. **Scan.** Trivy on the built image, once, as JSON: OS and library
   vulnerabilities of severity HIGH and CRITICAL. Any finding with a fix
   version fails the run; the findings without one are printed as a
   summary in the log and never fail it.
4. **Boot.** `tests/smoke.sh` on the built image (section 7.4).
5. **Push by digest.** Only now the job logs in to the registry, pushes
   the same bake target without a tag, with an SBOM and SLSA provenance
   (`mode=max`) attached as attestation manifests in the per-architecture
   index, asserts that the pushed image's config digest equals the loaded
   image's, and logs out. Nothing that ran before this step could see a
   registry login (the job token's own exposure is stated in section 4.2).
6. **Publish**, one job after both build jobs, per image: merge the two
   digests into one index tagged `YYYY.MM.DD`, annotated with the OCI
   title, description, source, url, revision, created and version
   (section 6.5) so that the registry page shows them; sign the index
   digest with cosign keyless through the job's OIDC identity, in the
   legacy tag form (`sha256-<digest>.sig` beside the image), the form
   section 8.7 relies on, which under cosign 3 is
   `--new-bundle-format=false --use-signing-config=false`; verify the
   signature at once with the identity of section 8.5; then attach a
   GitHub artifact attestation to the index digest. Only the index is
   signed: that is what a tag resolves to, so that is what `cosign verify`
   checks. Each image is tagged, signed and verified before the next; a
   failure stops the loop (section 8.6).
7. **Release**, once per run after every image published: sign
   `record.json`, the machine-readable record of the run (section 8.4),
   as a blob with cosign keyless into `record.json.sigstore.json`; create
   the git tag on the built commit and a GitHub release carrying both
   files and notes generated from the record by `tools/release_notes.sh`
   as one table. The repository setting makes releases immutable.
8. **Promote**, one job after the release exists, per image: verify the
   signature on the index digest the record names with the identity of
   section 8.5, point `latest` at it and verify that it resolved there.
   `latest` moves last, so a run that fails earlier never moves it
   (section 8.6).
9. **Retain**, one job after `latest` moved, per image: `tools/retain.sh`
   applies section 8.7 to the image's package on the registry, given the
   list of tags the GitHub releases name.

Nothing is retained between runs but the registry, the release and its
record.

### 8.4 The release record

A consumer reproduces or audits a release from the record alone:

- `record.json` on the release and the same data as the notes table: per
  image the tag, the index digest, the base tag, the base index digest
  and the base digest per architecture; plus the commit and the workflow
  run. `record.json.sigstore.json` beside it is its keyless signature by
  the release workflow identity, so a consumer verifies the record before
  trusting it, and the watch does the same (section 9).
- the image labels (section 6.5) and the same values as annotations on
  the index
- the SLSA provenance attached to each architecture's manifest
- the cosign signature on the index, logged in Rekor
- the GitHub artifact attestation on the index, checked with
  `gh attestation verify`

### 8.5 Verification

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp \
    '^https://github\.com/denyka/osnova/\.github/workflows/release\.yml@refs/heads/main$' \
  ghcr.io/denyka/osnova/debian13:latest
```

The release workflow runs from `main`, so the identity is the workflow at
`refs/heads/main` and nothing else. The pipeline runs this verification
itself after signing and again before `latest` moves (section 8.3). The
record is verified with the same identity:

```bash
cosign verify-blob \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp \
    '^https://github\.com/denyka/osnova/\.github/workflows/release\.yml@refs/heads/main$' \
  --bundle record.json.sigstore.json record.json
```

`docs/how_to/verify_a_release.md` carries both commands, the
`gh attestation verify` form, the provenance and SBOM inspection, and
digest pinning.

### 8.6 Failure

A run that fails in prepare or build publishes nothing: the registry
still serves the previous release and `latest` does not move. A run that
fails in publish leaves the dated tags created so far, each signed and
verified before the next was made, at most one of them unsigned, and no
release that names them; `latest` does not move. A run that fails in
release leaves signed dated tags and no release. A run that fails in
promote may have moved `latest` for some images, each to a verified
index. A run that fails in retain has published everything. In every case
the run opens one issue labelled `release-failed` with the run link, the
failing step and the state above, or comments on the open one, and a
re-run of the failed jobs completes the release from where it stopped.
That issue is the only time a release involves the owner. A failing gate
is fixed by a change on `main` through a pull request, and the next run,
scheduled, watched or manual, publishes. A dated tag that no release
names is deleted by retention (section 8.7).

### 8.7 Retention

Per image, after every successful publish, `tools/retain.sh` keeps
`latest`, every dated tag that a GitHub release names and that is
younger than ninety days, and in any case the five newest dated tags a
release names, and deletes every other dated tag: the released ones
older than ninety days beyond the five, and the ones no release names,
which are the orphans of failed runs (section 8.6) at any age. It then deletes every untagged version and
every cosign signature tag that no kept index references, where a kept
index references its per-architecture manifests, its attestation
manifests, the children of any child that is itself an index, and its
cosign signature. Nothing else is ever deleted. Everything to delete is
computed before the first delete; a listing or an index read that fails
stops the script before any delete. A delete the registry refuses with a
client error that means the version cannot or need not be deleted (400,
the answer for a public version with more than five thousand downloads;
404, already gone; 409, 410, 422) is reported and skipped. An
authentication or authorisation error (401, 403), a timeout or a rate
limit (408, 429) and any other failed delete stop the script and fail
the run, leaving the registry serving: a retention that silently skips
every delete for want of a scope would never be noticed otherwise.
The list of released tags the script is given must name at least one
dated tag, or the script refuses before listing anything: the release job
always precedes retention, so an empty list is a failed listing, not an
empty registry.

An image that sits in the registry unrebuilt is a growing set of known
vulnerabilities, so keeping it is the insecure choice. The watch rebuilds
whenever any base moves, so a count of releases is no measure of time;
ninety days is the window a consumer has to move a pin, and the floor of
five is what a consumer finds when releases are rare. The git tag, the
GitHub release and `record.json` are never deleted: the record of every
build outlives its image. A consumer who needs an image for longer
mirrors it, and the how-to says so.

The script is this project's, over the GitHub Packages API, not a
third-party action: the one multi-arch-aware cleanup action available is
third-party and would hold package write scope.

### 8.8 Concurrency

Release runs never cancel each other: a cancelled half-published set would
leave an image with a moved `latest` and a missing architecture. Two runs
queue.

### 8.9 Permissions and actions

The top of `release.yml` grants `contents: read`. Every job states its
own block, which repeats `contents: read` (a job-level block replaces the
top-level one, and a checkout needs it on a private fork) and escalates
only to what the job does:

| Job | Scope beyond `contents: read` | Why |
| --- | --- | --- |
| prepare | `packages: read` | refuse a dated tag already on the registry |
| build, one per architecture | `packages: write` | push by digest, in the last step only |
| publish | `packages: write`, `id-token: write`, `attestations: write` | tag the index, sign and verify it, attest it |
| release | `contents: write`, `id-token: write` | sign the record, create the tag and the release |
| promote | `packages: write` | verify the signed index, point `latest` at it |
| retain | `packages: write` | delete versions under section 8.7 |
| on failure | `issues: write`, `actions: read` | the failure issue, naming the failed jobs and their failing steps read from the run |

Every job in every workflow carries `timeout-minutes`: a hung boot or a
stalled pull must stop in minutes, not at the platform's six-hour
default.

Third-party actions in `release.yml`, `ci.yml` and the shared composite
action, each pinned to a commit SHA: Docker's own `setup-buildx-action`,
`login-action` and `bake-action` (the gate bakes through `bake-action`
because the GitHub Actions layer cache needs the Actions runtime that a
shell step never receives); `sigstore/cosign-installer`. Nothing else.
GitHub's own `actions/checkout`, `actions/upload-artifact`,
`actions/download-artifact` and `actions/attest-build-provenance` are
first-party; the artifact pair carries the digests and the record between
jobs. The images those actions run are pinned too: `setup-buildx-action`
is given the BuildKit image by tag and digest, and the SBOM step names
its generator image by tag and digest, because BuildKit is what writes
the provenance. Every other step is a shell step over tools the runner
ships or the workflow installs: Trivy is downloaded at the version and
verified against the sha256 per architecture that `.github/trivy.sha256`
pins in the tree, the one place its version lives. HQ's lint workflow
carries its own pinned set, hadolint included, verified against
`.github/tools.sha256` the same way.

### 8.10 Runner usage

The rules behind principle 9, each held by `tests/workflows.sh`:

- One build job per architecture, never one per image: checkout, buildx
  and the Trivy database are set up twice per run, not twelve times.
  Publish and retain are one job each, looping over the images.
- `ci.yml` runs on every pull request, and on every push to `main` so
  that the layer cache of section 8.10 is seeded from the merged tree; a
  push runs every job. On a pull request a `changes` job first classifies
  what the pull request touched with git alone, and the `verify` jobs
  skip when the change touched documentation alone: `**/*.md`, `docs/**`,
  `LICENSE`, `.github/ISSUE_TEMPLATE/**`, `.github/pull_request_template.md`,
  `.github/CODEOWNERS` and `.gitlab/**`, HQ's documentation set. An ignore
  list is the one list that cannot omit an input the build reads (HQ SPEC
  11.5 and the GitHub Actions standard). The skip is at job level, never a
  workflow path filter: a required check from a path-filtered workflow
  stays pending and blocks the merge. The two `verify` jobs are plain
  jobs named `verify (linux/amd64)` and `verify (linux/arm64)`, never a
  matrix: a matrix job skipped at job level never expands, reports one
  check under its unexpanded name, and the required contexts stay pending
  just the same. A draft pull request runs lint alone until it is marked
  ready for review.
- Pull request workflows cancel a superseded run of the same branch;
  the release never cancels (section 8.8).
- The pull request gate builds with the GitHub Actions layer cache;
  the release never does (section 8.3, step 2).
- The watch is two short jobs: one resolves six bases and scans six
  published images, the other dispatches or exits (section 9).
- Schedules avoid the top of the hour, when shared runners queue.
- The digests and the record travel between the release jobs as
  artifacts kept for seven days, the window in which "re-run the failed
  jobs" (section 8.2) still has its inputs.

## 9. Watch

`watch.yml` runs daily and on manual dispatch as two jobs under a
top-level `contents: read`. The `scan` job holds `packages: read`: it
downloads the latest release's `record.json` and its bundle, verifies the
record with the identity of section 8.5, resolves the live bases and
scans the published images. The `dispatch` job, after it, holds
`actions: write` beyond `contents: read` and nothing else, and runs
whether or not the scan job succeeded: it re-enables both scheduled
workflows first (section 4.2), then dispatches `release.yml` when the
scan job succeeded with a reason. The watch never commits and never
publishes. The reasons are:

- **No release yet.** There is no release to compare with.
- **Drift.** For any base in `matrix.yml`, the live digest of its
  `linux/amd64` or `linux/arm64` manifest differs from the one in the
  record (the index digest alone moves when an architecture the project
  does not build is republished), or an image in the matrix has no entry
  there.
- **Fix available.** Trivy reports a fixable HIGH or CRITICAL
  vulnerability in any published `latest` image, on either architecture.

The dispatch job does not dispatch when today's release already exists,
or when a release run is queued or in progress: the running one picks up
whatever the watch saw. A base that cannot be resolved, an image that
cannot be scanned, a record that cannot be read or does not verify, or a
release run that cannot be listed fails the watch; silence is never "no
drift". A failed watch is a red run and nothing more; the owner reads
the Actions page or the schedule's next day covers it. When the latest
release is older than the schedule would allow, the schedule already
covers it.

## 10. Repository gates

Every pull request to `main` passes two workflows before it can merge.
The branch ruleset requires a pull request for every change and lists
them as required checks, strict, so the branch is current with `main`
when they pass; the rule and the checks come from the forge module with
the rest of the ruleset.

| Workflow | Source | What it proves |
| --- | --- | --- |
| `lint.yml` | HQ template, verbatim | every pre-commit hook including hadolint, gitleaks over tree and history, frozen hook revisions, `make test` |
| `ci.yml` | this repository | one job per architecture, native: resolve, build, Trivy gate, smoke suite under both contracts for every image; nothing pushed |

`watch.yml` and `release.yml` never run on a pull request. HQ's
`docker_bake.yml` template is not carried: it would rebuild every image
on amd64 on every pull request, a strict subset of `ci.yml` (section 14).
The Trivy configuration scan it carries runs inside `ci.yml` instead.

`ci.yml` reuses the release's steps 2 to 4 exactly, after resolving the
bases in its own job; the two workflows share them through a composite
action in `.github/actions/` so a gate cannot drift between the pull
request and the release. When only
documentation changed (section 8.10), the two `verify` jobs, plain jobs
named for their platform, skip at job level and their required checks
pass as skipped; a matrix skipped at job level or a workflow-level path
filter would leave them pending. The ignore list is why that can never
hide an input the build reads.

## 11. Local work

`make help` lists every target. Beyond HQ's Quality and Development
blocks:

| Target | Runs |
| --- | --- |
| `build` | resolve the bases, then bake every target for the host's architecture, loaded locally |
| `smoke` | `tests/smoke.sh` against `IMAGE=<ref>` |
| `scan` | Trivy against `IMAGE=<ref>` with the pipeline's settings |
| `digests` | print the live base digests the next build would use |

`make test` runs every suite in section 12; the smoke suite runs there
only when `OSNOVA_SMOKE_IMAGE` names an image, and reports itself skipped
otherwise, so a checkout without Docker still has a green gate for
everything that does not need one.

## 12. Tests

`tests/run.sh` and `tests/lib/harness.sh` are HQ's shell templates
verbatim. One suite per concern:

| Suite | Pins |
| --- | --- |
| `tests/layout.sh` | the layout of section 5: every file and directory it names exists, the root hygiene files are present, `AGENTS.md` links `CLAUDE.md` |
| `tests/matrix.sh` | `matrix.yml` holds name, family and base tag only; every image has a bake target whose own `variable` block defaults to that base tag; every family a Dockerfile whose `ARG BASE_IMAGE` default is the family's newest base; two majors per distribution; names match the pattern |
| `tests/dockerfiles.sh` | the build contract of section 6.3 line by line, including the cache, documentation, locale and log stripping, the empty machine id, the `ARG`-only build environment and the exact final `ENV`; the masked set of 6.4 identical in both families and nothing beyond it; the static labels; no forbidden instruction; no instruction after the scratch copy but the ones 6.3 lists |
| `tests/workflows.sh` | every action pinned to a commit SHA with a version comment; the BuildKit and SBOM generator images pinned by digest; Trivy installed from `.github/trivy.sha256` and nowhere else; `persist-credentials: false` on every checkout the project writes; the permission table of section 8.9 and nothing wider; no push or pull request trigger on the release; release concurrency never cancels; the watch's scan job holds no write scope and only its dispatch job holds `actions: write`; every job has `timeout-minutes`; the build jobs are one per architecture on the pinned runners; the registry login in the build job happens inside the composite action after the boot and only in publish mode; the cosign flags, the verify after signing and before promote, the attestation step, the record signing; artifacts kept seven days; `ci.yml` carries the `changes` gate over the documentation set and the draft rule of 8.10, and no workflow path filter; the release build passes no cache; no `${{ }}` inside a `run:` block |
| `tests/ci_changes.sh` | `.github/ci_changes.sh`: the documentation set of 8.10, renames, a push, a draft, malformed input |
| `tests/tools.sh` | `resolve_bases.sh`, `release_notes.sh` and `retain.sh` against fake `docker` and `gh` binaries on a scratch `PATH`: output shape including the per-architecture digests, failure on an unresolvable base, a malformed matrix refused, the exact keep and delete sets of section 8.7 by age, floor and release list, including a shared child, a nested index and a signature, a client-error delete skipped and reported, and no delete after a failed listing |
| `tests/smoke.sh` | section 7.4, when `OSNOVA_SMOKE_IMAGE` is set |

Every suite sources the harness, ends with `t_finish`, touches nothing
outside a `mktemp -d` scratch, and uses synthetic values.

## 13. Claude layer

HQ's fleet skeleton: `.claude/settings.json` from the template with the
project's additions, a thin `CLAUDE.md` of three sections and at most
eighty lines, `AGENTS.md` linking it, no memory, no commands, no hooks.
The settings deny, beyond the fleet list, every form of publishing Claude
could reach: `docker push`, `docker buildx imagetools create`,
`cosign sign`, `gh workflow run`, `gh release`. Claude builds, scans and
boots images locally and never publishes one.

One project skill, `_osnova_development`: how a change to an image, the
matrix or the pipeline is made and proven, linking the how-tos rather
than restating them.

## 14. Deviations from HQ standards

Each is declared here, carries its rationale, and is proposed back to HQ
as an amendment so the fleet audit stops reporting it:

| HQ rule | osnova | Why | Amendment proposed |
| --- | --- | --- | --- |
| The final stage runs as a named non-root user | no `USER`; the image is an init | PID 1 must be root to run systemd; consumers add users | an exemption for init images, stated in the Dockerfile |
| Every workflow holds `contents: read` and pushes nothing | the release and watch workflows hold the scopes of 8.9 and 9 | a publishing repository publishes; scopes are per job and minimal | accepted in HQ SPEC 11.2 as the publishing shape (no pull request trigger, `contents: read` at the top, per-job `packages`, `id-token`, `attestations`, `contents: write`); still outside that set and reported by HQ's audit: `actions: read` and `issues: write` in the failure report, `actions: write` in the watch's dispatch job |
| Every base image pinned by digest in the tree | base tags in `matrix.yml`, digests resolved at build and recorded in the release | an unattended pipeline cannot commit pin bumps without a bot credential and a branch bypass, which security first refuses (ADR 0004) | the rule accepts a resolved-and-recorded digest where the release record is signed |
| The SPEC version is the repository version and a release bumps both | the SPEC version is its revision date and no release bumps it (section 17) | a release changes no interface, so the repository has no version but the date of each build | calendar versioning is accepted (HQ SPEC 14); the SPEC-version rule itself stands and this row remains |
| A `docker_bake` repository carries HQ's `workflow_docker_bake.yml` as `docker_bake.yml` | not carried; `ci.yml` is its superset on both architectures | the template would rebuild every image on every pull request for an answer `ci.yml` already gives (principle 9) | the rule accepts a project workflow that carries the template's steps, listed: hadolint, Trivy configuration scan, bake, image scan |
| Unpinned package rules are errors (hadolint DL3005, DL3008, DL3041) | ignored inline in both Dockerfiles with the reason beside them | the build exists to apply upstream fixes on a base whose digest is recorded; a pinned package version would hold the fix back | an exemption for base images that record the base digest |
| Trivy configuration findings are not ignored | `AVD-DS-0002` (no `USER`) is ignored for `images/*/Dockerfile` in `.trivyignore.yaml` with the statement beside it | the same exemption as the `USER` row above, where Trivy checks it | the same amendment |
| Runners pinned to one OS release | HQ's `lint.yml` runs on `ubuntu-latest` | the workflow is carried verbatim; `tests/workflows.sh` exempts it from this check; its downloads are now verified against `.github/tools.sha256` | declined in HQ: a pinned runner label rots with no bump mechanism |

Everything else in HQ's docker, shell, git, GitHub Actions and
documentation standards applies unchanged. The amendments are proposed
in `.dev/hq_amendments.md` until HQ carries them.

## 15. Invariants

Binding; each is enforced by the named check on every commit or every run.

| Invariant | Check |
| --- | --- |
| No emulation: every build and test on its native architecture | `tests/workflows.sh` refuses `qemu`, `DOCKER_DEFAULT_PLATFORM` and a foreign platform on a runner |
| Every action pinned to a commit SHA with its version in a comment | `tests/workflows.sh`; HQ's lint workflow verifies the hook revisions the same way |
| No write scope outside the table of 8.9 and 9 | `tests/workflows.sh` |
| The release never runs on push or pull request | `tests/workflows.sh` |
| The bake file and the matrix agree, one target per image | `tests/matrix.sh` |
| Two majors per distribution | `tests/matrix.sh` |
| Both Dockerfiles follow section 6.3 and mask the same set | `tests/dockerfiles.sh` |
| No secret, key or credential in the tree or its history | gitleaks and `detect-private-key` in pre-commit and CI |
| A clean image boots `running` under both contracts on both architectures, with a fresh machine id | `tests/smoke.sh` in `ci.yml` and `release.yml` |
| Nothing publishes with a fixable HIGH or CRITICAL vulnerability | the Trivy step before any push |
| No registry login exists before the image is scanned and booted | `tests/workflows.sh`: no login step in the build job; the composite logs in after the boot, in publish mode only |
| The pushed image is the scanned image | the config digest assertion in the composite action |
| Every signature the pipeline makes is verified by the pipeline before `latest` moves | `tests/workflows.sh` holds the cosign flags and both verify steps |
| A dated tag is never rebuilt, and deleted only by retention under section 8.7 | the release refuses an existing tag; `tests/tools.sh` pins the keep set of `retain.sh` |
| Retention never deletes a manifest a kept index references | `tests/tools.sh` with a shared child, a nested index and a signature in the fixture |
| The pull request and release gates are the same steps | the shared composite action; `tests/workflows.sh` refuses an inline copy |
| Every job times out; builds are one job per architecture on pinned runners; the image gate's verify jobs skip at job level on a documentation-only change; the release builds uncached | `tests/workflows.sh` |
| The schedules are re-enabled on every watch run | `tests/workflows.sh` holds the enable step in the dispatch job |
| HQ templates match byte for byte | HQ's `check_templates.sh` and `check_conventions.sh`, run by the lead before every commit and by the fleet audit |

## 16. Documentation

Lean Diátaxis, HQ's pattern:

- `docs/SPEC.md`: this file, source of truth, carries the rationale.
- `docs/security.md`: the threat model of section 4 in operating detail,
  the run-contract exposure, the forge controls the repository relies on.
- `docs/adr/`: `0001_native_builds_no_emulation`,
  `0002_reduced_run_contract`, `0003_unattended_dated_releases`,
  `0004_digests_recorded_not_committed`. An ADR records the options
  considered; the decision itself is in this file.
- `docs/how_to/`: `use_the_images` (Docker, Molecule, Podman, the apt
  cache note, pinning), `verify_a_release`, `add_a_distro`,
  `run_a_release` (manual dispatch, reading a failure issue, recovery).
- `docs/reference/`: `images` (matrix, baseline, masked units, labels),
  `tags` (scheme, registry paths, retention), `pipeline` (every workflow,
  trigger, permission and action), `makefile_targets`.
- `README.md` is the entry map with the pull command, the run contract and
  the verification command on the first screen.
- `CHANGELOG.md` follows Keep a Changelog for changes to the repository:
  every user-visible change lands under `[Unreleased]` in the pull
  request that makes it. The lead moves those entries under the dated
  heading of the first release that shipped them, `## [YYYY.MM.DD]`, the
  image tag of section 8.2, in the next change to the tree. The GitHub
  releases list every image release, with notes generated from the record
  (section 14); the changelog lists what changed in the images and the
  pipeline between them.

No tutorials. A page that duplicates another is cut to a link.

## 17. Versioning and release

Image releases are calendar-versioned dated builds (section 8.2): the git
tag is `vYYYY.MM.DD`, the image tag `YYYY.MM.DD`, `latest` moves last
(section 8.3), retention follows section 8.7, and every release is
unattended (section 8.1). This file's version is its revision date
(section 2) and no release bumps it: a base image has no interface with
breaking changes, so the only version that means anything to a consumer
is the date of the build. HQ's rule that the SPEC version is the
repository version is deviated from under section 14.
