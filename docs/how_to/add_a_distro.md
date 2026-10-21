# Add a distro

The matrix carries exactly two majors per distribution, LTS releases only
for Ubuntu ([SPEC 6.1](../SPEC.md)). Adding a major retires the oldest of
that distribution in the same change.

## Steps

1. Add the entry to `matrix.yml`: name, family and base tag. No digest.
   The name is lower-case letters and digits, the distribution and its
   major with no separator.
2. In `docker-bake.hcl`, add the `BASE_<NAME>` variable with the bare tag
   as its default, a target that inherits `_el` or `_deb`, and the target's
   line in the `default` group.
3. Remove the oldest major of the distribution from `matrix.yml` and from
   the bake file: its variable, its target, its group line.
4. Build and boot it on this host:

   ```bash
   make build
   make smoke IMAGE=ghcr.io/denyka/osnova/<name>:latest
   ```

5. Run `make test`. `tests/matrix.sh` checks the two-majors rule, the
   names, and that every image has a bake target and a Dockerfile.
6. Update [images](../reference/images.md) and the SPEC's matrix; the SPEC
   change is the owner's to approve first.

## A new family

A family without a Dockerfile needs one under `images/<family>/`. Its
`ARG BASE_IMAGE` default is the newest base of that family's first
distribution, which `tests/matrix.sh` enforces. It follows the build contract of [SPEC 6.3](../SPEC.md) and keeps the masked
unit loop byte-identical to the other families; `tests/dockerfiles.sh`
checks it.

## Then

The pull request runs `ci.yml`. The next release publishes the new image,
and the watch dispatches one when an image is missing from the latest
record. A retired image's dated tags are kept forever: retention iterates
the current matrix only ([SPEC 6.1](../SPEC.md)), so it never visits a
retired image's package again.
