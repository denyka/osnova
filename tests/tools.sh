#!/usr/bin/env bash
# The tools against fake docker, gh and git on a scratch PATH: the strict
# matrix parser, the resolver JSON with per-architecture digests, the release
# record, the notes, the tag guard, and retention by age with a floor and a
# released list (SPEC 8.3 step 1, 8.4, 8.6, 8.7).
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
cd "${T_ROOT}" || exit 1

scratch="$(mktemp -d "${TMPDIR:-/tmp}/osnova.XXXXXX")"
# chained with the harness trap: remove the scratch, keep the failure guarantee
trap 'rm -rf "${scratch}"; [[ "${_T_FAILED}" -eq 0 ]] || exit 1' EXIT
mkdir -p "${scratch}/bin" "${scratch}/home"
export HOME="${scratch}/home" TMPDIR="${scratch}"
export PATH="${scratch}/bin:/usr/bin:/bin"
# the real git and jq stay reachable: link them
for real in git jq awk sed grep sort paste tr cut date mktemp head wc cat dirname; do
    p="$(command -v "${real}" 2>/dev/null || true)"; [[ -n "${p}" ]] && ln -sf "${p}" "${scratch}/bin/${real}"
done
log="${scratch}/calls.log"

# fake docker for the resolver, one registry read per call (each is logged):
#   `buildx imagetools inspect --format {{.Manifest.Digest}} <tag>` answers a digest derived from the tag
#   `buildx imagetools inspect --format {{json .Manifest}} <tag>` answers the index: that digest, an attestation
#   entry, the arm64 and amd64 manifests (digests derived from the tag length), unless the tag is named in
#   DOCKER_NOARM or DOCKER_NOAMD64; DOCKER_FAIL fails a tag
cat > "${scratch}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALLS_LOG}"
ref="${!#}"
if [[ "$*" == *"imagetools inspect"* ]]; then
    if [[ ",${DOCKER_FAIL:-}," == *",${ref},"* ]]; then printf 'ERROR: %s: not found\n' "${ref}" >&2; exit 1; fi
    digest="$(printf 'sha256:%064d' "${#ref}")"
    if [[ "$*" == *"json .Manifest"* ]]; then
        amd="$(printf 'sha256:%064d' $((${#ref} + 1000)))"; arm="$(printf 'sha256:%064d' $((${#ref} + 2000)))"
        manifests="$(jq -cn '[{digest: "sha256:att", platform: {os: "unknown", architecture: "unknown"}}]')"
        if [[ ",${DOCKER_NOARM:-}," != *",${ref},"* ]]; then
            manifests="$(jq -c --arg d "${arm}" '. + [{digest: $d, platform: {os: "linux", architecture: "arm64", variant: "v8"}}]' <<<"${manifests}")"
        fi
        if [[ ",${DOCKER_NOAMD64:-}," != *",${ref},"* ]]; then
            manifests="$(jq -c --arg d "${amd}" '. + [{digest: $d, platform: {os: "linux", architecture: "amd64"}}]' <<<"${manifests}")"
        fi
        jq -n --arg d "${DOCKER_BAD_DIGEST:-${digest}}" --argjson m "${manifests}" '{schemaVersion: 2, digest: $d, manifests: $m}'
        exit 0
    fi
    printf '%s\n' "${digest}"
    exit 0
fi
printf 'fake docker: unexpected: %s\n' "$*" >&2; exit 2
EOF
chmod +x "${scratch}/bin/docker"
export CALLS_LOG="${log}"

# --list reads the matrix with no network
: > "${log}"
list="$(bash tools/resolve_bases.sh --list)"
t_assert_eq "almalinux9 el almalinux:9-minimal" "$(printf '%s\n' "${list}" | head -1)" "--list: first line"
t_assert_eq 6 "$(printf '%s\n' "${list}" | wc -l | tr -d ' ')" "--list: six lines"
t_assert_eq "" "$(cat "${log}")" "--list: no docker call"

# default mode: one BASE_ line per image, digests from the fake
out="$(bash tools/resolve_bases.sh)"; rc=$?
t_assert_eq 0 "${rc}" "resolve: exit 0"
t_assert_eq "BASE_ALMALINUX9=almalinux:9-minimal@sha256:$(printf '%064d' 19)" "$(printf '%s\n' "${out}" | head -1)" "resolve: first line shape"
t_assert_eq 6 "$(printf '%s\n' "${out}" | grep -c '^BASE_[A-Z0-9]*=.*@sha256:[0-9a-f]\{64\}$')" "resolve: six well-formed lines"

# --json: the base digest and the digests of the amd64 and arm64 manifests of the base index
: > "${log}"
json="$(bash tools/resolve_bases.sh --json)"
d13="debian:13-slim"
t_assert_eq "debian13" "$(printf '%s' "${json}" | jq -r '.[3].name')" "--json: fourth entry is debian13"
t_assert_eq "sha256:$(printf '%064d' 14)" "$(printf '%s' "${json}" | jq -r '.[3].base_digest')" "--json: digest derived"
t_assert_eq "sha256:$(printf '%064d' $((${#d13} + 1000)))" "$(printf '%s' "${json}" | jq -r '.[3].platforms["linux/amd64"]')" "--json: amd64 manifest digest"
t_assert_eq "sha256:$(printf '%064d' $((${#d13} + 2000)))" "$(printf '%s' "${json}" | jq -r '.[3].platforms["linux/arm64"]')" "--json: arm64 manifest digest"
t_assert_eq "base,base_digest,family,name,platforms" "$(printf '%s' "${json}" | jq -r '.[0] | keys | join(",")')" "--json: entry keys"
t_assert_eq "linux/amd64,linux/arm64" "$(printf '%s' "${json}" | jq -r '.[0].platforms | keys | join(",")')" "--json: platform keys"
t_assert_eq 6 "$(printf '%s' "${json}" | jq 'length')" "--json: six entries"
# one registry read per base: six reads for six bases, not three each
t_assert_eq 6 "$(grep -c 'imagetools inspect' "${log}")" "--json: one registry read per base"
: > "${log}"
bash tools/resolve_bases.sh >/dev/null
t_assert_eq 6 "$(grep -c 'imagetools inspect' "${log}")" "default: one registry read per base"
# a base whose index lacks a platform fails the run and prints nothing
for var in DOCKER_NOARM DOCKER_NOAMD64; do
    out="$(env "${var}=ubuntu:26.04" bash tools/resolve_bases.sh --json 2>"${scratch}/err")"; rc=$?
    t_assert_eq "1:" "${rc}:${out}" "--json: ${var} fails, no output"
    if grep -q 'ubuntu:26.04' "${scratch}/err"; then t_ok "${var}: base named on stderr"; else t_fail "${var}: stderr does not name the base"; fi
done
# a failed read keeps its stderr visible and fails the run
out="$(DOCKER_FAIL=debian:12-slim bash tools/resolve_bases.sh --json 2>"${scratch}/err")"; rc=$?
t_assert_eq "1:" "${rc}:${out}" "--json: failed read fails, no output"
if grep -q 'not found' "${scratch}/err"; then t_ok "failed docker call: its stderr stays visible"; else t_fail "docker stderr hidden"; fi

# a base index whose own digest is not a digest fails the run
out="$(DOCKER_BAD_DIGEST=latest bash tools/resolve_bases.sh --json 2>/dev/null)"; rc=$?
t_assert_eq "1:" "${rc}:${out}" "--json: a non-digest index digest fails, no output"

# an unresolvable base fails the whole run and prints no line for it (Review Focus 1)
out="$(DOCKER_FAIL=ubuntu:26.04 bash tools/resolve_bases.sh 2>"${scratch}/err")"; rc=$?
t_assert_eq 1 "${rc}" "unresolvable base fails"
if grep -q 'ubuntu:26.04' "${scratch}/err"; then t_ok "unresolvable base named on stderr"; else t_fail "stderr does not name the base"; fi
if grep -q 'not found' "${scratch}/err"; then t_ok "unresolvable base: docker stderr visible"; else t_fail "unresolvable base: docker stderr hidden"; fi
if printf '%s' "${out}" | grep -q 'BASE_UBUNTU2604='; then t_fail "a line was printed for the unresolved base"; else t_ok "no line for the unresolved base"; fi
# a resolver answer that is not a digest is refused too
cp "${scratch}/bin/docker" "${scratch}/docker.real"
cat > "${scratch}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'latest\n'
EOF
out="$(bash tools/resolve_bases.sh 2>/dev/null)"; rc=$?
t_assert_eq 1 "${rc}" "a non-digest answer fails"
cp "${scratch}/docker.real" "${scratch}/bin/docker"

# an empty or missing matrix fails and prints nothing (SPEC 9)
mkdir -p "${scratch}/empty/tools"; cp tools/resolve_bases.sh "${scratch}/empty/tools/"; : > "${scratch}/empty/matrix.yml"
for mode in "" --json --list; do
    out="$(bash "${scratch}/empty/tools/resolve_bases.sh" ${mode} 2>/dev/null)"; rc=$?
    t_assert_eq "1:" "${rc}:${out}" "empty matrix (${mode:-default}): exit 1, no output"
done
rm "${scratch}/empty/matrix.yml"
out="$(bash "${scratch}/empty/tools/resolve_bases.sh" 2>/dev/null)"; rc=$?
t_assert_eq "1:" "${rc}:${out}" "missing matrix: exit 1, no output"

# a malformed matrix is refused naming the entry; nothing is inherited or dropped silently
mkdir -p "${scratch}/m/tools"; cp tools/resolve_bases.sh "${scratch}/m/tools/"
matrix_case() { # $1 label, $2 text stderr must contain; the matrix on stdin
    local label="$1" want="$2" rc mode
    cat > "${scratch}/m/matrix.yml"
    for mode in --list --json ""; do
        out="$(bash "${scratch}/m/tools/resolve_bases.sh" ${mode} 2>"${scratch}/err")"; rc=$?
        t_assert_eq "1:" "${rc}:${out}" "malformed matrix, ${label} (${mode:-default}): exit 1, no output"
    done
    if grep -qF -- "${want}" "${scratch}/err"; then t_ok "malformed matrix, ${label}: names ${want}"; else t_fail "malformed matrix, ${label}: stderr lacks ${want}: $(cat "${scratch}/err")"; fi
}
matrix_case "missing key" debian12 <<'M'
images:
  - name: almalinux9
    family: el
    base: almalinux:9-minimal
  - name: debian12
    family: deb
M
matrix_case "inherited family" debian13 <<'M'
images:
  - name: debian12
    family: deb
    base: debian:12-slim
  - name: debian13
    base: debian:13-slim
M
matrix_case "quoted scalar" debian12 <<'M'
images:
  - name: debian12
    family: deb
    base: "debian:12-slim"
M
matrix_case "quoted name" debian12 <<'M'
images:
  - name: "debian12"
    family: deb
    base: debian:12-slim
M
matrix_case "duplicate name" debian12 <<'M'
images:
  - name: debian12
    family: deb
    base: debian:12-slim
  - name: debian12
    family: deb
    base: debian:13-slim
M
matrix_case "duplicate key" debian12 <<'M'
images:
  - name: debian12
    family: deb
    family: el
    base: debian:12-slim
M
matrix_case "extra key" debian12 <<'M'
images:
  - name: debian12
    family: deb
    base: debian:12-slim
    arch: amd64
M
matrix_case "flow style" '{name: debian12' <<'M'
images:
  - {name: debian12, family: deb, base: debian:12-slim}
M
matrix_case "bad name" Debian12 <<'M'
images:
  - name: Debian12
    family: deb
    base: debian:12-slim
M
matrix_case "name without major" debian <<'M'
images:
  - name: debian
    family: deb
    base: debian:12-slim
M
matrix_case "bad family" debian12 <<'M'
images:
  - name: debian12
    family: deb1
    base: debian:12-slim
M
matrix_case "base without tag" debian12 <<'M'
images:
  - name: debian12
    family: deb
    base: debian
M
# a document-start marker, comments and blank lines are fine
cat > "${scratch}/m/matrix.yml" <<'M'
---
# comment

images:
  - name: debian12
    family: deb
    base: debian:12-slim

  # between entries
  - name: ubuntu2404
    family: deb
    base: ubuntu:24.04
M
t_assert_eq "debian12 deb debian:12-slim,ubuntu2404 deb ubuntu:24.04" "$(bash "${scratch}/m/tools/resolve_bases.sh" --list | paste -sd, -)" "a well-formed matrix with comments parses"

# release record and notes
h64() { printf '%064d' "$1"; }
printf '%s' "${json}" > "${scratch}/bases.json"
jq -n --arg a "sha256:$(h64 1)" --arg b "sha256:$(h64 2)" --arg c "sha256:$(h64 3)" --arg d "sha256:$(h64 4)" --arg e "sha256:$(h64 5)" --arg f "sha256:$(h64 6)" \
    '{almalinux9:$a,almalinux10:$b,debian12:$c,debian13:$d,ubuntu2404:$e,ubuntu2604:$f}' > "${scratch}/digests.json"
rec() { bash tools/release_notes.sh record --tag 2026.10.19 --commit 0123abc --run https://github.com/denyka/osnova/actions/runs/1 "$@"; }
rec --bases "${scratch}/bases.json" --digests "${scratch}/digests.json" > "${scratch}/record.json"
t_assert_eq "2026.10.19" "$(jq -r .tag "${scratch}/record.json")" "record: tag"
t_assert_eq "commit,images,run,tag" "$(jq -r 'keys | join(",")' "${scratch}/record.json")" "record: top-level keys"
t_assert_eq 6 "$(jq '.images | length' "${scratch}/record.json")" "record: six images"
t_assert_eq "base,base_digest,base_platforms,digest,image,name,tag" "$(jq -r '.images[0] | keys | join(",")' "${scratch}/record.json")" "record: image keys"
t_assert_eq "ghcr.io/denyka/osnova/debian13" "$(jq -r '.images[3].image' "${scratch}/record.json")" "record: image path"
t_assert_eq "sha256:$(h64 4)" "$(jq -r '.images[3].digest' "${scratch}/record.json")" "record: index digest"
t_assert_eq "sha256:$(printf '%064d' 14)" "$(jq -r '.images[3].base_digest' "${scratch}/record.json")" "record: base digest"
t_assert_eq "$(printf '%s' "${json}" | jq -c '.[3].platforms')" "$(jq -c '.images[3].base_platforms' "${scratch}/record.json")" "record: base_platforms copied from the resolver"
t_assert_eq "linux/amd64,linux/arm64" "$(jq -r '.images[3].base_platforms | keys | join(",")' "${scratch}/record.json")" "record: base_platforms keys"
# a digest missing for an image in the matrix is an error
jq 'del(.debian13)' "${scratch}/digests.json" > "${scratch}/short.json"
if rec --bases "${scratch}/bases.json" --digests "${scratch}/short.json" >/dev/null 2>&1; then t_fail "record accepted a missing digest"; else t_ok "record refuses a missing digest"; fi
# an empty bases array, a malformed digest anywhere, and a base without platforms are refused
printf '[]\n' > "${scratch}/nobases.json"
if rec --bases "${scratch}/nobases.json" --digests "${scratch}/digests.json" >/dev/null 2>&1; then t_fail "record accepted an empty bases array"; else t_ok "record refuses an empty bases array"; fi
jq '.debian13 = "sha256:dddd"' "${scratch}/digests.json" > "${scratch}/baddig.json"
if rec --bases "${scratch}/bases.json" --digests "${scratch}/baddig.json" >/dev/null 2>&1; then t_fail "record accepted a short image digest"; else t_ok "record refuses a malformed image digest"; fi
jq '.[2].base_digest = "latest"' "${scratch}/bases.json" > "${scratch}/badbase.json"
if rec --bases "${scratch}/badbase.json" --digests "${scratch}/digests.json" >/dev/null 2>&1; then t_fail "record accepted a malformed base digest"; else t_ok "record refuses a malformed base digest"; fi
jq '.[1].platforms["linux/arm64"] = "sha256:XYZ"' "${scratch}/bases.json" > "${scratch}/badplat.json"
if rec --bases "${scratch}/badplat.json" --digests "${scratch}/digests.json" >/dev/null 2>&1; then t_fail "record accepted a malformed platform digest"; else t_ok "record refuses a malformed platform digest"; fi
jq 'del(.[4].platforms)' "${scratch}/bases.json" > "${scratch}/noplat.json"
if rec --bases "${scratch}/noplat.json" --digests "${scratch}/digests.json" >/dev/null 2>&1; then t_fail "record accepted a base without platforms"; else t_ok "record refuses a base without platforms"; fi
# every flag needs a value
bash tools/release_notes.sh record --tag >/dev/null 2>&1; rc=$?
t_assert_eq 2 "${rc}" "record: a flag without a value exits 2"
bash tools/release_notes.sh tag_exists --tag >/dev/null 2>&1; rc=$?
t_assert_eq 2 "${rc}" "tag_exists: --tag without a value exits 2"

notes="$(bash tools/release_notes.sh notes "${scratch}/record.json")"
if printf '%s\n' "${notes}" | grep -q '^| image | tag | digest | base | base digest |$'; then t_ok "notes: table header"; else t_fail "notes: table header"; fi
if printf '%s\n' "${notes}" | grep -q "| ghcr.io/denyka/osnova/ubuntu2604 | 2026.10.19 | sha256:$(h64 6) | ubuntu:26.04 | sha256:"; then t_ok "notes: ubuntu2604 row"; else t_fail "notes: ubuntu2604 row"; fi
if printf '%s\n' "${notes}" | grep -q 'cosign verify'; then t_ok "notes: verification command"; else t_fail "notes: no cosign verify"; fi
if printf '%s\n' "${notes}" | grep -qF -- "'^https://github\\.com/denyka/osnova/\\.github/workflows/release\\.yml@refs/heads/main\$'"; then t_ok "notes: anchored identity regexp"; else t_fail "notes: identity regexp wrong or unanchored"; fi
if printf '%s\n' "${notes}" | grep -qF -- '--certificate-oidc-issuer https://token.actions.githubusercontent.com'; then t_ok "notes: oidc issuer"; else t_fail "notes: oidc issuer wrong"; fi
if printf '%s\n' "${notes}" | grep -q '0123abc'; then t_ok "notes: commit named"; else t_fail "notes: commit missing"; fi

# the tag guard: 0 present, 1 absent, 3 on any other git failure with its message
repo="${scratch}/repo"; git init -q "${repo}"
git -C "${repo}" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m one
git -C "${repo}" -c tag.gpgsign=false tag v2026.10.18
(cd "${repo}" && bash "${T_ROOT}/tools/release_notes.sh" tag_exists --tag 2026.10.18); rc=$?
t_assert_eq 0 "${rc}" "tag_exists: existing tag is 0"
(cd "${repo}" && bash "${T_ROOT}/tools/release_notes.sh" tag_exists --tag 2026.10.19); rc=$?
t_assert_eq 1 "${rc}" "tag_exists: missing tag is 1"
(cd "${repo}" && GIT_DIR="${scratch}/no-such-git-dir" bash "${T_ROOT}/tools/release_notes.sh" tag_exists --tag 2026.10.18 2>"${scratch}/err"); rc=$?
t_assert_eq 3 "${rc}" "tag_exists: broken git is 3"
if grep -qi 'not a git repository' "${scratch}/err"; then t_ok "tag_exists: git's message is shown"; else t_fail "tag_exists: git message lost: $(cat "${scratch}/err")"; fi
mkdir -p "${scratch}/plain"
(cd "${scratch}/plain" && GIT_CEILING_DIRECTORIES="${scratch}" bash "${T_ROOT}/tools/release_notes.sh" tag_exists --tag 2026.10.19 2>/dev/null); rc=$?
t_assert_eq 3 "${rc}" "tag_exists: outside a repository is 3, not absent"

# ---- retention (SPEC 8.7) against a fake gh and a fake docker
# today is 2026.10.20. Released dated tags (age in days): 10.19 (1, latest), 10.18 (2), 09.20 (30),
# 08.01 (80), 07.20 (92), 06.30 (112), 06.22 (120). 10.17 (3) is the orphan of a failed run: no release
# names it. rc1 is a human tag, IMIX carries a dated tag and foo.
# children: I19 → A1819, B19 and NEST19 (an index) → C19A, C19B; I18 → A1819 (shared), B18, T18.
# every index has its signature tag sha256-<index>.sig.
cat > "${scratch}/versions.json" <<'EOF'
[
 {"id":1,"name":"sha256:I19","metadata":{"container":{"tags":["2026.10.19","latest"]}}},
 {"id":2,"name":"sha256:I18","metadata":{"container":{"tags":["2026.10.18"]}}},
 {"id":3,"name":"sha256:I17","metadata":{"container":{"tags":["2026.10.17"]}}},
 {"id":4,"name":"sha256:I0920","metadata":{"container":{"tags":["2026.09.20"]}}},
 {"id":5,"name":"sha256:I0801","metadata":{"container":{"tags":["2026.08.01"]}}},
 {"id":6,"name":"sha256:I0720","metadata":{"container":{"tags":["2026.07.20"]}}},
 {"id":7,"name":"sha256:I0630","metadata":{"container":{"tags":["2026.06.30"]}}},
 {"id":8,"name":"sha256:I0622","metadata":{"container":{"tags":["2026.06.22"]}}},
 {"id":9,"name":"sha256:IRC","metadata":{"container":{"tags":["rc1"]}}},
 {"id":10,"name":"sha256:IMIX","metadata":{"container":{"tags":["2026.10.01","foo"]}}},
 {"id":11,"name":"sha256:A1819","metadata":{"container":{"tags":[]}}},
 {"id":12,"name":"sha256:B19","metadata":{"container":{"tags":[]}}},
 {"id":13,"name":"sha256:NEST19","metadata":{"container":{"tags":[]}}},
 {"id":14,"name":"sha256:C19A","metadata":{"container":{"tags":[]}}},
 {"id":15,"name":"sha256:C19B","metadata":{"container":{"tags":[]}}},
 {"id":16,"name":"sha256:B18","metadata":{"container":{"tags":[]}}},
 {"id":17,"name":"sha256:T18","metadata":{"container":{"tags":[]}}},
 {"id":18,"name":"sha256:A17","metadata":{"container":{"tags":[]}}},
 {"id":19,"name":"sha256:A0920","metadata":{"container":{"tags":[]}}},
 {"id":20,"name":"sha256:A0801","metadata":{"container":{"tags":[]}}},
 {"id":21,"name":"sha256:A0720","metadata":{"container":{"tags":[]}}},
 {"id":22,"name":"sha256:A0630","metadata":{"container":{"tags":[]}}},
 {"id":23,"name":"sha256:A0622","metadata":{"container":{"tags":[]}}},
 {"id":31,"name":"sha256:S19","metadata":{"container":{"tags":["sha256-I19.sig"]}}},
 {"id":32,"name":"sha256:S18","metadata":{"container":{"tags":["sha256-I18.sig"]}}},
 {"id":33,"name":"sha256:S17","metadata":{"container":{"tags":["sha256-I17.sig"]}}},
 {"id":34,"name":"sha256:S0720","metadata":{"container":{"tags":["sha256-I0720.sig"]}}},
 {"id":35,"name":"sha256:S0630","metadata":{"container":{"tags":["sha256-I0630.sig"]}}},
 {"id":36,"name":"sha256:S0622","metadata":{"container":{"tags":["sha256-I0622.sig"]}}},
 {"id":37,"name":"sha256:SRC","metadata":{"container":{"tags":["sha256-IRC.sig"]}}},
 {"id":38,"name":"sha256:S0920","metadata":{"container":{"tags":["sha256-I0920.sig"]}}},
 {"id":39,"name":"sha256:S0801","metadata":{"container":{"tags":["sha256-I0801.sig"]}}},
 {"id":41,"name":"sha256:ARC","metadata":{"container":{"tags":[]}}},
 {"id":42,"name":"sha256:TRC","metadata":{"container":{"tags":[]}}},
 {"id":51,"name":"sha256:ORPHAN","metadata":{"container":{"tags":[]}}}
]
EOF
printf '%s\n' 2026.10.19 2026.10.18 2026.09.20 2026.08.01 2026.07.20 2026.06.30 2026.06.22 > "${scratch}/released.txt"
# fake gh: `api --paginate /users/denyka/packages/container/osnova%2Fx/versions` → the fixture in two pages;
# `api -X DELETE .../versions/<id>` → logs the id; GH_FAIL_LIST=1 fails the listing;
# GH_FAIL_DELETE=<id>:<message> refuses that delete with the message on stderr
cat > "${scratch}/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "${CALLS_LOG}"
if [[ "$*" == *"-X DELETE"* ]]; then
    args="$*"; id="${args##*/}"
    if [[ "${GH_FAIL_DELETE:-}" == "${id}:"* ]]; then
        printf 'gh: %s\n' "${GH_FAIL_DELETE#*:}" >&2; exit 1
    fi
    printf '%s\n' "${id}" >> "${DELETED_LOG}"; exit 0
fi
if [[ "$*" == *"/versions"* ]]; then
    [[ -n "${GH_FAIL_LIST:-}" ]] && { printf 'gh: 502\n' >&2; exit 1; }
    if [[ "$*" == *"--paginate"* ]]; then
        n="$(jq 'length / 2 | floor' "${VERSIONS_JSON}")"
        jq -c ".[:${n}]" "${VERSIONS_JSON}"; jq -c ".[${n}:]" "${VERSIONS_JSON}"
    else
        cat "${VERSIONS_JSON}"
    fi
    exit 0
fi
printf 'fake gh: unexpected: %s\n' "$*" >&2; exit 2
EOF
chmod +x "${scratch}/bin/gh"
# fake docker for retention: `buildx imagetools inspect --raw <ref>@sha256:Ixx` → the index's children, with
# media types; a leaf or an unknown digest is an error, so the tool may only read kept indexes and child indexes
cat > "${scratch}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALLS_LOG}"
ref="${!#}"; idx="${ref##*@sha256:}"
m() { printf '{"digest":"sha256:%s","mediaType":"application/vnd.oci.image.manifest.v1+json"}' "$1"; }
case "${idx}" in
    I19) printf '{"manifests":[%s,%s,{"digest":"sha256:NEST19","mediaType":"application/vnd.docker.distribution.manifest.list.v2+json"}]}\n' "$(m A1819)" "$(m B19)" ;;
    NEST19) printf '{"manifests":[%s,%s]}\n' "$(m C19A)" "$(m C19B)" ;;
    I18) printf '{"manifests":[%s,%s,%s]}\n' "$(m A1819)" "$(m B18)" "$(m T18)" ;;
    I17) printf '{"manifests":[%s]}\n' "$(m A17)" ;;
    I0920) printf '{"manifests":[%s]}\n' "$(m A0920)" ;;
    I0801) printf '{"manifests":[%s]}\n' "$(m A0801)" ;;
    I0720) printf '{"manifests":[%s]}\n' "$(m A0720)" ;;
    I0630) printf '{"manifests":[%s]}\n' "$(m A0630)" ;;
    I0622) printf '{"manifests":[%s]}\n' "$(m A0622)" ;;
    IRC) printf '{"manifests":[%s,%s]}\n' "$(m ARC)" "$(m TRC)" ;;
    IMIX | IBAD) printf '{"manifests":[]}\n' ;;
    *) printf 'fake docker: unexpected index %s\n' "${idx}" >&2; exit 1 ;;
