# 0004. Digests recorded, not committed

- Status: accepted
- Date: 2026-10-19

## Context

HQ pins every base image by digest in the tree. An unattended pipeline would have to commit the pin bumps back to `main`.

## Decision

`matrix.yml` holds the base tag. The digest is resolved at build time by `tools/resolve_bases.sh` and recorded in the image labels, the provenance and the signed release's `record.json` ([SPEC 8.4](../SPEC.md)).

## Options considered

- A bot credential commits pin bumps, with a branch-ruleset bypass for it. Rejected: security first refuses a standing write credential and a bypass on the protected branch.
- Pull requests opened by a bot. Rejected: the same credential, and a human gate the unattended design removes.
- Resolve at build and record. Accepted.

## Consequences

- The tree never shows which base digest the last release used; the record does, and the record is signed as a blob by the release workflow identity and published on an immutable release, so the pin it replaces is as trustworthy as the tree would have been ([SPEC 8.4](../SPEC.md)).
- A rebuild from a given commit may resolve a newer base; the record names the one that was used.
- A declared deviation from HQ's pinning rule ([SPEC 14](../SPEC.md)).
