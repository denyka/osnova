# Tags

## Scheme

| Tag | Meaning |
| --- | --- |
| `YYYY.MM.DD` | The UTC date of the release run. Immutable while it exists |
| `latest` | The newest release. Moved last, after the release exists |

The git tag is `vYYYY.MM.DD`. There is no other tag: the distribution major
is in the image name.

## Registry paths

`ghcr.io/denyka/osnova/<image>:<tag>`, for each image in
[images](images.md). Signatures are stored beside the image as
`sha256-<digest>.sig` tags.

## Retention

After every successful publish, per image, `tools/retain.sh` runs
([SPEC 8.7](../SPEC.md)).

| Kept | Deleted |
| --- | --- |
| `latest` | every dated tag older than ninety days beyond the five newest that a GitHub release names |
| every released dated tag younger than ninety days | every dated tag no release names: the orphans of failed runs, at any age |
| the five newest dated tags a release names, whatever their age | untagged versions no kept index references |
| the manifests, attestations and signature of a kept index | signature tags no kept index references |

The tags the GitHub releases name are the input to retention: the `retain`
job lists them before it runs, and a list that names no dated tag stops the
script before it lists anything, because the release job always precedes
retention and an empty list is a failed listing, not an empty registry.
Ninety days is the window a consumer has to move a pin; the floor of five is
what a consumer finds when releases are rare. Never deleted: git tags,
GitHub releases and `record.json`.

Everything to delete is computed before the first delete. A failed listing
or index read stops the script before any delete. A delete GHCR refuses with
a client error that means the version cannot or need not be deleted (400,
the answer for a public version with more than five thousand downloads; 404,
already gone; 409, 410, 422) is reported and skipped. An authentication or
authorisation error (401, 403), a timeout or rate limit (408, 429) and any
other failed delete stop the script and fail the run, leaving the registry
serving: a retention that silently skipped every delete for want of a scope
would never be noticed.

A retired image's dated tags are kept forever: retention iterates the
current matrix only ([SPEC 6.1](../SPEC.md)), so it never visits a retired
image's package again.

## Pin

By tag:

```bash
docker pull ghcr.io/denyka/osnova/debian13:2026.10.19
```

By digest, from the release notes or `record.json`:

```bash
docker pull ghcr.io/denyka/osnova/debian13@sha256:<digest>
```

A pin older than ninety days, and beyond the five newest releases, stops
resolving. Mirror the image to keep it longer ([use the images](../how_to/use_the_images.md)).