esac
EOF
chmod +x "${scratch}/bin/docker"
export VERSIONS_JSON="${scratch}/versions.json" DELETED_LOG="${scratch}/deleted.log"
retain() { bash tools/retain.sh --owner denyka --package osnova/x --today 2026.10.20 "$@"; }
deleted() { sort -n "${DELETED_LOG}" | paste -sd' ' -; }

# A: keep 5, ninety days, the released list: young tags 10.19 10.18 09.20 08.01, the floor adds 07.20;
# 06.30 and 06.22 go, the orphan 10.17 goes at 3 days; untagged versions and signatures that no kept index references go
: > "${log}"; : > "${DELETED_LOG}"
out="$(retain --keep 5 --max-age-days 90 --released "${scratch}/released.txt" --dry-run)"; rc=$?
t_assert_eq 0 "${rc}" "retain --dry-run exits 0"
t_assert_eq "" "$(cat "${DELETED_LOG}")" "--dry-run deletes nothing"
for id in 3 7 8 18 22 23 33 35 36 51; do
    if printf '%s\n' "${out}" | grep -q "^would delete ${id} "; then t_ok "dry-run plans delete of ${id}"; else t_fail "dry-run misses ${id}"; fi
done
t_assert_eq 10 "$(printf '%s\n' "${out}" | grep -c '^would delete ')" "dry-run plans exactly ten deletes"
if grep -q 'osnova%2Fx/versions' "${log}"; then t_ok "package name url-encoded"; else t_fail "package name not url-encoded"; fi
if grep -q -- '--paginate' "${log}"; then t_ok "listing paginates"; else t_fail "listing does not paginate"; fi

