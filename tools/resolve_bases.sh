#!/usr/bin/env bash
# resolve_bases.sh — base tag → index digest (SPEC 8.3 step 1).
#   resolve_bases.sh          print BASE_<NAME>=<base>@sha256:<digest>, one per image
#   resolve_bases.sh --list   print "name family base" per image, no network
#   resolve_bases.sh --json   print [{name,family,base,base_digest,platforms}] where
#                             platforms is {"linux/amd64": sha256:…, "linux/arm64": sha256:…},
#                             the digests of the base index's two manifests, all from one
#                             `imagetools inspect --format '{{json .Manifest}}'` read per base
# Reads matrix.yml beside this script's repository root, strictly (comments, blank
# lines and a leading --- aside): every
# entry holds exactly name, family and base as plain scalars of the shapes
# below, or the run fails naming the entry; nothing is inherited or dropped.
#   name    ^[a-z]+[0-9]+$, unique      family  ^[a-z]+$
#   base    ^[a-z0-9.-]+:[a-z0-9.-]+$
# A base that does not resolve, resolves to something that is not a digest,
# or whose index lacks linux/amd64 or linux/arm64 (--json) fails the run and
# prints nothing for that image: an unreachable registry must never read as
# "unchanged" (SPEC 9). A failed docker call keeps its stderr visible.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
matrix="${root}/matrix.yml"
digest_re='^sha256:[0-9a-f]{64}$'

# list prints "name family base" per image, in matrix order, or fails naming the entry
list() {
    if [[ ! -s "${matrix}" ]]; then
        printf 'resolve_bases: %s is missing or empty\n' "${matrix}" >&2
        return 1
    fi
    local line lineno=0 seen_images=false entries="" names=" "
    local name="" family="" base="" open=false
    local re_name='^[a-z]+[0-9]+$' re_family='^[a-z]+$' re_base='^[a-z0-9.-]+:[a-z0-9.-]+$'
    local key value

    # close the entry being read: all three fields present, each well formed, the name unique
    flush() {
        [[ "${open}" == true ]] || return 0
        if [[ -z "${name}" || -z "${family}" || -z "${base}" ]]; then
            printf 'resolve_bases: matrix.yml: entry %s: needs exactly name, family and base\n' "${name:-at line ${lineno}}" >&2
            return 1
        fi
        if [[ ! "${name}" =~ ${re_name} ]]; then
            printf 'resolve_bases: matrix.yml: entry %s: name must match %s\n' "${name}" "${re_name}" >&2; return 1
        fi
        if [[ ! "${family}" =~ ${re_family} ]]; then
            printf 'resolve_bases: matrix.yml: entry %s: family %s must match %s\n' "${name}" "${family}" "${re_family}" >&2; return 1
        fi
        if [[ ! "${base}" =~ ${re_base} ]]; then
            printf 'resolve_bases: matrix.yml: entry %s: base %s must match %s\n' "${name}" "${base}" "${re_base}" >&2; return 1
        fi
        if [[ "${names}" == *" ${name} "* ]]; then
            printf 'resolve_bases: matrix.yml: entry %s: duplicate name\n' "${name}" >&2; return 1
        fi
        names+="${name} "
        entries+="${name} ${family} ${base}"$'\n'
        return 0
    }

    while IFS= read -r line || [[ -n "${line}" ]]; do
        lineno=$((lineno + 1))
        if [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]]; then continue; fi
        if [[ "${line}" == "---" && "${seen_images}" == false && "${open}" == false ]]; then continue; fi
        if [[ "${line}" == "images:" ]]; then
            if [[ "${seen_images}" == true ]]; then
                printf 'resolve_bases: matrix.yml:%s: images: given twice\n' "${lineno}" >&2; return 1
            fi
            seen_images=true; continue
        fi
        if [[ "${seen_images}" == true && "${line}" == "  - name: "* ]]; then
            flush || return 1
            open=true; name="${line#  - name: }"; family=""; base=""
        elif [[ "${open}" == true && "${line}" == "    "[A-Za-z_]*": "* ]]; then
            key="${line#    }"; value="${key#*: }"; key="${key%%: *}"
            case "${key}" in
                family)
                    if [[ -n "${family}" ]]; then printf 'resolve_bases: matrix.yml: entry %s: family given twice\n' "${name}" >&2; return 1; fi
                    family="${value}" ;;
                base)
                    if [[ -n "${base}" ]]; then printf 'resolve_bases: matrix.yml: entry %s: base given twice\n' "${name}" >&2; return 1; fi
                    base="${value}" ;;
                *) printf 'resolve_bases: matrix.yml: entry %s: unexpected key %s\n' "${name}" "${key}" >&2; return 1 ;;
            esac
        else
            printf 'resolve_bases: matrix.yml:%s: not a matrix line: %s\n' "${lineno}" "${line}" >&2
            return 1
        fi
    done < "${matrix}"
    flush || return 1
    if [[ -z "${entries}" ]]; then
        printf 'resolve_bases: %s lists no image\n' "${matrix}" >&2
        return 1
    fi
    printf '%s' "${entries}"
}

