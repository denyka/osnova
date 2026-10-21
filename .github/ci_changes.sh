#!/usr/bin/env bash
# ci_changes.sh — classify what a pull request touched, for the `changes`
# job of ci.yml (SPEC 8.10). The verify jobs read the outputs and run only
# when the change can affect their result.
#
#   ci_changes.sh             read the event from the environment and append
#                             the outputs to $GITHUB_OUTPUT
#   ci_changes.sh --classify  read one path per line on stdin, print the
#                             classification on stdout (the test's mode)
#
# Outputs: code and draft. A pull_request event supplies PR_BASE_SHA,
# PR_HEAD_SHA and PR_DRAFT through the environment. Any other event (a push
# to main) runs everything.
set -euo pipefail

# classify reads paths on stdin and prints code=true|false. The first
# matching pattern wins. Documentation is HQ's set: anything else is code.
# An empty list is unknown, and unknown runs everything.
classify() {
  local code=false any=false path
  while IFS= read -r path || [[ -n "${path}" ]]; do
    [[ -z "${path}" ]] && continue
    any=true
    # *.md also covers .github/pull_request_template.md.
    case "${path}" in
    docs/* | *.md | LICENSE | .github/ISSUE_TEMPLATE/* | .github/CODEOWNERS | .gitlab/*) ;;
    *) code=true ;;
    esac
  done
  if [[ "${any}" == false ]]; then
    code=true
  fi
  printf 'code=%s\n' "${code}"
}

main() {
  local out="${GITHUB_OUTPUT:?GITHUB_OUTPUT is unset}"
  if [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" ]]; then
    printf 'code=true\ndraft=false\n' >>"${out}"
    return 0
  fi
  local base="${PR_BASE_SHA:-}" head="${PR_HEAD_SHA:-}" draft="${PR_DRAFT:-}"
  if [[ -z "${base}" || -z "${head}" ]]; then
    printf 'ci_changes: a pull_request event needs PR_BASE_SHA and PR_HEAD_SHA\n' >&2
    return 1
  fi
  case "${draft}" in
  true | false) ;;
  *)
    printf 'ci_changes: PR_DRAFT must be true or false, got %q\n' "${draft}" >&2
    return 1
    ;;
  esac
  # Three dots: what the pull request changed since it diverged from its
  # base. --no-renames lists both sides of a rename: a move into docs/ must
  # not hide the source path it left.
  local result
  result="$(git diff --name-only --no-renames "${base}...${head}" | classify)"
  printf '%s\ndraft=%s\n' "${result}" "${draft}" >>"${out}"
}

case "${1:-}" in
--classify) classify ;;
"") main ;;
*)
  printf 'usage: %s [--classify]\n' "$0" >&2
  exit 2
  ;;
esac
