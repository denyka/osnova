# Security

The threat model of [SPEC 4](SPEC.md) in operating detail: where each
control lives, what the run contract exposes, and which settings the owner
enables by hand.

## Threat model

| Asset | Threat | Control | Where it lives |
| --- | --- | --- | --- |
| A published image | A consumer pulls something other than what the pipeline built | Keyless cosign signature on every index, bound to the release workflow identity and verified by the pipeline before `latest` moves; a GitHub artifact attestation on every index; SBOM and SLSA provenance per architecture; the record signed as a blob on an immutable release; digest table in the notes | `publish`, `release` and `promote` jobs of `.github/workflows/release.yml`; push step of `.github/actions/build_and_verify/action.yml`; `tools/release_notes.sh` |
| The build input | A compromised or stale upstream base | Base resolved to its index digest and per-architecture digests, upstream patches applied at build, Trivy gate before any push, daily watch | `tools/resolve_bases.sh`; Trivy step of the composite action; `.github/workflows/watch.yml` |
| The pipeline | A third-party action or tool runs code it did not yesterday | Actions pinned to a commit SHA with a version comment; BuildKit and SBOM generator images pinned by digest; Trivy checked against a sha256 pinned in the tree; `persist-credentials: false` on the project's checkouts; per-job permissions; the third-party actions kept to the minimum | `tests/workflows.sh`; `.github/trivy.sha256` |
| The publish path | Someone other than the pipeline publishes under the project's name | Only `release.yml` holds package write scope; the registry login happens only after the image has been scanned and booted, immediately before the push, and is logged out right after the config-digest assertion (the job token itself exists for the whole job: see the accepted exposures); the pushed image is asserted to be the scanned one by config digest; the signature identity names that workflow; no long-lived registry credential | `permissions:` blocks of `release.yml`; the composite action; [verify a release](how_to/verify_a_release.md) |
| The repository | A secret or a credential enters the tree | The only credential is the job-scoped `GITHUB_TOKEN`; gitleaks and private-key detection over tree and history; ignore rules refuse files named like secrets | `.pre-commit-config.yaml`; `lint.yml` |
| The default branch | A change merges without the gate | Branch ruleset, a pull request for every change and the required checks (see below) | The forge module in HQ, applied by the owner |
| The consumer's host | The run contract gives the container more than it needs | The documented contract is the least that boots systemd; the privileged form is documented only for Molecule | [The run contract exposure](#the-run-contract-exposure) |

## The run contract exposure

The documented contract is `--cgroupns=host`, the cgroup mount read-write,
`--cap-add SYS_ADMIN` and `--security-opt apparmor=unconfined`
([SPEC 7.1](SPEC.md), [ADR 0002](adr/0002_reduced_run_contract.md)).

| Setting | What the container can do |
| --- | --- |
| Host cgroup namespace and `/sys/fs/cgroup` read-write | Read and write the host's cgroup hierarchy: see every cgroup, move processes between them, change limits |
| `SYS_ADMIN` | The one added capability: mount, namespace and cgroup operations that Docker's default set withholds |
| `apparmor=unconfined` | No AppArmor confinement: the mount, file and signal rules of Docker's default profile no longer apply; what the capability set allows is allowed. A host without AppArmor ignores the option |
| Still in force | Default seccomp profile; no host devices |

`--privileged` adds on top of that every capability, every host device,
and no seccomp confinement. Container root is then roughly host
root. It is documented only because Molecule's docker driver needs it.

The images run as root and carry `sudo`. They are for trusted development
machines and CI runners, never a shared or production host.

## Accepted exposures

[SPEC 4.2](SPEC.md) lists them; the ones a consumer or the owner meets are:

- Unattended releases publish images no human reviewed. The gates, the
  signature and the record are the review; a gate failure publishes nothing
  and opens an issue.
- Retention deletes a dated tag older than ninety days once five newer
  releases exist, so an old pin stops resolving. Serving unfixed
  vulnerabilities indefinitely is the worse exposure. Mirror an image to
  keep it ([tags](reference/tags.md)).
