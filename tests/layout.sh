#!/usr/bin/env bash
# The chassis: every path SPEC 5 names exists, the Makefile carries the
# image targets, the Claude layer denies publishing.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
cd "${T_ROOT}" || exit 1

for f in Makefile README.md CHANGELOG.md LICENSE SECURITY.md CONTRIBUTING.md CODE_OF_CONDUCT.md \
         CLAUDE.md docs/SPEC.md matrix.yml docker-bake.hcl .editorconfig .gitignore \
         .markdownlint.yaml .yamllint.yaml .pre-commit-config.yaml .shellcheckrc \
         .hadolint.yaml .dockerignore .github/dependabot.yml .github/requirements.txt \
         .github/workflows/lint.yml .github/CODEOWNERS .claude/settings.json .claude/.gitignore \
         images/el/Dockerfile images/deb/Dockerfile \
         tools/resolve_bases.sh tools/release_notes.sh tools/retain.sh \
         tests/lib/harness.sh tests/run.sh tests/layout.sh tests/matrix.sh tests/dockerfiles.sh \
         tests/workflows.sh tests/ci_changes.sh tests/tools.sh tests/smoke.sh \
         .github/workflows/ci.yml .github/workflows/release.yml .github/workflows/watch.yml \
         .github/actions/build_and_verify/action.yml .github/ci_changes.sh .github/trivy.sha256 \
         .github/pull_request_template.md .trivyignore.yaml \
         docs/security.md .claude/skills/_osnova_development/SKILL.md; do
    t_assert_file "${f}"
done
for d in docs docs/adr docs/how_to docs/reference .github/ISSUE_TEMPLATE .github/actions .claude/skills; do
    t_assert_dir "${d}"
done
if [[ -L AGENTS.md && "$(readlink AGENTS.md)" == "CLAUDE.md" ]]; then t_ok "AGENTS.md links CLAUDE.md"; else t_fail "AGENTS.md is not a link to CLAUDE.md"; fi
for target in build smoke scan digests; do t_assert_grep "^${target}: ##" Makefile; done
t_assert_not_grep 'docker_bake\.yml' .github/workflows/lint.yml
if [[ ! -e .github/workflows/docker_bake.yml ]]; then t_ok "docker_bake.yml not carried (SPEC 14)"; else t_fail "docker_bake.yml present"; fi
# every publishing path is denied (prefix globs; a * matches anywhere in the command)
for d in 'gh release *' 'docker push*' 'docker image push*' 'docker buildx build*' \
         'docker buildx bake*--push*' 'docker buildx bake*push=true*' 'docker buildx imagetools create*' \
         'cosign sign*' 'gh workflow run*' 'bash tools/retain.sh*' 'tools/retain.sh*' 'gh api*DELETE*'; do
    if grep -qF "\"Bash(${d})\"" .claude/settings.json; then t_ok "denied: ${d}"; else t_fail "not denied: ${d}"; fi
done
# the config scan ignores exactly DS-0002: an init image runs as root by design (SPEC 14)
if [[ ! -e .trivyignore ]]; then t_ok ".trivyignore absent (replaced by .trivyignore.yaml)"; else t_fail ".trivyignore present"; fi
t_assert_grep 'AVD-DS-0002' .trivyignore.yaml
t_assert_eq "1" "$(grep -c 'AVD-' .trivyignore.yaml)" ".trivyignore.yaml names one check"
t_assert_grep 'SPEC 14' .trivyignore.yaml
# the Trivy pin file: three sourceable lines (SPEC 8.9)
t_assert_grep '^TRIVY_VERSION=' .github/trivy.sha256
t_assert_grep '^TRIVY_SHA256_AMD64=' .github/trivy.sha256
t_assert_grep '^TRIVY_SHA256_ARM64=' .github/trivy.sha256
t_assert_grep 'versioning scheme is the one .docs/SPEC\.md. states' CHANGELOG.md
t_assert_grep '^## \[Unreleased\]' CHANGELOG.md
t_assert_grep '^\.dev/$' .gitignore
t_assert_grep '^\.tmp/$' .gitignore
t_finish
