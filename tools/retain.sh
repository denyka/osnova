#!/usr/bin/env bash
# retain.sh — retention over one image's package on GHCR (SPEC 8.7).
#   retain.sh --owner OWNER --package osnova/NAME [--keep 5] [--max-age-days 90]
#             [--released FILE] [--today YYYY.MM.DD] [--dry-run]
# Keeps `latest`, every dated tag (YYYY.MM.DD) that a release names and that is
# younger than MAX-AGE-DAYS, and in any case the KEEP newest dated tags that a
# release names. FILE lists the released tags, one per line (a leading v is
# ignored); without --released every dated tag counts as released. A dated tag
# no release names is deleted at any age: it is the orphan of a failed run.
# A dated tag has a month 01-12 and a day 01-31; anything else is a non-dated tag.
# A tag's age is TODAY (default: the current UTC day) minus the tag's date.
# A version carrying a tag that is neither dated nor a cosign signature is kept.
# Then deletes every untagged version and every cosign signature tag that no
# kept index references. A kept index references its per-architecture
# manifests, its attestation manifests, the children of any child that is
# itself an index, and its signature tag sha256-<digest>.sig.
# Everything to delete is computed before the first delete. A failed listing or
# index read stops the script before any delete. A delete that gh refuses with
# an HTTP 400, 404, 409, 410 or 422 is reported ("retain: skipped <id> <label> (HTTP <code>)") and
# skipped; any other failed delete (401, 403, 408, 429 and 5xx included) stops the script with exit 1. The last line
# reports the kept, deleted and skipped counts.
# Needs gh (authenticated: GH_TOKEN or GITHUB_TOKEN), jq and docker.
set -euo pipefail

owner="" package="" keep=5 max_age=90 released="" today="" dry_run=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --owner | --package | --keep | --max-age-days | --released | --today)
            [[ $# -ge 2 ]] || { printf 'retain: %s needs a value\n' "$1" >&2; exit 2; }
            case "$1" in
                --owner) owner="$2" ;;
                --package) package="$2" ;;
                --keep) keep="$2" ;;
                --max-age-days) max_age="$2" ;;
                --released) released="$2" ;;
                --today) today="$2" ;;
            esac
            shift 2
            ;;
        --dry-run) dry_run=true; shift ;;
        *) printf 'usage: %s --owner OWNER --package PKG [--keep N] [--max-age-days N] [--released FILE] [--today YYYY.MM.DD] [--dry-run]\n' "$0" >&2; exit 2 ;;
    esac
done
dated='^[0-9]{4}\.(0[1-9]|1[0-2])\.(0[1-9]|[12][0-9]|3[01])$'
[[ -n "${today}" ]] || today="$(date -u +%Y.%m.%d)"
[[ -n "${owner}" && -n "${package}" && "${keep}" =~ ^[0-9]+$ && "${max_age}" =~ ^[0-9]+$ && "${today}" =~ ${dated} ]] \
    || { printf 'retain: --owner, --package, a numeric --keep and --max-age-days and a --today of YYYY.MM.DD are required\n' >&2; exit 2; }
# the released list is read once; one that names no dated tag would orphan every tag, so it is refused
released_list=""
if [[ -n "${released}" ]]; then
    [[ -r "${released}" ]] || { printf 'retain: cannot read --released %s\n' "${released}" >&2; exit 2; }
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line#v}"
        [[ "${line}" =~ ${dated} ]] && released_list+="${line}"$'\n'
    done < "${released}"
    [[ -n "${released_list}" ]] || { printf 'retain: --released %s names no dated tag; refusing to treat every tag as an orphan\n' "${released}" >&2; exit 2; }
fi

encoded="${package//\//%2F}"
api="/users/${owner}/packages/container/${encoded}/versions"
image="ghcr.io/${owner}/${package}"
sig_re='^sha256-[0-9a-zA-Z]+\.sig$'
index_re='(image\.index\.v1\+json|manifest\.list\.v2\+json)$'

