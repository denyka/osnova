# Contributing

1. Open an issue before a large change so the approach is agreed first.
2. Branch from the default branch; keep one change per pull request.
3. `make install-hooks` once; every commit then passes the hooks, and
   `make lint` and `make test` are green before you push. A red hook is
   fixed, never bypassed.
4. Commits are signed and follow Conventional Commits
   (`feat:`, `fix:`, `docs:`, `chore:`).
5. Update `CHANGELOG.md` under `[Unreleased]` with the user-visible change.
