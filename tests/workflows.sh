#!/usr/bin/env bash
# Every workflow and the composite action (SPEC 8.9, 8.10, 9, 10, 12, 15): pins,
# permissions, triggers, timeouts, the job shapes, the shared steps.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
cd "${T_ROOT}" || exit 1

wfs=(.github/workflows/*.yml)
action=.github/actions/build_and_verify/action.yml
ci=.github/workflows/ci.yml
rel=.github/workflows/release.yml
w=.github/workflows/watch.yml
pin=.github/trivy.sha256
t_assert_file "${action}"
t_assert_file "${ci}"
t_assert_file "${rel}"
t_assert_file "${w}"
t_assert_file "${pin}"
# all: every workflow plus the action, HQ's lint workflow included (universal rules:
# pins, no emulation, no privileged trigger, no expression inside a run block).
all=("${wfs[@]}" "${action}")
# own: the project's files. lint.yml is HQ's but for the hadolint step (SPEC 14), so it is exempt
# from the permitted third-party set, persist-credentials, the pinned runners, the
# BuildKit pin, artifact retention and the Trivy pin rules.
own=("${action}")
for f in "${wfs[@]}"; do [[ "${f}" == .github/workflows/lint.yml ]] || own+=("${f}"); done

# job FILE NAME prints the job's block, its header line included, with every
# backslash-continued shell line joined to the next
job() {
    awk -v j="$2" '$0 ~ "^  "j":$"{p=1;print;next} p&&/^  [A-Za-z0-9_-]+:$/{p=0} p{print}' "$1" |
        awk '{ if (buf != "") { sub(/^ +/, ""); $0 = buf " " $0 } if ($0 ~ /\\$/) { sub(/ *\\$/, ""); buf = $0; next } buf = ""; print }'
}
job_has() {
    if job "$1" "$2" | grep -qE -- "$3"; then t_ok "$1: job $2 matches /$3/"; else t_fail "$1: job $2 does not match /$3/"; fi
}
job_lacks() {
    if job "$1" "$2" | grep -qE -- "$3"; then t_fail "$1: job $2 must not match /$3/"; else t_ok "$1: job $2 clean of /$3/"; fi
}
# jobs FILE prints the job names in order
jobs_of() { awk '/^jobs:/{j=1;next} j&&/^[^ #]/{j=0} j&&/^  [A-Za-z0-9_-]+:$/{sub(/^  /,"");sub(/:$/,"");print}' "$1" | paste -sd' ' -; }
# jobperm FILE JOB prints the job's permissions block as "key: value" pairs in order
jobperm() { job "$1" "$2" | awk '/^    permissions:$/{p=1;next} p&&/^      [a-z-]+: /{print $1" "$2;next} p{p=0}' | paste -sd' ' -; }
# step FILE PATTERN prints the step (from its "- name:" line) whose block matches PATTERN
step() { awk -v pat="$2" '/^ *- name: /{ if (hit) { print buf; exit } buf=$0; next } { buf=buf "\n" $0; if ($0 ~ pat) hit=1 } END{ if (hit) print buf }' "$1"; }
# line FILE PATTERN prints the first line number matching PATTERN, or 0
line() { local n; n="$(grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1)"; printf '%s\n' "${n:-0}"; }

# pins, all files: every uses is a 40-hex SHA with a version comment, or a local action
for f in "${all[@]}"; do
    while IFS= read -r l; do
        if [[ "${l}" =~ uses:\ [^@]+@[0-9a-f]{40}\ #\ v[0-9] ]]; then t_ok "${f}: pinned: ${l#*uses: }"
        elif [[ "${l}" =~ uses:\ \./ ]]; then t_ok "${f}: local action"
        else t_fail "${f}: unpinned: ${l#*uses: }"; fi
    done < <(grep -E '^\s+(- )?uses:' "${f}")
    t_assert_not_grep '(qemu|DOCKER_DEFAULT_PLATFORM|setup-qemu)' "${f}"
    t_assert_not_grep '^\s*(pull_request_target|workflow_run):' "${f}"
    # values reach a run block through env or with, never as an expression (SPEC 12)
    exprs="$(awk 'function ind(s) { match(s, /^ */); return RLENGTH }
        inrun { if ($0 ~ /^[[:space:]]*$/) next; if (ind($0) > rind) { if (index($0, "${{")) print NR; next } inrun = 0 }
        /^[[:space:]]*(- )?run: / { body = $0; sub(/^[[:space:]]*(- )?run: /, "", body)
            if (body ~ /^[|>]/) { inrun = 1; rind = ind($0); if ($0 ~ /^[[:space:]]*- /) rind += 2 }
            else if (index(body, "${{")) print NR }' "${f}" | paste -sd, -)"
    t_assert_eq "" "${exprs}" "${f}: no \${{ }} inside a run block"
