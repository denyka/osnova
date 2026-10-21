#!/usr/bin/env bash
# run.sh — execute every tests/*.sh and fail if any fails. A suite also
# fails when it never prints its `N passed, M failed` summary, so a script
# that exits early or forgets t_finish cannot pass by accident.
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0
ran=0
for t in "${root}"/tests/*.sh; do
    [[ "$(basename "${t}")" == "run.sh" ]] && continue
    ran=$((ran + 1))
    printf '==> %s\n' "$(basename "${t}")"
    out="$(bash "${t}" 2>&1)"; rc=$?
    printf '%s\n' "${out}"
    if [[ "${rc}" -ne 0 ]]; then
        failed=$((failed + 1))
    elif ! grep -qE ': [0-9]+ passed, [0-9]+ failed$' <<<"${out}"; then
        printf 'FAIL  %s: no summary line (t_finish not reached)\n' "$(basename "${t}")" >&2
        failed=$((failed + 1))
    fi
done
if [[ "${failed}" -ne 0 ]]; then
    printf 'tests: %d suite(s) failed\n' "${failed}" >&2
    exit 1
fi
# an empty tests/ is not a passing test suite
if [[ "${ran}" -eq 0 ]]; then
    printf 'tests: no suite under tests/ (write tests/<name>.sh with the harness)\n' >&2
    exit 1
fi
printf 'tests: all suites passed\n'