: > "${DELETED_LOG}"
out="$(retain --keep 5 --max-age-days 90 --released "${scratch}/released.txt")"; rc=$?
t_assert_eq 0 "${rc}" "retain exits 0"
t_assert_eq "3 7 8 18 22 23 33 35 36 51" "$(deleted)" "A: exact delete set (floor keeps 07.20, orphan 10.17 goes)"
first="$(head -1 "${DELETED_LOG}")"
if [[ "${first}" == 3 || "${first}" == 7 || "${first}" == 8 ]]; then t_ok "dated tags deleted first"; else t_fail "first delete was ${first}"; fi
t_assert_eq "retain: osnova/x: kept 5 dated tag(s), deleted 10, skipped 0" "$(printf '%s\n' "${out}" | tail -1)" "A: final line counts kept, deleted, skipped"
# the shared child (11), the nested index (13) and its children (14 15) and the signatures of kept indexes survive
for id in 11 13 14 15 31 32 34 37 38 39 41 42 9 10; do
    if grep -qx "${id}" "${DELETED_LOG}"; then t_fail "kept version ${id} was deleted"; else t_ok "keeps ${id}"; fi
done
if grep -q 'NEST19' "${log}"; then t_ok "a child index is read too"; else t_fail "a child index was not inspected"; fi

