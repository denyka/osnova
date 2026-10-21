# Pipeline

Four workflows and one composite action ([SPEC 8 to 10](../SPEC.md)). Every
job has `timeout-minutes`. Every action is pinned to a commit SHA with its
version in a comment; the versions are listed here. Runners are pinned to
one OS release: `ubuntu-24.04` for `linux/amd64`, `ubuntu-24.04-arm` for
`linux/arm64`.

## Actions used

| Action | Version | Used by |
| --- | --- | --- |
| `actions/checkout` | v7.0.1 | every workflow |
| `actions/setup-python` | v7.0.0 | `lint.yml` |
| `terraform-linters/setup-tflint` | v6.3.2 | `lint.yml` (only where `.tf` files exist) |
| `docker/setup-buildx-action` | v4.4.1 | `ci.yml`, `release.yml`, `watch.yml` |
| `docker/login-action` | v4.6.0 | the composite action, `release.yml`, `watch.yml` |
| `docker/bake-action` | v7.5.0 | the composite action |
| `sigstore/cosign-installer` | v4.1.2 | `release.yml`, `watch.yml` |
| `actions/upload-artifact` | v7.0.2 | `release.yml` |
| `actions/download-artifact` | v8.0.2 | `release.yml` |
| `actions/attest-build-provenance` | v4.2.2 | `release.yml` |

The third-party set is Docker's three actions and `sigstore/cosign-installer`
([SPEC 8.9](../SPEC.md)); the artifact pair and `attest-build-provenance`
are GitHub's own. There is no Trivy action. Trivy is downloaded by a shell
step at the version in `.github/trivy.sha256` and verified against the
sha256 for the runner's architecture pinned in the same file; that file is
the one place its version lives.

The images the actions run are pinned as well: `setup-buildx-action` is
given the BuildKit image by tag and digest, and the SBOM step names its
generator image by tag and digest, because BuildKit writes the provenance.

## lint.yml

HQ's lint workflow, verbatim. It installs hadolint, pinned and verified
against `.github/tools.sha256`, where a Dockerfile exists, because the
hadolint hook shells out to a binary the runner does not ship.

| Item | Value |
| --- | --- |
| Trigger | push to `main`, pull request to `main` |
| Permissions | `contents: read` |
| Job `pre-commit` | 20 minutes, check name `pre-commit + make test`: installs hadolint and the pinned pre-commit from `.github/requirements.txt`, runs every hook on every file (including `make test`), then gitleaks over history and tree |
| Concurrency | cancels a superseded run of the same ref |

## ci.yml

The image gate ([SPEC 10](../SPEC.md)).

| Item | Value |
| --- | --- |
| Trigger | push to `main`, pull request to `main` (opened, synchronize, reopened, ready for review) |
| Path filter | none: the workflow runs on every pull request, because a required check from a path-filtered workflow stays pending |
| Documentation set | `**/*.md`, `docs/**`, `LICENSE`, `.github/ISSUE_TEMPLATE/**`, `.github/pull_request_template.md`, `.github/CODEOWNERS`, `.gitlab/**`; a change touching only these skips `verify` ([SPEC 8.10](../SPEC.md)) |
| Drafts | a draft pull request skips `verify`; lint alone runs |
| Permissions | `contents: read` |
| Concurrency | cancels a superseded run of the same pull request; a push to `main` (which seeds the cache) is never cancelled |

| Job | Timeout | Condition | What it does |
| --- | --- | --- | --- |
| `changes` | 5 | always | Checks out with full history and runs `.github/ci_changes.sh`, which classifies `git diff --name-only --no-renames base...head` against the documentation set and outputs `code` and `draft`. Any event but a pull request outputs `code=true`, `draft=false` |
| `verify (linux/amd64)`, `verify (linux/arm64)` | 60 | not a draft and `code` is true | One plain job per architecture on its native pinned runner, never a matrix: a skipped matrix never expands its names. Skipped at job level on a draft or a documentation-only change; the required checks then pass as skipped |

