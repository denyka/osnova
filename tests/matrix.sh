#!/usr/bin/env bash
# matrix.yml holds name, family and base tag only (SPEC 6.1); every image has a
# bake target and a family Dockerfile; two majors per distribution.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
cd "${T_ROOT}" || exit 1

t_assert_file matrix.yml
t_assert_grep '^images:$' matrix.yml
# only the three keys, each exactly once per entry, in this order
keys="$(grep -E '^[[:space:]]+(- )?[a-z_]+:' matrix.yml | sed -E 's/^[[:space:]]+(- )?([a-z_]+):.*/\2/' | paste -sd' ' -)"
expected="$(printf 'name family base %.0s' 1 2 3 4 5 6 | sed 's/ $//')"
t_assert_eq "${expected}" "${keys}" "matrix.yml carries name, family, base per image and nothing else"
names="$(awk '/^[[:space:]]+- name:/{print $3}' matrix.yml | paste -sd' ' -)"
t_assert_eq "almalinux9 almalinux10 debian12 debian13 ubuntu2404 ubuntu2604" "${names}" "the six images in SPEC order"
while read -r name family base; do
    if [[ "${name}" =~ ^[a-z]+[0-9]+$ ]]; then t_ok "name pattern: ${name}"; else t_fail "name pattern: ${name}"; fi
    if [[ "${family}" == el || "${family}" == deb ]]; then t_ok "${name}: family ${family}"; else t_fail "${name}: family ${family}"; fi
    if [[ "${base}" =~ ^[a-z]+:[a-z0-9.-]+$ ]]; then t_ok "${name}: base is a bare tag: ${base}"; else t_fail "${name}: base must be image:tag with no digest: ${base}"; fi
    t_assert_dir "images/${family}"
    t_assert_file "images/${family}/Dockerfile"
    t_assert_grep "^target \"${name}\" \\{" docker-bake.hcl
    upper="$(printf '%s' "${name}" | tr '[:lower:]' '[:upper:]')"
    t_assert_grep "^variable \"BASE_${upper}\" \\{" docker-bake.hcl
    # the default sits in this image's own variable block, not another's
    block_default="$(awk -v v="BASE_${upper}" '$0 ~ "^variable \"" v "\" \\{"{p=1;next} p&&/^}/{p=0} p&&/default *=/{gsub(/.*= *"|".*/,""); print}' docker-bake.hcl)"
    t_assert_eq "${base}" "${block_default}" "${name}: variable BASE_${upper} defaults to ${base}"
    # the target wires its own base variable, nobody else's
    wired="$(awk -v t="${name}" '$0 ~ "^target \"" t "\" \\{"{p=1;next} p&&/^}/{p=0} p&&/args/{print}' docker-bake.hcl | sed -E 's/.*BASE_IMAGE *= *([A-Z0-9_]+).*/\1/')"
    t_assert_eq "BASE_${upper}" "${wired}" "${name}: args wire BASE_${upper}"
done < <(awk '/^[[:space:]]+- name:/{n=$3} /^[[:space:]]+family:/{f=$2} /^[[:space:]]+base:/{gsub(/"/,"",$2); print n, f, $2}' matrix.yml)
# each family Dockerfile defaults to the newest base of its own distribution
# (highest major): the debian and ubuntu bases share one family, the default
# names debian, so newest is taken among the entries of that distribution.
for family in el deb; do
    f="images/${family}/Dockerfile"
    default="$(sed -n 's/^ARG BASE_IMAGE=//p' "${f}")"
    distro="${default%%:*}"
    newest="$(awk -v d="${distro}" '/^[[:space:]]+base:/{gsub(/"/,"",$2); b=$2; split(b,a,":"); if (a[1]==d) {m=a[2]; sub(/^[^0-9]*/,"",m); sub(/[^0-9].*$/,"",m); print m+0, b}}' matrix.yml | sort -n | tail -1 | cut -d' ' -f2)"
    t_assert_eq "${newest}" "${default}" "${f}: ARG BASE_IMAGE default is the newest ${distro} base in matrix.yml"
done
# two majors per distribution (letters prefix)
dup="$(awk '/^[[:space:]]+- name:/{print $3}' matrix.yml | sed -E 's/[0-9]+$//' | sort | uniq -c | awk '$1 != 2 {print $2}')"
t_assert_eq "" "${dup}" "exactly two majors per distribution"
# the default group lists every image
for n in ${names}; do t_assert_grep "^[[:space:]]+\"${n}\",\$" docker-bake.hcl; done
t_assert_not_grep 'sha256:' matrix.yml
t_finish
