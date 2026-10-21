# shellcheck shell=bash
# harness.sh — shared assertions for tests/*.sh. Sourced, never executed.
# A test script sources this file, calls t_* assertions, and ends with
# t_finish, which exits 1 when any assertion failed.

[[ -n "${__T_HARNESS_LOADED:-}" ]] && return 0
readonly __T_HARNESS_LOADED=1

_T_FAILED=0
_T_PASSED=0

# Repo root derived from this file's location: tests/lib/ → repo root.
T_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly T_ROOT

t_ok()   { _T_PASSED=$((_T_PASSED + 1)); printf 'ok    %s\n' "$*"; }
t_fail() { _T_FAILED=$((_T_FAILED + 1)); printf 'FAIL  %s\n' "$*" >&2; }

t_assert_file() {
    if [[ -f "${T_ROOT}/$1" ]]; then t_ok "file exists: $1"; else t_fail "missing file: $1"; fi
}

t_assert_dir() {
    if [[ -d "${T_ROOT}/$1" ]]; then t_ok "dir exists: $1"; else t_fail "missing dir: $1"; fi
}

t_assert_grep() {
    if grep -qE -- "$1" "${T_ROOT}/$2" 2>/dev/null; then
        t_ok "$2 matches /$1/"
    else
        t_fail "$2 does not match /$1/"
    fi
}

t_assert_not_grep() {
    if grep -qE -- "$1" "${T_ROOT}/$2" 2>/dev/null; then
        t_fail "$2 must not match /$1/"
    else
        t_ok "$2 clean of /$1/"
    fi
}

t_assert_eq() {
    if [[ "$1" == "$2" ]]; then t_ok "$3"; else t_fail "$3 (expected '$1', got '$2')"; fi
}

t_finish() {
    printf '%s: %d passed, %d failed\n' "$(basename "$0")" "${_T_PASSED}" "${_T_FAILED}"
    [[ "${_T_FAILED}" -eq 0 ]]
}

# A suite that never reaches t_finish still fails when it recorded a failure.
trap '[[ "${_T_FAILED}" -eq 0 ]] || exit 1' EXIT
