# Verify a release

Every index is signed keyless by the release workflow. Verification checks
the signature against that workflow's identity on `main` and nothing else.

## Verify the signature

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp \
    '^https://github\.com/denyka/osnova/\.github/workflows/release\.yml@refs/heads/main$' \
  ghcr.io/denyka/osnova/debian13:latest
```

Expect cosign to report that the claims were validated, the signature was
verified against the transparency log, and the certificate was verified
against the identity above. It prints the signed payload as JSON.

The signatures are stored in cosign's legacy tag form: one
`sha256-<index digest>.sig` tag beside the image in the same repository, not
an OCI referrer. The release signs that way
(`--new-bundle-format=false --use-signing-config=false`) because retention
and [SPEC 8.7](../SPEC.md) rely on the tag. cosign 3 verifies the legacy
form unchanged, with the command above. To see the signature attached to an
index:

```bash
cosign tree ghcr.io/denyka/osnova/debian13:<date>
```

An image published any other way does not verify, by design: a build from
a developer machine, from another branch or from another workflow carries a
different identity or none.

## Verify the attestation

Every index also carries a GitHub artifact attestation, a SLSA provenance
statement bound to the same repository:

```bash
gh attestation verify oci://ghcr.io/denyka/osnova/debian13:latest --repo denyka/osnova
```

## Read and verify the record

`record.json` and its signature `record.json.sigstore.json` are attached to
every GitHub release, which is immutable. Fetch the latest and verify the
record with the same identity before trusting it:

```bash
gh release download --repo denyka/osnova --pattern 'record.json*'
cosign verify-blob \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp \
    '^https://github\.com/denyka/osnova/\.github/workflows/release\.yml@refs/heads/main$' \
  --bundle record.json.sigstore.json record.json
```

It holds the dated tag, the commit, the run URL and, per image, the index
digest, the base tag, the base index digest and the base digest per
architecture ([SPEC 8.4](../SPEC.md)).

## Inspect the SBOM and the provenance

The record carries index digests. The SBOM and the provenance are attached
to the per-architecture manifests the index lists. Inspecting the index
digest prints a map keyed by platform:

```bash
docker buildx imagetools inspect ghcr.io/denyka/osnova/debian13@<index digest> --format '{{json .SBOM}}'
docker buildx imagetools inspect ghcr.io/denyka/osnova/debian13@<index digest> --format '{{json .Provenance}}'
```

To reach one architecture's manifest digest, read the index:

```bash
docker buildx imagetools inspect ghcr.io/denyka/osnova/debian13@<index digest> --raw \
  | jq -r '.manifests[] | select(.platform.architecture == "amd64") | .digest'
```

## Compare a pulled digest with the record

```bash
docker buildx imagetools inspect ghcr.io/denyka/osnova/debian13:latest --format '{{.Manifest.Digest}}'
jq -r '.images[] | select(.name == "debian13") | .digest' record.json
```

The two digests match while `latest` is the release the record describes.
To pin by digest, use the value from the record
([use the images](use_the_images.md)). A dated tag older than ninety days
may be gone; the record stays ([tags](../reference/tags.md)).
