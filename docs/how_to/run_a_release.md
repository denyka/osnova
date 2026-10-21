# Run a release

Releases are unattended: monthly, and on the watch's dispatch. The owner
runs one by hand when a change should not wait.

## Manual dispatch

```bash
gh workflow run release.yml --ref main
```

Only `main` publishes. A run from another branch skips every job and opens
no issue.

## Owner settings the pipeline relies on

The `main` ruleset comes from the forge module in HQ: linear history,
signed commits, no force push, no deletion, a pull-request rule with zero
required approvals, and the required checks `pre-commit + make test` (the
`lint` workflow), `verify (linux/amd64)` and `verify (linux/arm64)`
(`ci.yml`), strict. The owner sets the rest once, by hand, in the
repository and package settings ([SPEC 4.1 and 14](../SPEC.md)):

1. Immutable releases, so a published release and its `record.json` cannot
   be changed.
2. Private vulnerability reporting, which [SECURITY](../../SECURITY.md)
   names as the reporting channel. The owner enables it; nothing in the
   repository assumes it is on.
3. After the first publish, each of the six packages public
   (`osnova/almalinux9` to `osnova/ubuntu2604`, under the account's
   packages). A package created by a user-scoped push starts private.
4. Under each package's "Manage Actions access", the `osnova` repository
   with the Admin role. `retain` deletes package versions with the
   workflow's `GITHUB_TOKEN`, and a delete needs Admin.

Recommended, also the owner's: turn on CodeQL default setup for the
workflow files and run an OpenSSF Scorecard check on the repository; neither
is assumed by the pipeline. `step-security/harden-runner` is declined: it is
a third-party action outside the set of [SPEC 8.9](../SPEC.md).

On the first run, confirm in the `retain` log that the version listing
works with the workflow token, the call `tools/retain.sh` makes:
`gh api /users/denyka/packages/container/osnova%2F<name>/versions`. Then
confirm the signature form:

```bash
cosign tree ghcr.io/denyka/osnova/<name>:<date>
```

It must list the signature as a `sha256-<index digest>.sig` tag. That tag
is what retention keeps beside a kept index
([verify a release](verify_a_release.md)).

## What the run does

| Job | What it does |
| --- | --- |
| `prepare` | Computes the UTC dated tag, resolves the bases once, fails if the git tag exists or any image already has that dated tag on the registry |
| `build`, per architecture | Bakes uncached, scans with Trivy, boots the smoke suite, then logs in and pushes by digest with SBOM and provenance |
| `publish` | Per image: one index tagged with the date, annotated, signed, verified, attested |
| `release` | Signs `record.json`, creates the git tag and the immutable GitHub release with the record, its signature and the notes |
| `promote` | Verifies each recorded index, moves `latest` to it and checks that `latest` resolves there |
| `retain` | Applies the retention of [tags](../reference/tags.md) per image |

The jobs run in that order. A failure before `promote` never moves
`latest` ([pipeline](../reference/pipeline.md)).

## One release per day

The tag is the UTC date and is immutable ([SPEC 8.2](../SPEC.md)).
`prepare` fails when the git tag `v<date>` exists, which the `release` job
creates, and when any image already carries the dated tag on the registry,
which `publish` creates. A new run on the same day after a failure in
`publish` or later is therefore refused on purpose, and opens or comments
on the failure issue. A run that failed in `prepare` or `build` pushed no
dated tag, so a new run the same day can follow it.

## Recovery

"Re-run failed jobs" on the failed run completes it from where it stopped.
A re-run keeps `prepare`'s outputs and the uploaded artifacts, so the jobs
use the same dated tag, the same bases and the same digests. The artifacts
are kept seven days, which is the window for this; after it, or after a
failure in `prepare` or `build`, the next run publishes. A cause in the
code is fixed on `main` through a pull request first.

## Reading a `release-failed` issue

The issue names the failed jobs and their failing steps, states the
registry's state and links the run. It is the one time a release involves
the owner ([SPEC 8.6](../SPEC.md)).

| Failed job | Registry state |
| --- | --- |
| `prepare`, `build` | Nothing was published; the previous release serves and `latest` did not move |
| `publish` | Dated tags created so far exist, each signed and verified before the next was made, at most one of them unsigned; no release names them; `latest` did not move |
| `release` | Signed dated tags exist and no release; `latest` did not move |
| `promote` | The release exists; `latest` may have moved for some images, each to a verified index |
| `retain` | Everything is published and `latest` moved; retention stopped at a failed listing, an authorisation error or a failed delete |

A dated tag that no release names is an orphan; retention deletes it on a
later successful run.

## What retention deletes

Dated tags older than ninety days beyond the five newest that a release
names, the orphans of failed runs, and untagged versions and cosign
signatures that no kept index references. A version GHCR refuses to delete
because of its download count is reported and skipped. Git tags, GitHub
releases and `record.json` are never deleted ([tags](../reference/tags.md)).

## Re-enable a disabled schedule

GitHub disables the schedules of a public repository after sixty days
without activity. The watch re-enables `release.yml` and `watch.yml` on
every run, so this happens only if the watch itself was disabled. Check the
Actions page when no watch run appears for a few days, and enable it:

```bash
gh workflow enable watch.yml --repo denyka/osnova
gh workflow enable release.yml --repo denyka/osnova
```

Nothing in the repository can notice this state from inside
([SPEC 4.2](../SPEC.md)).

## Required checks and path filters

`ci.yml` runs on every pull request and every push to `main`, and carries
no path filter. Its `changes` job classifies the change, and the two
`verify` jobs, plain jobs named for their platform, skip at job level on a
documentation-only change, so the required checks `verify (linux/amd64)`
and `verify (linux/arm64)` pass as skipped and the pull request can merge.
A matrix job would not: skipped before expansion, it reports one check
under its unexpanded name and the required contexts stay pending. `pre-commit + make test` runs and passes on
every pull request; a draft runs it alone. A workflow skipped by a path
filter would leave its required checks pending.

## Risk

A release pulls twelve base images uncached from Docker Hub, six per
architecture. Unauthenticated runners can meet Docker Hub's rate limit
(HTTP 429), which fails the run and opens the issue. The owner decides any
mitigation.