done
# the permitted third-party set, credential-free checkouts, pinned runners, the
# BuildKit pin, retention and the Trivy pin, own files only
for f in "${own[@]}"; do
    while IFS= read -r l; do
        if [[ "${l}" =~ uses:\ ([^@]+)@ ]]; then
            a="${BASH_REMATCH[1]}"
            case "${a}" in
                actions/checkout | actions/upload-artifact | actions/download-artifact | actions/attest-build-provenance | docker/setup-buildx-action | docker/login-action | docker/bake-action | sigstore/cosign-installer) t_ok "${f}: ${a} permitted" ;;
                *) t_fail "${f}: action outside the permitted set: ${a}" ;;
            esac
        fi
    done < <(grep -E '^\s+(- )?uses:' "${f}")
    t_assert_eq "$(grep -cE 'actions/checkout@' "${f}")" "$(grep -cE 'persist-credentials: false' "${f}")" "${f}: every checkout keeps no credentials"
    t_assert_not_grep 'ubuntu-latest' "${f}"
    # the BuildKit image every builder runs is pinned by tag and digest (SPEC 8.9)
    t_assert_eq "$(grep -cE 'uses: docker/setup-buildx-action@' "${f}")" "$(grep -cE '^ +driver-opts: image=moby/buildkit:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$' "${f}")" "${f}: every setup-buildx-action pins the BuildKit image"
    # every artifact is kept seven days, the re-run window (SPEC 8.10)
    t_assert_eq "$(grep -cE 'uses: actions/upload-artifact@' "${f}")" "$(grep -cE '^ +retention-days: 7$' "${f}")" "${f}: every upload is kept seven days"
    t_assert_not_grep 'retention-days: ([0-68-9]|[0-9]{2,})' "${f}"
    # Trivy's version and sha256 live in the pin file alone; no checksum page is fetched
    t_assert_not_grep 'checksums\.txt' "${f}"
    t_assert_not_grep 'trivy_version|TRIVY_VERSION: ' "${f}"
    t_assert_not_grep 'trivy-action' "${f}"
    # any file that downloads or installs Trivy takes it from the pin file
    if grep -qE 'aquasecurity/trivy|install.*trivy' "${f}"; then
        t_assert_grep '^ +\. \.github/trivy\.sha256$' "${f}"
        t_assert_grep 'sha256sum --check --strict' "${f}"
        t_assert_grep 'releases/download/v\$\{TRIVY_VERSION\}/' "${f}"
    fi
done
# the two files that install Trivy source the pin file, unconditionally
for f in "${action}" "${w}"; do
    t_assert_grep '^ +\. \.github/trivy\.sha256$' "${f}"
done
# the Trivy pin file: three sourceable lines
t_assert_grep '^TRIVY_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "${pin}"
t_assert_grep '^TRIVY_SHA256_AMD64=[0-9a-f]{64}$' "${pin}"
t_assert_grep '^TRIVY_SHA256_ARM64=[0-9a-f]{64}$' "${pin}"
t_assert_eq 3 "$(grep -cvE '^(#|$)' "${pin}")" "trivy.sha256: three assignments and nothing else"
# every workflow: every job has timeout-minutes, a top-level permissions block
for f in "${wfs[@]}"; do
    if awk '/^jobs:/{j=1;next} j&&/^[^ #]/{j=0} j&&/^  [A-Za-z0-9_-]+:/{ if(n&&!t) bad=1; n++; t=0 } j&&/^    timeout-minutes: [0-9]+$/{t=1} END{ if(n&&!t) bad=1; exit !(n&&!bad)}' "${f}"; then t_ok "${f}: every job has timeout-minutes"; else t_fail "${f}: a job lacks timeout-minutes"; fi
    t_assert_grep '^permissions:$' "${f}"
