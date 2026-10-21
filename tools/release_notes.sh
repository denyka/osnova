#!/usr/bin/env bash
# release_notes.sh — the release record and what is rendered from it (SPEC 8.3
# step 7, 8.4).
#   record --tag T --commit C --run URL --bases bases.json --digests digests.json
#       bases.json: resolve_bases.sh --json; digests.json: {"<name>":"sha256:..."}
#       prints record.json: {tag, commit, run, images:[{name,image,tag,digest,base,base_digest,
#       base_platforms}]}; base_platforms is the resolver's platforms ({"linux/amd64": …,
#       "linux/arm64": …}). An empty bases array, a missing index digest and any digest that
#       is not sha256:<64 hex> are refused.
#   notes record.json      prints the Markdown notes
#   tag_exists --tag T     exit 0 when git tag vT exists here, 1 when it does not,
#                          3 (with git's message) on any other git failure
# Every --flag needs a value; otherwise usage, exit 2.
set -euo pipefail

registry="ghcr.io/denyka/osnova"

usage() { printf 'usage: %s record|notes|tag_exists ...\n' "$0" >&2; exit 2; }

record() {
    local tag="" commit="" run="" bases="" digests=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag) [[ $# -ge 2 ]] || usage; tag="$2"; shift 2 ;;
            --commit) [[ $# -ge 2 ]] || usage; commit="$2"; shift 2 ;;
            --run) [[ $# -ge 2 ]] || usage; run="$2"; shift 2 ;;
            --bases) [[ $# -ge 2 ]] || usage; bases="$2"; shift 2 ;;
            --digests) [[ $# -ge 2 ]] || usage; digests="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    [[ -n "${tag}" && -n "${commit}" && -n "${run}" && -f "${bases}" && -f "${digests}" ]] || usage
    # every image of the matrix needs its index digest; a missing one is an error
    local missing
    missing="$(jq -r --slurpfile d "${digests}" '.[] | select($d[0][.name] == null) | .name' "${bases}")"
    if [[ -n "${missing}" ]]; then
        printf 'release_notes: no index digest for: %s\n' "${missing}" >&2
        return 1
    fi
    # every digest the record carries must be a full sha256, and every base needs both platforms
    local bad
    bad="$(jq -r --slurpfile d "${digests}" '
        if length == 0 then "bases.json lists no image" else
        [ .[] | . as $b | ($d[0][$b.name], $b.base_digest, $b.platforms["linux/amd64"]?, $b.platforms["linux/arm64"]?)
          | select((type != "string") or (test("^sha256:[0-9a-f]{64}$") | not)) ] | length
          | if . > 0 then "\(.) digest(s) are not sha256:<64 hex>" else empty end end' "${bases}")"
    if [[ -n "${bad}" ]]; then
        printf 'release_notes: %s\n' "${bad}" >&2
        return 1
    fi
    jq -n --arg tag "${tag}" --arg commit "${commit}" --arg run "${run}" --arg registry "${registry}" \
        --slurpfile bases "${bases}" --slurpfile digests "${digests}" '
        { tag: $tag, commit: $commit, run: $run,
          images: [ $bases[0][] | { name: .name, image: ($registry + "/" + .name), tag: $tag,
                                    digest: $digests[0][.name], base: .base, base_digest: .base_digest,
                                    base_platforms: .platforms } ] }'
}

notes() {
    local record="$1"
    [[ -f "${record}" ]] || usage
    local tag commit run first
    tag="$(jq -r .tag "${record}")"; commit="$(jq -r .commit "${record}")"; run="$(jq -r .run "${record}")"
    first="$(jq -r '.images[0].image' "${record}")"
    printf 'Images of osnova %s\n\n' "${tag}"
    printf 'Built from commit %s by %s. Every image below is a multi-architecture index (linux/amd64, linux/arm64), signed with cosign keyless; record.json on this release carries the same table.\n\n' "${commit}" "${run}"
    printf '| image | tag | digest | base | base digest |\n| --- | --- | --- | --- | --- |\n'
    jq -r '.images[] | "| \(.image) | \(.tag) | \(.digest) | \(.base) | \(.base_digest) |"' "${record}"
    printf '\nVerify any image:\n\n```bash\ncosign verify \\\n  --certificate-oidc-issuer https://token.actions.githubusercontent.com \\\n  --certificate-identity-regexp '"'"'^https://github\\.com/denyka/osnova/\\.github/workflows/release\\.yml@refs/heads/main$'"'"' \\\n  %s:%s\n```\n' "${first}" "${tag}"
}

tag_exists() {
    local tag="" err rc=0
    while [[ $# -gt 0 ]]; do
        case "$1" in --tag) [[ $# -ge 2 ]] || usage; tag="$2"; shift 2 ;; *) usage ;; esac
    done
    [[ -n "${tag}" ]] || usage
    err="$(git rev-parse -q --verify "refs/tags/v${tag}" 2>&1 >/dev/null)" || rc=$?
    case "${rc}" in
        0) return 0 ;;
        1) [[ -z "${err}" ]] && return 1 ;;
    esac
    printf 'release_notes: git failed (exit %s): %s\n' "${rc}" "${err}" >&2
    return 3
}

cmd="${1:-}"; shift || true
case "${cmd}" in
    record) record "$@" ;;
    notes) notes "$@" ;;
    tag_exists) tag_exists "$@" ;;
    *) usage ;;
esac