# B: keep 2, thirty days: 09.20 is exactly thirty days old and goes
: > "${DELETED_LOG}"
retain --keep 2 --max-age-days 30 --released "${scratch}/released.txt" >/dev/null; rc=$?
t_assert_eq 0 "${rc}" "B: exits 0"
t_assert_eq "3 4 5 6 7 8 18 19 20 21 22 23 33 34 35 36 38 39 51" "$(deleted)" "B: exact delete set (age bound is exclusive)"
# C: the floor outranks age: keep 3, one day keeps 09.20 too
: > "${DELETED_LOG}"
retain --keep 3 --max-age-days 1 --released "${scratch}/released.txt" >/dev/null
t_assert_eq "3 5 6 7 8 18 20 21 22 23 33 34 35 36 39 51" "$(deleted)" "C: exact delete set (floor of three keeps 09.20)"
# D: no released list: every dated tag counts as released, the 3-day-old 10.17 stays
: > "${DELETED_LOG}"
retain --keep 2 --max-age-days 30 >/dev/null
t_assert_eq "4 5 6 7 8 19 20 21 22 23 34 35 36 38 39 51" "$(deleted)" "D: no --released: nothing is an orphan"
# the defaults (today, 90 days) run; the floor of two newest releases holds whatever today is
: > "${DELETED_LOG}"
bash tools/retain.sh --owner denyka --package osnova/x --keep 2 --released "${scratch}/released.txt" >/dev/null; rc=$?
t_assert_eq 0 "${rc}" "default --today and --max-age-days run"
if grep -qx 1 "${DELETED_LOG}" || grep -qx 2 "${DELETED_LOG}"; then t_fail "the floor lost a newest release"; else t_ok "the floor holds under the default today"; fi