done
# top-level permissions: every workflow is exactly contents: read
top() { awk '/^permissions:/{p=1;next} p&&/^([^ ]|$)/{p=0} p{print}' "$1" | sed 's/^  //' | paste -sd' ' -; }
t_assert_eq "contents: read" "$(top .github/workflows/lint.yml)" "lint: contents: read"
# the hadolint step of SPEC 14: where a Dockerfile exists, the x86_64 binary verified against tools.sha256
t_assert_grep "^        if: hashFiles\('\*\*/Dockerfile'\) != ''$" .github/workflows/lint.yml
t_assert_grep 'hadolint-Linux-x86_64' .github/workflows/lint.yml
job_has .github/workflows/lint.yml pre-commit 'sha256sum --check --strict --ignore-missing "\$\{GITHUB_WORKSPACE\}/\.github/tools\.sha256"'
t_assert_grep '^[0-9a-f]{64}  hadolint-Linux-x86_64$' .github/tools.sha256
t_assert_eq "contents: read" "$(top "${ci}")" "ci: contents: read"
t_assert_eq "contents: read" "$(top "${rel}")" "release: contents: read at the top"
t_assert_eq "contents: read" "$(top "${w}")" "watch: contents: read at the top"
# the pinned runners (SPEC 8.3): ubuntu-24.04 and ubuntu-24.04-arm only
for f in "${ci}" "${rel}" "${w}"; do
    t_assert_grep 'runs-on: ubuntu-24\.04$' "${f}"
    t_assert_eq "" "$(grep -E '(runs-on|runner):' "${f}" | grep -vE '(runs-on|runner): (ubuntu-24\.04|ubuntu-24\.04-arm|\$\{\{ matrix\.runner \}\})$')" "${f}: every runner is pinned"
done

# ci.yml: triggers, the changes gate, drafts, cache, two jobs on native runners, the composite
t_assert_grep '^    types: \[opened, synchronize, reopened, ready_for_review\]$' "${ci}"
t_assert_not_grep 'paths-ignore:' "${ci}"
t_assert_not_grep '^\s+paths:' "${ci}"
t_assert_grep '^  changes:$' "${ci}"
t_assert_eq 5 "$(awk '/^  changes:$/{c=1;next} c&&/^  [A-Za-z0-9_-]+:/{c=0} c&&/^    timeout-minutes: [0-9]+$/{print $2}' "${ci}")" "ci: the changes job has a 5 minute timeout"
t_assert_grep 'run: bash \.github/ci_changes\.sh$' "${ci}"
t_assert_grep '^          PR_BASE_SHA: \$\{\{ github\.event\.pull_request\.base\.sha \}\}$' "${ci}"
t_assert_grep '^          PR_HEAD_SHA: \$\{\{ github\.event\.pull_request\.head\.sha \}\}$' "${ci}"
t_assert_grep '^          PR_DRAFT: \$\{\{ github\.event\.pull_request\.draft \}\}$' "${ci}"
t_assert_grep '^    needs: \[changes\]$' "${ci}"
t_assert_grep "^    if: needs\\.changes\\.outputs\\.draft != 'true' && needs\\.changes\\.outputs\\.code == 'true'$" "${ci}"
t_assert_not_grep 'github.event_name != .pull_request. \|\| !github.event.pull_request.draft' "${ci}"
t_assert_grep "^  cancel-in-progress: \\\$\\{\\{ github.event_name == 'pull_request' \\}\\}$" "${ci}"
t_assert_not_grep '^  cancel-in-progress: true$' "${ci}"
# SPEC 8.10: two plain verify jobs named for their platform, never a matrix (a skipped matrix never expands
# its names, so the required contexts would stay pending)
t_assert_not_grep '^\s+matrix:' "${ci}"
t_assert_grep '^  verify_amd64:$' "${ci}"; t_assert_grep '^    name: verify \(linux/amd64\)$' "${ci}"
t_assert_grep '^  verify_arm64:$' "${ci}"; t_assert_grep '^    name: verify \(linux/arm64\)$' "${ci}"
t_assert_eq 2 "$(grep -cE "^    if: needs\.changes\.outputs\.draft != 'true' && needs\.changes\.outputs\.code == 'true'$" "${ci}")" "ci: both verify jobs skip at job level on a draft or a documentation-only change"
job_has "${ci}" verify_amd64 'runs-on: ubuntu-24\.04$'; job_has "${ci}" verify_amd64 'platform: linux/amd64$'; job_has "${ci}" verify_amd64 'trivy config '
job_has "${ci}" verify_arm64 'runs-on: ubuntu-24\.04-arm$'; job_has "${ci}" verify_arm64 'platform: linux/arm64$'
t_assert_eq 1 "$(grep -c 'trivy config ' "${ci}")" "ci: the configuration scan runs once"
t_assert_grep 'uses: \./\.github/actions/build_and_verify' "${ci}"
t_assert_grep "mode: verify" "${ci}"
t_assert_grep "cache: 'true'" "${ci}"
# the gate never receives a registry credential
t_assert_not_grep 'registry_(username|password)' "${ci}"
t_assert_not_grep 'docker/login-action' "${ci}"
t_assert_not_grep '^\s+permissions:' "${ci}"
t_assert_not_grep 'push: true|push-by-digest' "${ci}"
# Trivy does not auto-load the YAML ignore file; the scan names it
t_assert_grep 'trivy config --ignorefile \.trivyignore\.yaml --exit-code 1 --severity HIGH,CRITICAL images$' "${ci}"