resolve_one() { # $1 base → digest on stdout, or return 1
    local digest
    if ! digest="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$1")"; then
        printf 'resolve_bases: %s: cannot resolve\n' "$1" >&2
        return 1
    fi
    if [[ ! "${digest}" =~ ${digest_re} ]]; then
        printf 'resolve_bases: %s: not a digest: %s\n' "$1" "${digest}" >&2
        return 1
    fi
    printf '%s\n' "${digest}"
}

resolve_json() { # $1 base → "digest amd64 arm64" on stdout, or return 1; one registry read
    local manifest d amd arm
    if ! manifest="$(docker buildx imagetools inspect --format '{{json .Manifest}}' "$1")"; then
        printf 'resolve_bases: %s: cannot resolve\n' "$1" >&2
        return 1
    fi
    if ! d="$(jq -r '[.digest // "",
            ([.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest][0] // ""),
            ([.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "arm64") | .digest][0] // "")] | join(" ")' <<<"${manifest}")"; then
        printf 'resolve_bases: %s: the answer is not JSON\n' "$1" >&2
        return 1
    fi
    read -r digest amd arm <<<"${d}"
    if [[ ! "${digest}" =~ ${digest_re} ]]; then
        printf 'resolve_bases: %s: not a digest: %s\n' "$1" "${digest}" >&2
        return 1
    fi
    if [[ ! "${amd}" =~ ${digest_re} ]]; then
        printf 'resolve_bases: %s: no linux/amd64 manifest in the index\n' "$1" >&2
        return 1
    fi
    if [[ ! "${arm}" =~ ${digest_re} ]]; then
        printf 'resolve_bases: %s: no linux/arm64 manifest in the index\n' "$1" >&2
        return 1
    fi
    printf '%s %s %s\n' "${digest}" "${amd}" "${arm}"
}

# prints "name family base digest[ amd64 arm64]" per image; fails on any miss.
# $1 = platforms adds the two manifest digests. One registry read per base.
resolve_all() {
    local name family base resolved entries failed=0
    entries="$(list)" || return 1
    while read -r name family base; do
        if [[ "${1:-}" == platforms ]]; then
            if resolved="$(resolve_json "${base}")"; then
                printf '%s %s %s %s\n' "${name}" "${family}" "${base}" "${resolved}"
            else
                failed=1
            fi
        elif resolved="$(resolve_one "${base}")"; then
            printf '%s %s %s %s\n' "${name}" "${family}" "${base}" "${resolved}"
        else
            failed=1
        fi
    done <<< "${entries}"
    [[ "${failed}" -eq 0 ]]
}

case "${1:-}" in
    --list) list ;;
    --json)
        resolved="$(resolve_all platforms)"
        printf '%s\n' "${resolved}" | jq -Rn '[inputs | split(" ") | {name: .[0], family: .[1], base: .[2], base_digest: .[3],
            platforms: {"linux/amd64": .[4], "linux/arm64": .[5]}}]'
        ;;
    "")
        resolved="$(resolve_all)"
        printf '%s\n' "${resolved}" | awk '{ n=toupper($1); printf "BASE_%s=%s@%s\n", n, $3, $4 }'
        ;;
    *) printf 'usage: %s [--list|--json]\n' "$0" >&2; exit 2 ;;
esac
