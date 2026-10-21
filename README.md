# osnova

osnova (Ukrainian: foundation) publishes slim, multi-architecture base images that boot real systemd as PID 1: AlmaLinux 9 and 10, Debian 12 and 13, Ubuntu 24.04 and 26.04, for testing configuration tooling and as a base for anything that needs a manageable systemd system in a container. Images are built, scanned, booted, signed and published unattended to GHCR.

Pull:

```bash
docker pull ghcr.io/denyka/osnova/debian13:latest
```

Run:

```bash
docker run -d --name box \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  ghcr.io/denyka/osnova/debian13:latest
```

systemd needs the host cgroup namespace, the cgroup tree writable, one added capability and Docker's default AppArmor profile lifted on the hosts that carry one; these are the least that boot it. The images are for trusted development machines and CI runners, never a shared or production host.

Verify:

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp \
    '^https://github\.com/denyka/osnova/\.github/workflows/release\.yml@refs/heads/main$' \
  ghcr.io/denyka/osnova/debian13:latest
```

The same identity verifies the signed release record, and every index also
carries a GitHub artifact attestation:

```bash
gh attestation verify oci://ghcr.io/denyka/osnova/debian13:latest --repo denyka/osnova
```

The record check, the provenance and the SBOM are in
[verify a release](docs/how_to/verify_a_release.md). A dated tag is kept
for ninety days and never fewer than the five newest releases; pin by
digest and mirror the image to keep it longer
([tags](docs/reference/tags.md)).

## Documentation

| Page | Holds |
| --- | --- |
| [SPEC](docs/SPEC.md) | The source of truth |
| [Security](docs/security.md) | Threat model, run contract exposure, supply chain |
| [Use the images](docs/how_to/use_the_images.md) | Docker, Molecule, Podman, pinning |
| [Verify a release](docs/how_to/verify_a_release.md) | Signature, attestation, record, SBOM, provenance |
| [Add a distro](docs/how_to/add_a_distro.md) | Change the matrix |
| [Run a release](docs/how_to/run_a_release.md) | Dispatch, failure issues, recovery |
| [Images](docs/reference/images.md) | Matrix, baseline, masked units, labels |
| [Tags](docs/reference/tags.md) | Scheme, paths, retention |
| [Pipeline](docs/reference/pipeline.md) | Every workflow, permission and action |
| [Makefile targets](docs/reference/makefile_targets.md) | Every target |
| [Decisions](docs/adr/) | The four ADRs |
| [Changelog](CHANGELOG.md) | What changed |
| [Contributing](CONTRIBUTING.md) | Contribution rules |
| [Security policy](SECURITY.md) | Reporting a vulnerability |
| [Code of conduct](CODE_OF_CONDUCT.md) | Conduct |
| [License](LICENSE) | MIT |

## Develop

```bash
make help                  # every target
make build                 # bake every image for this host, loaded locally
make smoke IMAGE=<ref>     # boot an image and assert the systemd contract
make lint
make test
```

Nothing publishes from a developer machine: the release workflow alone
pushes, tags and signs.