# the composite action: trivy pinned and verified, the loop, both modes
t_assert_grep "resolve_bases.sh --list" "${action}"
t_assert_grep 'bash tests/smoke.sh' "${action}"
t_assert_grep 'TRIVY_SHA256_AMD64' "${action}"
t_assert_grep 'TRIVY_SHA256_ARM64' "${action}"
# one JSON scan per image; any finding with a fix version fails, the rest are summarised
# (the patterns below start with dashes and are passed without a leading --: the harness takes no options)
t_assert_grep 'trivy image --image-src docker --scanners vuln --severity HIGH,CRITICAL --format json --output ' "${action}"
t_assert_not_grep '--ignore-unfixed' "${action}"
t_assert_grep 'FixedVersion' "${action}"
t_assert_grep 'unfixed' "${action}"
# the local image only: a missing image never falls back to the registry
t_assert_grep 'trivy image --image-src docker' "${action}"
t_assert_eq 1 "$(grep -cE 'no-cache:' "${action}")" "action: exactly one no-cache key"
t_assert_grep "no-cache: \\$\\{\\{ inputs.mode == 'publish' \\}\\}" "${action}"
t_assert_eq 2 "$(grep -cE 'uses: docker/bake-action@' "${action}")" "action: both bakes go through bake-action"
# push by digest (SPEC 8.3 step 5): per target, the tag cleared and an untagged name, computed
# in the cfg step; a wildcard output would carry the tag and buildx refuses a tagged ref by digest
t_assert_not_grep '\*\.output=' "${action}"
t_assert_grep "printf '%s\.tags=" "${action}"
t_assert_grep 'out="type=image,name=\$\{REGISTRY\}/\$\{name\}"$' "${action}"
t_assert_grep '%s\.output=%s,push-by-digest=true,name-canonical=true,push=true' "${action}"
t_assert_grep '^        set: \$\{\{ steps\.cfg\.outputs\.push \}\}$' "${action}"
t_assert_grep 'cache-to=type=gha,scope=gate-%s-%s,mode=max' "${action}"
t_assert_not_grep '\*\.cache-' "${action}"
t_assert_grep 'startswith\("sha256:"\)' "${action}"
t_assert_grep 'push-by-digest=true' "${action}"
t_assert_grep 'provenance: mode=max' "${action}"
t_assert_grep 'cache-from=type=gha,scope=gate-%s-%s' "${action}"
# the SBOM generator is pinned by tag and digest (SPEC 8.9)
t_assert_grep '^        sbom: generator=docker/buildkit-syft-scanner:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$' "${action}"
# both bakes share one CREATED and its SOURCE_DATE_EPOCH, so the image configs agree
t_assert_grep "printf 'SOURCE_DATE_EPOCH=%s" "${action}"
t_assert_grep "printf 'CREATED=%s" "${action}"
# the pushed image is the scanned one, by config digest (SPEC 8.3 step 5)
t_assert_grep "docker image inspect \"\\\$\\{REGISTRY\\}/\\\$\\{name\\}:latest\" --format '\\{\\{\\.Id\\}\\}'" "${action}"
t_assert_grep '\.config\.digest' "${action}"
t_assert_grep 'is not the scanned image' "${action}"
# the credential is removed right after the assert, not at the end of the job
logout_step="$(step "${action}" 'docker logout ghcr.io')"
if grep -qE "^      if: inputs\\.mode == 'publish'$" <<<"${logout_step}"; then t_ok "action: the logout runs in publish mode"; else t_fail "action: no publish-mode logout step"; fi
l_assert="$(line "${action}" '^    - name: Assert the pushed image is the scanned image$')"
l_logout="$(line "${action}" '^        docker logout ghcr\.io$')"
if [[ "${l_assert}" -gt 0 && "${l_logout}" -gt "${l_assert}" ]]; then t_ok "action: logout after the config-digest assert"; else t_fail "action: logout missing or before the assert (assert ${l_assert}, logout ${l_logout})"; fi
# a fixable finding closes its log group before failing
t_assert_grep "^            printf '::endgroup::\\\\n'$" "${action}"
# the registry credential: inputs empty by default, one login in publish mode only,
# after the scan and boot and before the push (SPEC 4.1, 8.3 step 5)
t_assert_grep '^  registry_username:$' "${action}"
t_assert_grep '^  registry_password:$' "${action}"
t_assert_eq 4 "$(grep -cE "^    default: ''$" "${action}")" "action: the created and registry inputs default to empty"
t_assert_eq 1 "$(grep -cE 'uses: docker/login-action@' "${action}")" "action: one registry login"
login_step="$(step "${action}" 'docker/login-action@')"
if grep -qE "^      if: inputs\\.mode == 'publish'$" <<<"${login_step}"; then t_ok "action: the login runs in publish mode only"; else t_fail "action: the login is not guarded by publish mode"; fi
if grep -qE 'username: \$\{\{ inputs\.registry_username \}\}' <<<"${login_step}" && grep -qE 'password: \$\{\{ inputs\.registry_password \}\}' <<<"${login_step}"; then t_ok "action: the login takes the registry inputs"; else t_fail "action: the login does not take the registry inputs"; fi
l_boot="$(line "${action}" '^    - name: Scan and boot every image$')"
l_login="$(line "${action}" 'uses: docker/login-action@')"
l_push="$(line "${action}" '^    - name: Push by digest')"
if [[ "${l_boot}" -gt 0 && "${l_login}" -gt "${l_boot}" && "${l_push}" -gt "${l_login}" ]]; then t_ok "action: login after the scan and boot, before the push"; else t_fail "action: login out of order (boot ${l_boot}, login ${l_login}, push ${l_push})"; fi
# no workflow inlines the verify steps: trivy image scans live in the action only, except the
# watch, which scans the published images (SPEC 9)
for f in "${wfs[@]}"; do
    [[ "${f}" == "${w}" ]] || t_assert_not_grep 'trivy image' "${f}"