- The smoke suite boots the fresh image, upstream content included, under
  `--privileged` on the runner that then pushes it. A privileged container
  is roughly host root on the runner: it can reach the BuildKit daemon and
  read the memory of the runner process, which holds the job's
  `GITHUB_TOKEN` with `packages: write` for the whole job, whether or not a
  registry login has happened. The login placement keeps the credential out
  of the Docker configuration a container would read first; it does not
  remove the token from the runner. The pipeline asserts that the pushed
  image's config digest is the scanned one's; a tampered BuildKit cache that
  kept the config intact would pass. The exposure needs a compromised
  official upstream base image, in which case every consumer of that base is
  already compromised, and is accepted; the signed record and the signature
  identity still show what this pipeline pushed.
- A release is one set: the build jobs fail fast and nothing publishes until
  every image passed. One distribution whose mirror lacks the fix for a
  fixable finding blocks the other five until upstream catches up; the
  watch re-dispatches once a day, each run commenting on the open issue.
- GitHub disables the schedules of a public repository after sixty days
  without activity. The watch re-enables both scheduled workflows on every
  run; a disabled watch is re-enabled by the owner
  ([run a release](how_to/run_a_release.md)).
- A publish that fails part way leaves the dated tags created so far, each
  signed and verified before the next was made, at most one of them
  unsigned, and no release naming them. They are never `latest`, and
  retention deletes them.
- Root needs no password for `sudo`: stock behaviour, not a change the
  project makes.

## Supply chain

| Step | What it does | Where |
| --- | --- | --- |
| Resolve | Each base tag becomes `<tag>@sha256:<digest>`, with its per-architecture digests; an unresolvable base fails the run | `tools/resolve_bases.sh` |
| Build | Uncached, so the upstream patches apply; digest recorded in labels | `docker-bake.hcl`, `images/*/Dockerfile` |
| Trivy gate | Fixable HIGH and CRITICAL findings fail before any push; unfixed ones are reported | Trivy step of the composite action |
| Push | Login after the boot only, so the token is out of the Docker configuration until then, SBOM and provenance `mode=max`, config digest asserted equal to the scanned image's, logout | composite action, publish mode |
| Signature and attestation | Keyless cosign on the index digest, logged in Rekor and verified at once; a GitHub artifact attestation | `publish` job |
| Record | `record.json` on the immutable GitHub release, signed as a blob: commit, run, base and image digests | `release` job, `tools/release_notes.sh` |
| Promotion | The signature is verified again before `latest` moves | `promote` job |

`latest` moves only after the release exists, and only to the digests the
record carries ([pipeline](reference/pipeline.md)).

## What a compromised upstream base can and cannot do

The gates bound the damage:

- A fixable HIGH or CRITICAL finding in a base blocks publication.
- An unfixable finding is reported and does not block: no patch exists to
  apply.
- A malicious base that carries no known finding passes every gate. That is
  why the record exists: the base digest of every release is kept, so an
  audit can name exactly which upstream bytes an image was built from.

## Forge controls the owner enables

Repository settings are the owner's ([SPEC 14](SPEC.md)). The forge module
in HQ carries the ruleset; the owner enables the rest by hand until it
does. The repository relies on:

- A branch ruleset on `main`: linear history, signed commits, no force
  push, no deletion.
- A pull-request rule on that ruleset with zero required approvals, so
  every change goes through the gate.
- Required checks `pre-commit + make test` (`lint.yml`),
  `verify (linux/amd64)` and `verify (linux/arm64)` (`ci.yml`): the job
  names, as GitHub lists them. The two `verify` jobs are plain jobs, not
  a matrix, so each skips at job level on a documentation-only change
  under its required name and passes as skipped
  ([run a release](how_to/run_a_release.md#required-checks-and-path-filters)).
- Immutable releases, so a release and its signed record cannot change.
- Secret scanning with push protection.
- Private vulnerability reporting, which [SECURITY](../SECURITY.md) names as
  the channel. The owner enables it; this repository does not assume it.
- No collaborators. Adding one changes the threat model first.

## Reporting

See [SECURITY](../SECURITY.md).
