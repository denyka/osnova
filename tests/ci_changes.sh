#!/usr/bin/env bash
# The changes gate (SPEC 8.10): .github/ci_changes.sh classifies a change as
# documentation-only or code, and reads a pull_request event with git alone.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
cd "${T_ROOT}" || exit 1

script="${T_ROOT}/.github/ci_changes.sh"
t_assert_file .github/ci_changes.sh
if [[ -x "${script}" ]]; then t_ok "ci_changes.sh is executable"; else t_fail "ci_changes.sh is not executable"; fi

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"; [[ "${_T_FAILED}" -eq 0 ]] || exit 1' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

classify() { bash "${script}" --classify; }

# the --classify table: input, expected line, label
t_assert_eq "code=false" "$(printf 'README.md\ndocs/how_to/x.md\nLICENSE\n.github/CODEOWNERS\n.gitlab/ci.yml\n' | classify)" "classify: documentation set alone is not code"
t_assert_eq "code=false" "$(printf '.github/ISSUE_TEMPLATE/bug.yml\n.github/pull_request_template.md\nimages/README.md\n' | classify)" "classify: templates and nested markdown are documentation"
t_assert_eq "code=true" "$(printf 'docs/x.md\nimages/el/Dockerfile\n' | classify)" "classify: documentation plus a Dockerfile is code"
t_assert_eq "code=true" "$(printf 'matrix.yml\n' | classify)" "classify: matrix.yml is code"
t_assert_eq "code=true" "$(printf 'tests/smoke.sh\n' | classify)" "classify: tests/smoke.sh is code"
t_assert_eq "code=true" "$(printf 'Makefile' | classify)" "classify: a last path without a newline is read"
t_assert_eq "code=true" "$(printf '' | classify)" "classify: an empty list runs everything"

# event mode
event() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE GITHUB_OUTPUT="${out}" "$@" bash "${script}"; }

out="${scratch}/out_push"
: >"${out}"
event GITHUB_EVENT_NAME=push
t_assert_eq $'code=true\ndraft=false' "$(cat "${out}")" "event: a push runs everything"

out="${scratch}/out_missing"
: >"${out}"
rc=0
event GITHUB_EVENT_NAME=pull_request PR_DRAFT=false 2>/dev/null || rc=$?
t_assert_eq 1 "${rc}" "event: a pull request without SHAs exits 1"
t_assert_eq 0 "$(wc -c <"${out}" | tr -d ' ')" "event: a refused run writes nothing"

out="${scratch}/out_baddraft"
: >"${out}"
rc=0
event GITHUB_EVENT_NAME=pull_request PR_BASE_SHA=a PR_HEAD_SHA=b PR_DRAFT=maybe 2>/dev/null || rc=$?
t_assert_eq 1 "${rc}" "event: a bad PR_DRAFT exits 1"
t_assert_eq 0 "$(wc -c <"${out}" | tr -d ' ')" "event: a bad PR_DRAFT writes nothing"

# git-backed cases in a scratch repository
repo="${scratch}/repo"
mkdir -p "${repo}"
g() { git -C "${repo}" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
g init -q -b main
mkdir -p "${repo}/docs" "${repo}/images"
printf 'a\n' >"${repo}/docs/a.md"
printf 'content that moves from a code path into docs\n' >"${repo}/images/x"
g add -A
g commit -q -m base
base="$(g rev-parse HEAD)"

g checkout -q -b rename
g mv images/x docs/x.md
g commit -q -m head
head_rename="$(g rev-parse HEAD)"

g checkout -q "${base}"
g checkout -q -b docsonly
printf 'a2\n' >>"${repo}/docs/a.md"
g add -A
g commit -q -m docs
head_docs="$(g rev-parse HEAD)"

pr() {
    out="${scratch}/out_$1"
    : >"${out}"
    (cd "${repo}" && event GITHUB_EVENT_NAME=pull_request PR_BASE_SHA="${base}" PR_HEAD_SHA="$2" PR_DRAFT=false)
}
pr rename "${head_rename}"
t_assert_eq $'code=true\ndraft=false' "$(cat "${out}")" "event: a rename from images/ into docs/ lists the source side, so it is code"
pr docs "${head_docs}"
t_assert_eq $'code=false\ndraft=false' "$(cat "${out}")" "event: a docs-only head is not code"

# unknown SHAs: git diff fails, the run fails and writes nothing
out="${scratch}/out_unknown"
: >"${out}"
rc=0
(cd "${repo}" && event GITHUB_EVENT_NAME=pull_request PR_BASE_SHA=0000000000000000000000000000000000000001 PR_HEAD_SHA=0000000000000000000000000000000000000002 PR_DRAFT=false) 2>/dev/null || rc=$?
if [[ "${rc}" -ne 0 ]]; then t_ok "event: unknown SHAs exit non-zero"; else t_fail "event: unknown SHAs exited 0"; fi
t_assert_eq 0 "$(wc -c <"${out}" | tr -d ' ')" "event: unknown SHAs write nothing"

t_finish