done

# release.yml: triggers and concurrency
t_assert_grep '^  schedule:$' "${rel}"
t_assert_grep "^    - cron: '[0-9]+ [0-9]+ 1 \* \*'$" "${rel}"
t_assert_grep '^  workflow_dispatch:' "${rel}"
t_assert_not_grep '^  (push|pull_request):' "${rel}"
t_assert_grep '^  cancel-in-progress: false$' "${rel}"
# job permissions exactly as SPEC 8.9, each block starting from contents
t_assert_eq "prepare build publish release promote retain failed" "$(jobs_of "${rel}")" "release: the job set"
t_assert_eq "contents: read packages: read" "$(jobperm "${rel}" prepare)" "release: prepare reads the registry only"
t_assert_eq "contents: read packages: write" "$(jobperm "${rel}" build)" "release: build scope"
t_assert_eq "contents: read packages: write id-token: write attestations: write" "$(jobperm "${rel}" publish)" "release: publish scope"
t_assert_eq "contents: write id-token: write" "$(jobperm "${rel}" release)" "release: release scope"
t_assert_eq "contents: read packages: write" "$(jobperm "${rel}" promote)" "release: promote scope"
t_assert_eq "contents: read packages: write" "$(jobperm "${rel}" retain)" "release: retain scope"
t_assert_eq "contents: read actions: read issues: write" "$(jobperm "${rel}" failed)" "release: failure scope"
t_assert_eq 7 "$(grep -cE '^    permissions:$' "${rel}")" "release: seven jobs carry a permissions block"
for f in "${rel}" "${w}"; do
    t_assert_not_grep '^    permissions: ' "${f}"
    t_assert_not_grep 'write-all' "${f}"
