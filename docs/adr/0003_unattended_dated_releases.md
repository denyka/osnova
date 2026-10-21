# 0003. Unattended dated releases

- Status: accepted
- Date: 2026-10-19

## Context

A base image has no interface with breaking changes. Its value is freshness: upstream patches applied and a known state recorded. The project has one owner and no collaborators.

## Decision

Releases are calendar-versioned by build date (`vYYYY.MM.DD`, image tag `YYYY.MM.DD`) and run unattended: monthly, on the daily watch's dispatch, or by hand ([SPEC 8.1, 8.2](../SPEC.md)). Every gate runs on every release; a failure publishes nothing and opens an issue.

## Options considered

- Semantic versioning with manual tags. Rejected: nothing in a base image is an interface, and a human in the loop makes patches late.
- Scheduled rebuilds without gates. Rejected: an unreviewed image would publish with known fixable findings or a broken boot.
- Drift reported as issues for the owner to act on. Rejected: it turns every upstream patch into manual work.
- Dated, gated, unattended releases. Accepted.

## Consequences

- A release is a date; one per UTC day, a second fails in `prepare` on purpose.
- Old images accumulate known vulnerabilities, so retention keeps `latest`, every dated tag younger than ninety days and never fewer than the five newest a release names ([SPEC 8.7](../SPEC.md)). A count alone was the first design; the watch rebuilds on every base move, so five releases can be days apart, and age is what a consumer can plan around. A pin older than that stops resolving; the git tag, release and `record.json` stay.
- A publish that fails part way leaves dated tags no release names; retention deletes them ([SPEC 8.6](../SPEC.md)).
- The changelog header states calendar versioning, a declared deviation from HQ ([SPEC 14](../SPEC.md)).
