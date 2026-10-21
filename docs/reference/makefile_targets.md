# Makefile targets

`make` or `make help` prints the list. Source: `Makefile`.

## Quality

| Target | Help | Tunables |
| --- | --- | --- |
| `help` | Show this help | |
| `lint` | Run every linter (pre-commit on all files) | `PRE_COMMIT` |
| `format` | Auto-fix whitespace and end-of-file | `PRE_COMMIT` |
| `test` | Run every suite under `tests/` | `OSNOVA_SMOKE_IMAGE` (the smoke suite runs only when set) |

## Development

| Target | Help | Tunables |
| --- | --- | --- |
| `install-hooks` | Install the pre-commit git hooks | `PRE_COMMIT` |
| `clean` | Remove throwaway scratch and editor leftovers | |

## Images

| Target | Help | Tunables |
| --- | --- | --- |
| `build` | Resolve the bases, then bake every target for this host's architecture, loaded locally | |
| `smoke` | Boot `IMAGE=<ref>` under both run contracts and assert the systemd contract | `IMAGE` |
| `scan` | Trivy IMAGE=<ref> with the pipeline's settings: fixable HIGH and CRITICAL fail | `IMAGE` |
| `digests` | Print the live base digests the next build would use | |

`scan` scans the local image only (`--image-src docker`), never the
registry. `IMAGE` defaults to `ghcr.io/denyka/osnova/debian13:latest`.
`make build` loads that tag for the host's architecture. Nothing in the
Makefile publishes ([SPEC 11](../SPEC.md)).