done
t_assert_grep "if: github.ref == 'refs/heads/main'" "${rel}"
# prepare: one resolve, the tag checks; tag_exists answers 0 or 1, anything else fails
job_has "${rel}" prepare 'tools/resolve_bases.sh --json'
t_assert_eq 1 "$(grep -cE 'resolve_bases\.sh --json' "${rel}")" "release: the bases are resolved once"
job_has "${rel}" prepare 'release_notes.sh tag_exists --tag "\$\{tag\}" \|\| rc=\$\?'
job_has "${rel}" prepare 'cannot check the git tags'
# a package that does not exist yet reads as absent through the Packages API; then
# only "no such tag" reads as absent and any other failure refuses the run
job_has "${rel}" prepare 'gh api "/users/denyka/packages/container/osnova%2F\$\{name\}"'
job_has "${rel}" prepare "grep -q 'HTTP 404' err.txt"
job_has "${rel}" prepare 'ref="\$\{REGISTRY\}/\$\{name\}:\$\{TAG\}"'
job_has "${rel}" prepare 'imagetools inspect "\$\{ref\}" >/dev/null 2>err.txt'
job_has "${rel}" prepare 'already exists on the registry'
job_has "${rel}" prepare "grep -qE ': not found\\$\|MANIFEST_UNKNOWN' err.txt"
t_assert_not_grep 'grep -qiE' "${rel}"
t_assert_not_grep 'NAME_UNKNOWN|denied' "${rel}"
job_has "${rel}" prepare 'cannot check'
# build: no registry credential in the job; the composite logs in after the boot
job_lacks "${rel}" build 'docker/login-action'
job_has "${rel}" build "mode: publish"
job_has "${rel}" build "cache: 'false'"
job_has "${rel}" build 'registry_username: \$\{\{ github\.actor \}\}'
job_has "${rel}" build 'registry_password: \$\{\{ secrets\.GITHUB_TOKEN \}\}'
# one created time per run, from prepare, so a re-run of failed jobs rebuilds the same
# labels, configs and indexes and a dated tag never moves (SPEC 8.3 step 1)
job_has "${rel}" prepare '^      created: \$\{\{ steps\.tag\.outputs\.created \}\}$'
job_has "${rel}" prepare '^      source_date_epoch: \$\{\{ steps\.tag\.outputs\.source_date_epoch \}\}$'
job_has "${rel}" build '^          created: \$\{\{ needs\.prepare\.outputs\.created \}\}$'
job_has "${rel}" build '^          source_date_epoch: \$\{\{ needs\.prepare\.outputs\.source_date_epoch \}\}$'
job_has "${rel}" publish '^          CREATED: \$\{\{ needs\.prepare\.outputs\.created \}\}$'
job_has "${rel}" publish 'image\.created=\$\{CREATED\}"'
job_lacks "${rel}" publish 'date -u'
t_assert_grep '^  created:$' "${action}"
t_assert_grep '^  source_date_epoch:$' "${action}"
t_assert_grep 'INPUT_CREATED' "${action}"
t_assert_grep 'INPUT_EPOCH' "${action}"
# the base line shape matches the resolver's: a repository like foo2 is accepted
t_assert_grep "re='\^BASE_\[A-Z0-9\]\+=\[a-z0-9\.-\]\+:\[a-z0-9\.-\]\+@sha256:\[0-9a-f\]\{64\}\\$'" "${action}"
t_assert_grep 'classic image store' "${action}"
t_assert_grep 'release_notes.sh record' "${rel}"
t_assert_grep 'release_notes.sh notes' "${rel}"
# publish: annotate, sign in the legacy tag form, verify at once, attest (SPEC 8.3 step 6)
for k in title description source url revision created version; do
    job_has "${rel}" publish "--annotation \"index:org\\.opencontainers\\.image\\.${k}="
done
job_has "${rel}" publish 'images/\$\{family\}/Dockerfile'
job_has "${rel}" publish 'cosign sign --yes --new-bundle-format=false --use-signing-config=false "\$\{image\}@\$\{index\}"$'
l_sign="$(job "${rel}" publish | grep -nE 'cosign sign ' | head -n 1 | cut -d: -f1)"
l_pverify="$(job "${rel}" publish | grep -nE 'cosign verify ' | head -n 1 | cut -d: -f1)"
if [[ -n "${l_sign}" && -n "${l_pverify}" && "${l_sign}" -lt "${l_pverify}" ]]; then t_ok "release: publish verifies after signing"; else t_fail "release: publish does not verify after signing"; fi
t_assert_eq 1 "$(grep -cE 'cosign sign ' "${rel}")" "release: one cosign sign"
job_has "${rel}" publish 'cosign verify --certificate-oidc-issuer "\$\{COSIGN_ISSUER\}" --certificate-identity-regexp "\$\{COSIGN_IDENTITY\}"'
job_has "${rel}" publish '"\$\{image\}@\$\{index\}" >/dev/null$'
job_has "${rel}" publish 'uses: actions/attest-build-provenance@'
attest_step="$(step "${rel}" 'actions/attest-build-provenance@')"
if grep -qE '^          push-to-registry: false$' <<<"${attest_step}"; then t_ok "release: the attestation is not pushed to the registry"; else t_fail "release: the attestation lacks push-to-registry: false"; fi
if grep -qE '^          subject-checksums: ' <<<"${attest_step}"; then t_ok "release: one attestation over every index"; else t_fail "release: the attestation lacks subject-checksums"; fi
job_has "${rel}" publish "printf '%s  %s\\\\n' \"\\\$\\{index#sha256:\\}\" \"\\\$\\{image\\}\" >> subjects\\.txt"
# the SPEC 8.5 identity, once per workflow that verifies
for f in "${rel}" "${w}"; do
    t_assert_grep "^  COSIGN_IDENTITY: '\\^https://github\\\\\\.com/denyka/osnova/\\\\\\.github/workflows/release\\\\\\.yml@refs/heads/main\\\$'$" "${f}"
    t_assert_grep '^  COSIGN_ISSUER: https://token\.actions\.githubusercontent\.com$' "${f}"