# a delete the registry refuses with 400, 404, 409, 410 or 422 is skipped and reported; the run goes on
: > "${DELETED_LOG}"
out="$(GH_FAIL_DELETE='7:delete refused (HTTP 400)' retain --keep 5 --max-age-days 90 --released "${scratch}/released.txt" 2>"${scratch}/err")"; rc=$?
t_assert_eq 0 "${rc}" "a 4xx delete does not fail the run"
t_assert_eq "3 8 18 22 23 33 35 36 51" "$(deleted)" "4xx: every other delete still happens"
t_assert_eq "retain: skipped 7 2026.06.30 (HTTP 400)" "$(grep '^retain: skipped' "${scratch}/err")" "4xx: skipped line on stderr"
t_assert_eq "retain: osnova/x: kept 5 dated tag(s), deleted 9, skipped 1" "$(printf '%s\n' "${out}" | tail -1)" "4xx: final line counts"
# a skipped untagged version is labelled too
: > "${DELETED_LOG}"
GH_FAIL_DELETE='22:Not Found (HTTP 404)' retain --keep 5 --max-age-days 90 --released "${scratch}/released.txt" >/dev/null 2>"${scratch}/err"
t_assert_eq "retain: skipped 22 untagged (HTTP 404)" "$(grep '^retain: skipped' "${scratch}/err")" "4xx: an untagged version is reported"
for code in 409 410 422; do
    : > "${DELETED_LOG}"
    GH_FAIL_DELETE="7:refused (HTTP ${code})" retain --keep 5 --max-age-days 90 --released "${scratch}/released.txt" >/dev/null 2>"${scratch}/err"; rc=$?
    t_assert_eq "0:retain: skipped 7 2026.06.30 (HTTP ${code})" "${rc}:$(grep '^retain: skipped' "${scratch}/err")" "HTTP ${code} is skipped"