Steps of `verify`:

1. Checkout without persisted credentials.
2. Set up buildx with the pinned BuildKit image.
3. Resolve the bases with `tools/resolve_bases.sh`.
4. The composite action in verify mode with the cache on: the GitHub
   Actions layer cache through `docker/bake-action`, one cache scope per
   target and architecture.
5. `trivy config --ignorefile .trivyignore.yaml --exit-code 1 --severity HIGH,CRITICAL images`,
   once, on amd64; Trivy does not load the YAML ignore file by itself, so the
   flag names it. The file waives `AVD-DS-0002` (no `USER`) for the two Dockerfiles that state
   `# init image: PID 1 runs as root` above their final stage: an init image runs as root by design
   (HQ SPEC 14, the upstream-tracking class of [SPEC 1](../SPEC.md)).

## release.yml

The unattended release ([SPEC 8](../SPEC.md)).

| Item | Value |
| --- | --- |
| Trigger | schedule `17 4 1 * *` (monthly), `workflow_dispatch`. No push, no pull request |
| Concurrency | group `release`, never cancels |
| Top-level permissions | `contents: read` |

Every job below repeats `contents: read` in its own block, because a
job-level block replaces the top-level one, and adds only what it lists.

| Job | Timeout | Permissions beyond `contents: read` | What it does |
| --- | --- | --- | --- |
| `prepare` | 10 | `packages: read` | Runs on `main` only. Computes the UTC tag, fixes the run's `created` timestamp once (both architectures, the labels and the index annotations carry it, so a re-run reproduces byte-identical indexes), resolves the bases and their per-architecture digests once with `tools/resolve_bases.sh --json`, fails if `v<tag>` exists or if the registry already has the dated tag (an absent package reads as absent; any other registry failure fails the run) |
| `build`, per architecture | 60 | `packages: write` | Runs the composite action in publish mode with no cache; uploads the pushed digests as an artifact |
| `publish` | 20 | `packages: write`, `id-token: write`, `attestations: write` | Per image: merges the two digests into one index tagged with the date, annotated; signs it with cosign keyless in the legacy tag form (`--new-bundle-format=false --use-signing-config=false`) and verifies the signature at once. A failure stops the loop. Then attests every index digest with `attest-build-provenance`, writes `record.json` with `tools/release_notes.sh record` and uploads it as an artifact |
| `release` | 10 | `contents: write`, `id-token: write` | `cosign sign-blob` of `record.json` into `record.json.sigstore.json`, `cosign verify-blob` of it, then the git tag on the built commit and the GitHub release with both files and the notes from `tools/release_notes.sh` |
| `promote` | 10 | `packages: write` | Per image: verifies the signature on the recorded index digest, points `latest` at it and checks that it resolved there |
| `retain` | 15 | `packages: write` | Lists the releases (`gh release list`) into the released-tags file, fails if it is empty, then runs `tools/retain.sh --keep 5 --max-age-days 90 --released` per image. Retention skips only the client errors 400, 404, 409, 410 and 422 and stops on 401, 403, 408, 429 and anything else ([tags](tags.md)) |
| `report a failed release` | 5 | `actions: read`, `issues: write` | Runs on any failure; reads the run's jobs for the failing steps |

The order is `prepare`, `build`, `publish`, `release`, `promote`, `retain`.
`latest` moves last, in `promote`, so a run that fails earlier never moves
it. `prepare` refuses a dated tag that exists as a git tag or on the
registry ([SPEC 8.2](../SPEC.md)); recovery is "Re-run failed jobs", which
keeps `prepare`'s outputs and the artifacts. The digests and the record
travel between jobs as artifacts kept seven days, the window in which a
re-run still has its inputs ([run a release](../how_to/run_a_release.md)).

### The failure issue

The job opens one issue labelled `release-failed` or comments on the open
one. The body names the failed jobs, states what that implies for the
registry and links the run. The failing steps are read from the run's jobs
and named beside the jobs ([SPEC 8.6](../SPEC.md)).