# day_number YYYY.MM.DD → days since a fixed epoch (proleptic Gregorian), no date(1) dialect involved
day_number() {
    local y m d era yoe doy doe
    IFS=. read -r y m d <<<"$1"
    y=$((10#${y})); m=$((10#${m})); d=$((10#${d}))
    if ((m <= 2)); then y=$((y - 1)); fi
    era=$((y / 400)); yoe=$((y - era * 400))
    doy=$(((153 * ((m + 9) % 12) + 2) / 5 + d - 1))
    doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
    printf '%s\n' $((era * 146097 + doe))
}
today_n="$(day_number "${today}")"

# 1. the listing; a failure here ends the run before any delete
versions="$(gh api --paginate "${api}" | jq -s '[.[][] | {id, digest: .name, tags: .metadata.container.tags}]')" \
    || { printf 'retain: listing %s failed\n' "${package}" >&2; exit 1; }

# 2. kept dated tags: the released ones younger than max_age, plus the newest KEEP released ones
released_tags=""
all_dated="$(jq -r --arg re "${dated}" '.[] | .tags[] | select(test($re))' <<<"${versions}" | sort -r)"
while IFS= read -r t; do
    [[ -z "${t}" ]] && continue
    if [[ -z "${released}" ]] || grep -Fqx -- "${t}" <<<"${released_list}"; then released_tags+="${t}"$'\n'; fi
done <<<"${all_dated}"
kept_tags=""
rank=0
while IFS= read -r t; do
    [[ -z "${t}" ]] && continue
    rank=$((rank + 1))
    age=$((today_n - $(day_number "${t}")))
    if ((rank <= keep || age < max_age)); then kept_tags+="${t}"$'\n'; fi
done <<<"${released_tags}"
is_kept_tag() { grep -Fqx -- "$1" <<<"${kept_tags}"; }

# Every tagged version is kept (its children and signature stay referenced)
# except versions whose tags are all dated and none kept, and cosign signature
# tags, which step 4 judges.
kept_digests=""
delete_tagged=""
while IFS=$'\t' read -r id digest tags; do
    [[ -z "${tags}" || "${tags}" =~ ${sig_re} ]] && continue
    keep_this=false
    for t in ${tags}; do
        if [[ "${t}" == latest ]] || is_kept_tag "${t}"; then keep_this=true; fi
    done
    if [[ "${keep_this}" != true ]]; then
        only_dated=true
        for t in ${tags}; do [[ "${t}" =~ ${dated} ]] || only_dated=false; done
        if [[ "${only_dated}" == true ]]; then
            delete_tagged+="${id} ${tags}"$'\n'
            continue
        fi
    fi
    kept_digests+="${digest}"$'\n'
done < <(jq -r '.[] | [.id, .digest, (.tags | join(" "))] | @tsv' <<<"${versions}")

# a package with nothing to keep is not one this tool empties
if [[ -z "${kept_digests}" ]] && jq -e 'any(.[]; .tags | length == 0)' <<<"${versions}" >/dev/null; then
    printf 'retain: %s: nothing would be kept, refusing to empty the package\n' "${package}" >&2
    exit 1
fi

# 3. what the kept indexes reference: their children, the children of child indexes, and their signature tags
referenced="${kept_digests}"
pending="${kept_digests}"
seen=$'\n'
while [[ -n "${pending//$'\n'/}" ]]; do
    digest="${pending%%$'\n'*}"
    pending="${pending#*$'\n'}"
    [[ -z "${digest}" || "${seen}" == *$'\n'"${digest}"$'\n'* ]] && continue
    seen+="${digest}"$'\n'
    raw="$(docker buildx imagetools inspect --raw "${image}@${digest}")" \
        || { printf 'retain: cannot read index %s\n' "${digest}" >&2; exit 1; }
    children="$(jq -r '.manifests[]? | [.digest, (.mediaType // "")] | @tsv' <<<"${raw}")" \
        || { printf 'retain: index %s is not JSON\n' "${digest}" >&2; exit 1; }
    while IFS=$'\t' read -r child media; do
        [[ -z "${child}" ]] && continue
        referenced+="${child}"$'\n'
        if [[ "${media}" =~ ${index_re} ]]; then pending+="${child}"$'\n'; fi
    done <<<"${children}"
done
while read -r digest; do
    [[ -n "${digest}" ]] && referenced+="sha256-${digest#sha256:}.sig"$'\n'
done <<<"${kept_digests}"
is_referenced() { grep -Fqx -- "$1" <<<"${referenced}"; }

# 4. the untagged and signature versions no kept index references
delete_orphans=""
while IFS=$'\t' read -r id digest tags; do
    if [[ -z "${tags}" ]]; then
        is_referenced "${digest}" || delete_orphans+="${id} untagged"$'\n'
    elif [[ "${tags}" =~ ${sig_re} ]]; then
        is_referenced "${tags}" || delete_orphans+="${id} ${tags}"$'\n'
    fi
done < <(jq -r '.[] | [.id, .digest, (.tags | join(" "))] | @tsv' <<<"${versions}")

# 5. delete: dated tags first, then orphans; 400/404/409/410/422 are skipped and reported, anything else stops
deleted=0 skipped=0
delete_one() { # $1 id, $2 label
    local err
    if [[ "${dry_run}" == true ]]; then
        printf 'would delete %s %s\n' "$1" "$2"; deleted=$((deleted + 1)); return 0
    fi
    if err="$(gh api -X DELETE "${api}/$1" 2>&1 >/dev/null)"; then
        printf 'deleted %s %s\n' "$1" "$2"; deleted=$((deleted + 1)); return 0
    fi
    if [[ "${err}" =~ HTTP\ (400|404|409|410|422)([^0-9]|$) ]]; then
        printf 'retain: skipped %s %s (HTTP %s)\n' "$1" "$2" "${BASH_REMATCH[1]}" >&2
        skipped=$((skipped + 1)); return 0
    fi
    printf 'retain: delete %s (%s) failed: %s\n' "$1" "$2" "${err}" >&2
    exit 1
}
while read -r id label; do [[ -n "${id}" ]] && delete_one "${id}" "${label}"; done <<<"${delete_tagged}"
while read -r id label; do [[ -n "${id}" ]] && delete_one "${id}" "${label}"; done <<<"${delete_orphans}"
printf 'retain: %s: kept %s dated tag(s), deleted %s, skipped %s\n' "${package}" "$(grep -c . <<<"${kept_tags}" || true)" "${deleted}" "${skipped}"