done
# any other failure stops the run: a missing scope (401, 403) must not stay green, nor a transient 408 or 429
for fail in 'Bad Gateway (HTTP 502)' 'HTTP 500' 'connection reset' 'Too Many Requests (HTTP 429)' 'Request Timeout (HTTP 408)' 'Unauthorized (HTTP 401)' 'Forbidden (HTTP 403)' 'HTTP 4000'; do
    : > "${DELETED_LOG}"
    GH_FAIL_DELETE="7:${fail}" retain --keep 5 --max-age-days 90 --released "${scratch}/released.txt" >/dev/null 2>"${scratch}/err"; rc=$?
    t_assert_eq 1 "${rc}" "delete failing with '${fail}' stops the run"
    t_assert_eq "3" "$(deleted)" "'${fail}': nothing after the failed delete"
done
# a failed listing deletes nothing and fails
: > "${DELETED_LOG}"
if GH_FAIL_LIST=1 retain --keep 5 --released "${scratch}/released.txt" >/dev/null 2>&1; then t_fail "listing failure not fatal"; else t_ok "listing failure is fatal"; fi
t_assert_eq "" "$(cat "${DELETED_LOG}")" "nothing deleted after a failed listing"
# an unreleased dated tag goes at any age with its signature and child
jq '[.[] | select(.id == 1 or .id == 11 or .id == 12 or .id == 13 or .id == 14 or .id == 15 or .id == 31 or .id == 3 or .id == 33 or .id == 18)]' "${scratch}/versions.json" > "${scratch}/few.json"
: > "${DELETED_LOG}"
printf '%s\n' 2026.10.19 > "${scratch}/one.txt"
VERSIONS_JSON="${scratch}/few.json" retain --keep 5 --released "${scratch}/one.txt" >/dev/null
t_assert_eq "3 18 33" "$(deleted)" "an unreleased dated tag and its debris go"
# an empty --released file, or one with no dated tag, would orphan every tag: exit 2 before any listing
: > "${scratch}/empty.txt"; printf '\n\nnot-a-tag\n' > "${scratch}/junk.txt"
for f in empty junk; do
    : > "${log}"; : > "${DELETED_LOG}"
    retain --keep 5 --released "${scratch}/${f}.txt" >/dev/null 2>"${scratch}/err"; rc=$?
    t_assert_eq 2 "${rc}" "${f} --released file exits 2"
    t_assert_eq "" "$(cat "${log}")${DELETED_LOG:+$(cat "${DELETED_LOG}")}" "${f} --released file: no listing, no delete"
    if grep -q 'released' "${scratch}/err"; then t_ok "${f} --released file: message"; else t_fail "${f} --released file: no message"; fi
