# CLAUDE.md

osnova: slim, multi-architecture base images that boot real systemd as PID 1, published unattended to GHCR.
The standards it is held to come from HQ; this file only points.

## Where things are

| Need | Location |
| --- | --- |
| What the project does and how to use it | `README.md` |
| Checks | `make lint`, `make test`; `make help` lists every target |
| Contribution rules | `CONTRIBUTING.md` |
| Security policy | `SECURITY.md` |
| The specification | `docs/SPEC.md` |
| Every workflow, permission and action | `docs/reference/pipeline.md` |
| Running the images | `docs/how_to/use_the_images.md` |
| How a change to an image, the matrix or the pipeline is made | `.claude/skills/_osnova_development/SKILL.md` |

## Critical rules

- The SPEC wins over code, docs, skills, this file and any conversation. A
  SPEC change is a diff the owner approves first; its commit precedes the
  implementation.
- Never bypass pre-commit or commit signing; a red hook is fixed, not skipped.
- Local changes and local commits only. Push, pull request, tag and release
  are the owner's actions.
- Images are built, scanned and booted locally; nothing is ever published from a developer machine. The release workflow alone pushes, tags and signs.
- Secrets never enter the repository, a log or a command argument.
- `CHANGELOG.md` gains an `[Unreleased]` line for every user-visible change.

## Model triage

| Model | Use for |
| --- | --- |
| opus or fable | architecture and cross-cutting changes |
| sonnet | features, fixes, tests, reviews |
| haiku | typo, comment and single-line lint fixes |
