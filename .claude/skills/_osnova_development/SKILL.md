---
name: _osnova_development
description: Use when changing an image, the matrix, a Dockerfile, the bake file, a tool under tools/, a suite under tests/ or a workflow in osnova.
---

# osnova development

The SPEC wins ([SPEC 2](../../../docs/SPEC.md)). Read the section that covers
the change before editing:

| Change | SPEC section |
| --- | --- |
| Images, matrix, Dockerfiles, labels | 6 |
| Run contract, smoke suite | 7 |
| Release workflow, retention, permissions | 8 |
| The watch | 9 |
| Suites | 12 |

A SPEC change is a diff the owner approves first.

## Procedure

1. Write the failing check first, in the suite that owns the rule
   (`tests/matrix.sh`, `dockerfiles.sh`, `workflows.sh`, `tools.sh`, `smoke.sh`).
2. Make the change.
3. An image change is proven on this host: `make build`, then
   `make smoke IMAGE=ghcr.io/denyka/osnova/<name>:latest`.
4. `make lint`, then `make test`.
5. Run the four HQ checks from HQ's `.claude/tools/`:
   - `check_templates.sh --applies docker,docker_bake,github .` reports two
     declared deviations ([SPEC 14](../../../docs/SPEC.md)): the CHANGELOG
     header states calendar versioning, and the `docker_bake.yml` workflow
     is not carried. Anything else is drift.
   - `check_conventions.sh .` and `audit_project.sh .` report clean.
   - `audit_security.sh .` reports four findings today: the local composite
     action reads as unpinned (`ci.yml`, `release.yml`), and `release.yml`
     and `watch.yml` carry job-level permissions blocks (both declared,
     SPEC 14). Any other finding is new.
6. Add a line under `[Unreleased]` in `CHANGELOG.md` for a user-visible change.

## Hard rules

Nothing is published from a developer machine
([SPEC 11 and 13](../../../docs/SPEC.md)); the invariants every change must
keep are in [SPEC 2](../../../docs/SPEC.md) and its section 15. A SPEC
change is approved by the owner first.

## Pages

- [Use the images](../../../docs/how_to/use_the_images.md)
- [Verify a release](../../../docs/how_to/verify_a_release.md)
- [Add a distro](../../../docs/how_to/add_a_distro.md)
- [Run a release](../../../docs/how_to/run_a_release.md)
- [Pipeline](../../../docs/reference/pipeline.md)
- [Images](../../../docs/reference/images.md)