done
# a tag of the dated shape with impossible month or day is not dated: never aged, never deleted
jq '. + [{"id":60,"name":"sha256:IBAD","metadata":{"container":{"tags":["2026.13.45"]}}}]' "${scratch}/few.json" > "${scratch}/badtag.json"
: > "${DELETED_LOG}"
VERSIONS_JSON="${scratch}/badtag.json" retain --keep 5 --released "${scratch}/one.txt" >/dev/null 2>&1; rc=$?
t_assert_eq 0 "${rc}" "an out-of-range date tag does not fail the run"
t_assert_eq "3 18 33" "$(deleted)" "an out-of-range date tag is kept as a non-dated tag"
bash tools/retain.sh --owner denyka --package osnova/x --today 2026.13.45 >/dev/null 2>&1; rc=$?
t_assert_eq 2 "${rc}" "an out-of-range --today exits 2"
# a missing option value is a usage error
for opt in --owner --package --keep --max-age-days --released --today; do
    bash tools/retain.sh "${opt}" >/dev/null 2>&1; rc=$?
    t_assert_eq 2 "${rc}" "missing value for ${opt} exits 2"
done
bash tools/retain.sh --owner denyka --package osnova/x --today 2026-10-20 >/dev/null 2>&1; rc=$?
t_assert_eq 2 "${rc}" "a malformed --today exits 2"
bash tools/retain.sh --owner denyka --package osnova/x --released "${scratch}/nope.txt" >/dev/null 2>&1; rc=$?
t_assert_eq 2 "${rc}" "an unreadable --released exits 2"
# an unreadable kept index stops the run before any delete
printf '[{"id":1,"name":"sha256:BAD","metadata":{"container":{"tags":["latest"]}}},{"id":2,"name":"sha256:X","metadata":{"container":{"tags":[]}}}]\n' > "${scratch}/bad.json"
: > "${DELETED_LOG}"
VERSIONS_JSON="${scratch}/bad.json" retain >/dev/null 2>&1; rc=$?
t_assert_eq 1 "${rc}" "unreadable kept index exits 1"
t_assert_eq "" "$(cat "${DELETED_LOG}")" "nothing deleted after an index read failure"
# nothing to keep while untagged versions exist: refuse
printf '[{"id":2,"name":"sha256:X","metadata":{"container":{"tags":[]}}}]\n' > "${scratch}/none.json"
: > "${DELETED_LOG}"
VERSIONS_JSON="${scratch}/none.json" retain >/dev/null 2>&1; rc=$?
t_assert_eq 1 "${rc}" "empty keep set refuses"
t_assert_eq "" "$(cat "${DELETED_LOG}")" "nothing deleted when refusing"
t_finish