done
# release: sign the record as a blob, verify it, release both files
job_has "${rel}" release 'uses: sigstore/cosign-installer@'
job_has "${rel}" release 'cosign sign-blob --yes --bundle record.json.sigstore.json record.json$'
job_has "${rel}" release 'cosign verify-blob --certificate-oidc-issuer "\$\{COSIGN_ISSUER\}" --certificate-identity-regexp "\$\{COSIGN_IDENTITY\}"'
job_has "${rel}" release 'gh release create "v\$\{TAG\}" --target "\$\{GITHUB_SHA\}" --title "v\$\{TAG\}" --notes-file notes.md record.json record.json.sigstore.json$'
# promote: verify the signed index before latest moves, then check where it landed
job_has "${rel}" promote 'uses: sigstore/cosign-installer@'
job_has "${rel}" promote 'cosign verify --certificate-oidc-issuer "\$\{COSIGN_ISSUER\}" --certificate-identity-regexp "\$\{COSIGN_IDENTITY\}"'
l_verify="$(job "${rel}" promote | grep -nE 'cosign verify ' | head -n 1 | cut -d: -f1)"
l_latest="$(job "${rel}" promote | grep -nE 'imagetools create --tag "\$\{image\}:latest"' | head -n 1 | cut -d: -f1)"
if [[ -n "${l_verify}" && -n "${l_latest}" && "${l_verify}" -lt "${l_latest}" ]]; then t_ok "release: promote verifies before latest moves"; else t_fail "release: promote does not verify before latest moves"; fi
job_has "${rel}" promote 'landed="\$\(docker buildx imagetools inspect "\$\{image\}:latest"'
job_has "${rel}" promote '\[\[ "\$\{landed\}" == "\$\{digest\}" \]\]'
# retain: the released tags, the SPEC 8.7 flags
job_has "${rel}" retain "gh release list --repo \"\\\$\\{REPO\\}\" --limit 1000 --json tagName --jq '\\.\\[\\]\\.tagName' \\| sed 's/\\^v//' > released\\.txt"
job_has "${rel}" retain 'tools/retain.sh --owner denyka --package "osnova/\$\{name\}" --keep 5 --max-age-days 90 --released released.txt$'
t_assert_eq "[promote]" "$(awk '/^  retain:$/{p=1;next} p&&/^    needs:/{print $2; exit}' "${rel}")" "release: retain needs promote"
# the failure issue states SPEC 8.6
t_assert_grep 'if: failure()' "${rel}"
t_assert_grep 'release-failed' "${rel}"
job_has "${rel}" failed 'nothing was published; the registry still serves the previous release and latest did not move'
job_has "${rel}" failed 'the dated tags created so far remain, each signed and verified before the next was made,"$'
job_has "${rel}" failed 'at most one of them unsigned; no release names them and latest did not move'
job_has "${rel}" failed 'signed dated tags remain and no release names them; latest did not move'
job_has "${rel}" failed 'latest may have moved for some images, each to a verified index'
job_has "${rel}" failed 'everything was published; retention stopped'
job_has "${rel}" failed 're-run the failed jobs to complete the release from where it stopped'
# the issue names the failing step (SPEC 8.6)
job_has "${rel}" failed 'gh api "repos/\$\{REPO\}/actions/runs/\$\{RUN_ID\}/jobs" --paginate'
job_has "${rel}" failed "select\\(\\.conclusion==\"failure\"\\) \\| \\.name as \\\$j \\| \\.steps\\[\\] \\| select\\(\\.conclusion==\"failure\"\\)"
job_has "${rel}" failed 'failing steps: '
t_assert_not_grep 'published nothing' "${rel}"
# the index create: one dated, one latest, never mixed
t_assert_grep '^  promote:$' "${rel}"
t_assert_eq 1 "$(grep -E 'imagetools create' "${rel}" | grep -c 'latest')" "release: only the promote create carries latest"
t_assert_eq 1 "$(grep -cE 'imagetools create.*TAG' "${rel}")" "release: one dated create"
t_assert_eq 0 "$(grep -E 'imagetools create.*TAG' "${rel}" | grep -c 'latest')" "release: the dated create never carries latest"

