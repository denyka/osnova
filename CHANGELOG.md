# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the versioning scheme is the one `docs/SPEC.md` states.

## [Unreleased]

## [2026.10.21] - 2026-10-21

### Added

- The six-image matrix and the family Dockerfiles for AlmaLinux, Debian and Ubuntu.
- The bake file as the one build definition, local and CI.
- The base resolver, the release record and the retention tools.
- The smoke suite and the static suites.
- The shared build action and the `ci.yml`, `release.yml` and `watch.yml` workflows.
- The documentation set and the Claude layer.
- A `changes` job in `ci.yml` that skips `verify` at job level on a documentation-only change, in place of a workflow path filter.
- Images: the smoke suite asserts a fresh machine id per container, different between two containers, and no `ubuntu` user.
- Pipeline: a `prepare` job that resolves the bases once, with their per-architecture digests, and refuses an existing dated tag.
- Pipeline: a GitHub artifact attestation on every published index, and cosign verification of every signature right after signing and again before `latest` moves.
- Pipeline: `record.json` signed as a blob into `record.json.sigstore.json` and released immutably; the watch verifies it before trusting it.
- Pipeline: OCI annotations on every index, so the registry page shows title, description, source, revision and version.
- Pipeline: the registry login happens inside the shared action after the boot, in publish mode only.
- Pipeline: BuildKit, the SBOM generator and Trivy are pinned (images by digest, Trivy by `.github/trivy.sha256`), and runners are pinned to `ubuntu-24.04` and `ubuntu-24.04-arm`.
- Pipeline: the watch is two jobs, scan and dispatch, re-enables both scheduled workflows on every run and does not dispatch while a release run is queued or in progress.
- Pipeline: retention by age, ninety days with a floor of five releases, and deletion of orphaned dated tags no release names.
- Pipeline: `tools/retain.sh` takes the list of tags the GitHub releases name (`--released`), refuses a list that names no dated tag, and prints a summary line of kept, deleted and skipped versions.
- Pipeline: the `release-failed` issue names the failing steps beside the failed jobs, and the shared action logs out of the registry right after the config-digest assertion.
- Pipeline: `prepare` fixes the `created` timestamp once, so a re-run of the failed jobs reproduces byte-identical indexes.
- Pipeline: retention skips only the client errors 400, 404, 409, 410 and 422 and stops on 401, 403, 408, 429 and any other failed delete.
- Pipeline: artifacts that carry the digests and the record between jobs are kept seven days, the re-run window.
- Tests: the smoke suite prints one line on the Docker host, the container's status and its last log lines when a boot fails, the command's output when `python3` or `sudo` fails, and the caller, capabilities and shadow lookup state when `sudo` fails.
- Tests: `tests/layout.sh` asserts every path of SPEC 5; `tests/ci_changes.sh` covers the changes classifier; the workflow, tools and Dockerfile suites hold the rules of this release.

### Changed

- Images: `/etc/machine-id` is empty and `/var/lib/dbus/machine-id` removed, so systemd generates a fresh machine id on every first boot.
- Images: four maintenance timers are masked (`apt-daily.timer`, `apt-daily-upgrade.timer`, `dpkg-db-backup.timer`, `fstrim.timer`), twelve units in all, identical in every family.
- Images: the final stage sets `PATH` and `HOME` and nothing else; build-time variables are `ARG`s of the build stage.
- Images: the `ubuntu` user (uid 1000) is removed from the Ubuntu images.
- Images: locale catalogues are stripped, and every `copyright` file under `/usr/share/doc` is kept.
- Pipeline: cosign signs in the legacy tag form with `--new-bundle-format=false --use-signing-config=false`; cosign 3 verifies it unchanged.
- Pipeline: Trivy runs once per image as JSON and fails only on findings with a fix; the Trivy action is gone, Trivy is downloaded and checked against `.github/trivy.sha256`.
- Pipeline: the exemption file is `.trivyignore.yaml`, scoped to the Dockerfiles, replacing `.trivyignore`.
- Pipeline: a delete GHCR refuses with a client error is reported and skipped, except the transient 408 and 429, which stop the run.
- Pipeline: retention keeps every dated tag younger than ninety days and the five newest named by a release, in place of the five newest alone.
- Pipeline: `promote` verifies the signed index before it moves `latest`; each job states its own permissions.
- Documentation: the run, verify and tag pages follow SPEC revision 2026-10-20.
- Documentation: the pull-request rule and the required checks come from the forge module with the rest of the ruleset; the owner's hand-set list is immutable releases, private vulnerability reporting and the package settings (SPEC revision 2026-10-21).
- Run contract: the documented form adds `--security-opt apparmor=unconfined`; Docker's default AppArmor profile denies every mount and systemd mounts `/run` at boot, so the contract did not boot on a Debian or Ubuntu host. The README, the how-to, the security page, ADR 0002 and the smoke suite carry it (SPEC revision 2026-10-21).

### Fixed

- Pipeline: the push by digest clears the bake file's tag per target and gives the output the untagged name; buildx refuses to push a tagged ref by digest, which failed the first release run in `build` after every image had been scanned and booted.
- Images: the `el` family sets `/etc/shadow` to mode 0600, so `sudo` works on a host whose AppArmor confines `unix_chkpwd`, as Ubuntu 24.04 and the gate's runners do; pam_unix reads the shadow entry through that helper since its CVE-2024-10041 fix and the profile cannot read a 0000 file (SPEC revision 2026-10-21).
- Pipeline: `lint.yml` installs hadolint, pinned and verified against `.github/tools.sha256`, where a Dockerfile exists; the hadolint hook failed every pull request for want of the binary (SPEC revision 2026-10-21).
- Pipeline: the verify checks are two plain jobs named for their platform; a matrix job skipped on a documentation-only pull request never expanded, so its required checks stayed pending and the pull request could not merge (SPEC revision 2026-10-21).
- Pipeline: a failed publish leaves signed, verified dated tags and no `latest`; its orphans are deleted by retention instead of lingering.
- Pipeline: an unreachable registry or an unreadable record fails the watch instead of reading as no drift.
- Pipeline: the watch compares the per-architecture base digests, so an architecture the project does not build no longer triggers a release.
- Documentation: the stale statement that `latest` moves in the publish job, and the `scan` row of the Makefile reference, now match the code.