| Failed job | Stated effect |
| --- | --- |
| `prepare` or `build` | Nothing was published; the previous release still serves |
| `publish` | Dated tags created so far exist, each signed and verified before the next, at most one unsigned; no release names them; `latest` did not move; re-run the failed jobs |
| `release` | Signed dated tags exist and no release; `latest` did not move; re-run the failed jobs |
| `promote` | The release exists; `latest` may have moved for some images, each to a verified index; re-run the failed jobs |
| `retain` | Everything was published; retention stopped before it finished |

## watch.yml

The daily drift and CVE watch ([SPEC 9](../SPEC.md)). It never commits and
never publishes.

| Item | Value |
| --- | --- |
| Trigger | schedule `23 5 * * *`, `workflow_dispatch` |
| Top-level permissions | `contents: read` |

| Job | Permissions beyond `contents: read` | What it does |
| --- | --- | --- |
| `scan` | `packages: read` | Downloads the latest release's `record.json` and bundle and verifies the record with the release identity; resolves the live bases; scans the `latest` of every image the record lists, on both architectures, with `--exit-code 3` (0 clean, 3 a finding, anything else fails the run) |
| `dispatch` | `actions: write` | Holds `actions: write` beyond `contents: read` and runs whether or not `scan` succeeded (`!cancelled()`). It re-enables `release.yml` and `watch.yml` first, so the keepalive never depends on the scan, and dispatches `release.yml` on `main` only when `scan` succeeded with a reason, unless today's release exists or a release run is queued or in progress |

| Dispatch reason | Meaning |
| --- | --- |
| No release yet | there is no release to compare with |
| Drift | the live `linux/amd64` or `linux/arm64` manifest digest of a base differs from the record, or an image is missing from the record |
| Fix available | a fixable HIGH or CRITICAL finding in any published `latest` |

A base that cannot be resolved, an image that cannot be scanned, a record
that cannot be read or does not verify, or a release run that cannot be
listed fails the watch.

## The composite action

`.github/actions/build_and_verify/action.yml`, shared by `ci.yml` and
`release.yml` so the gate cannot drift between them.

| Input | Default | Meaning |
| --- | --- | --- |
| `platform` | required | `linux/amd64` or `linux/arm64`, the runner's own |
| `bases` | required | the `BASE_<NAME>=<tag>@<digest>` lines `resolve_bases.sh` printed |
| `mode` | required | `verify` (load, scan, boot) or `publish` (the same, then push by digest) |
| `cache` | `false` | `true` for the GitHub Actions layer cache (the gate), never for the release |
| `registry` | `ghcr.io/denyka/osnova` | image path prefix |
| `registry_username` | empty | publish mode: the registry user the push logs in as |
| `registry_password` | empty | publish mode: the registry token; no login happens before the push |
| `created` | the build time | the run's fixed RFC 3339 `created` timestamp, from `prepare` in the release |
| `source_date_epoch` | `created`'s epoch | the epoch both bakes use, so they write the same image config |

| Output | Meaning |
| --- | --- |
| `digests` | publish mode: JSON object of image name to pushed digest |

Steps: install Trivy from `.github/trivy.sha256`; export the validated
bases and the bake variables; compute the bake overrides (the gate's cache
scopes and, in publish mode, per target the bake file's tag cleared and the
untagged name for the push, because buildx refuses to push a tagged ref by
digest); bake every image loaded (no cache in publish mode); per image,
Trivy once as JSON on the
local image only, failing on a finding with a fix and printing the rest,
then `tests/smoke.sh`. In publish mode only, after the boot: log in to the
registry, push by digest with an SBOM and `provenance: mode=max`, collect
the pushed digests, assert that the pushed config digest equals the loaded
image's, and log out (`docker logout ghcr.io`) right after that assertion,
so the registry login ends with the push and not at the end of the job.