# watch.yml: two jobs (SPEC 9); scan reads, dispatch alone holds actions: write
t_assert_grep '^  group: watch$' "${w}"
t_assert_grep '^  cancel-in-progress: false$' "${w}"
t_assert_grep '^  schedule:$' "${w}"
t_assert_grep "^    - cron: '[0-9]+ [0-9]+ \* \* \*'$" "${w}"
t_assert_eq "scan dispatch" "$(jobs_of "${w}")" "watch: the scan and dispatch jobs"
t_assert_eq "contents: read packages: read" "$(jobperm "${w}" scan)" "watch: scan scope"
t_assert_eq "contents: read actions: write" "$(jobperm "${w}" dispatch)" "watch: dispatch scope"
t_assert_eq 2 "$(grep -cE '^    permissions:$' "${w}")" "watch: both jobs carry a permissions block"
job_lacks "${w}" scan '^      [a-z-]+: write$'
t_assert_not_grep 'packages: write|contents: write|id-token' "${w}"
t_assert_eq "[scan]" "$(awk '/^  dispatch:$/{p=1;next} p&&/^    needs:/{print $2; exit}' "${w}")" "watch: dispatch needs scan"
job_has "${w}" scan '^      reason: \$\{\{ steps\.check\.outputs\.reason \}\}$'
# scan: read login, cosign, trivy, the signed record, drift per platform, the published images
job_has "${w}" scan 'uses: docker/login-action@'
job_has "${w}" scan 'uses: sigstore/cosign-installer@'
job_has "${w}" scan 'gh api "repos/\$\{REPO\}/releases/latest"'
job_has "${w}" scan 'no release yet'
job_has "${w}" scan 'gh release download "\$\{latest\}" --repo "\$\{REPO\}" --pattern record.json --pattern record.json.sigstore.json'
job_has "${w}" scan 'has no record.json.sigstore.json'
job_has "${w}" scan 'cosign verify-blob --certificate-oidc-issuer "\$\{COSIGN_ISSUER\}" --certificate-identity-regexp "\$\{COSIGN_IDENTITY\}"'
job_has "${w}" scan '--bundle record.json.sigstore.json record.json'
job_has "${w}" scan 'tools/resolve_bases.sh --json > live.json'
job_has "${w}" scan "base_platforms\\[\\\$p\\]"
job_has "${w}" scan 'linux/amd64'
job_has "${w}" scan 'linux/arm64'
job_has "${w}" scan "jq -r '\\.images\\[\\]\\.name' record.json"
# a finding is exit code 3; 1 is also Trivy's fatal error, never read as a finding
job_has "${w}" scan '--exit-code 3 --quiet'
t_assert_not_grep '--exit-code 1' "${w}"
t_assert_grep '^                  3\) found=true ;;$' "${w}"
job_has "${w}" scan 'cannot scan'
job_has "${w}" scan 'for platform in linux/amd64 linux/arm64'
job_lacks "${w}" scan 'gh workflow'
# dispatch: re-enable both schedules on every run, then dispatch unless today's release
# exists or a release run is queued or in progress
job_has "${w}" dispatch '^          gh workflow enable release\.yml --repo "\$\{REPO\}"$'
job_has "${w}" dispatch '^          gh workflow enable watch\.yml --repo "\$\{REPO\}"$'
l_enable="$(job "${w}" dispatch | grep -nE 'gh workflow enable' | head -n 1 | cut -d: -f1)"
l_run="$(job "${w}" dispatch | grep -nE 'gh workflow run' | head -n 1 | cut -d: -f1)"
if [[ -n "${l_enable}" && -n "${l_run}" && "${l_enable}" -lt "${l_run}" ]]; then t_ok "watch: the schedules are re-enabled first"; else t_fail "watch: the enable step does not come first"; fi
if step "${w}" 'gh workflow enable release' | grep -qE '^ +if: '; then t_fail "watch: the enable step is conditional"; else t_ok "watch: the enable step is unconditional"; fi
# the job runs after every scan that was not cancelled; the dispatch needs a successful scan
job_has "${w}" dispatch '^    if: \$\{\{ !cancelled\(\) \}\}$'
job_has "${w}" dispatch "^        if: needs\\.scan\\.result == 'success' && needs\\.scan\\.outputs\\.reason != ''$"
job_has "${w}" dispatch 'gh release view "\$\{today\}" --repo "\$\{REPO\}"'
job_has "${w}" dispatch 'for status in in_progress queued'
job_has "${w}" dispatch 'gh run list --repo "\$\{REPO\}" --workflow release\.yml --status "\$\{status\}"'
job_has "${w}" dispatch 'gh workflow run release\.yml --repo "\$\{REPO\}" --ref main$'
t_assert_eq 1 "$(grep -cE 'gh workflow run ' "${w}")" "watch: one dispatch"
t_assert_not_grep 'git (commit|push)' "${w}"

# every platform sits with its native runner in the release matrix; ci's two plain jobs are pinned above
pairs="$(awk '/^ *- platform: /{p=$3;next} p&&/^ *runner: /{print p"="$2; p=""}' "${rel}" | paste -sd' ' -)"
t_assert_eq "linux/amd64=ubuntu-24.04 linux/arm64=ubuntu-24.04-arm" "${pairs}" "${rel}: platform and runner pairs"
t_finish
