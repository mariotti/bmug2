# Contributing

bmug2 is developed like any team project, even though today it has a
single maintainer:

1. Branch off an up-to-date `main` (`git checkout -b feature/<name>`).
2. Commit there, add or update tests under `tests/` for any behavior
   change, and keep `sh tests/test_backmeup.sh` green locally.
3. Push the branch and open a pull request (`gh pr create` or the
   GitHub UI).
4. Wait for CI: GitHub Actions runs the suite on Linux (rsync +
   plocate) and macOS (Homebrew rsync + findutils) — both must pass.
5. Squash-merge the PR once it's reviewed. `main` is protected: direct
   pushes are rejected, and merging requires both checks green and the
   branch up to date with `main`.

The branch is deleted automatically on merge.

## Commit messages

Explain *why*, not just *what* — the diff already shows what changed.
Mention any bug found while testing and how it was confirmed, not just
the fix.

## Tests

New behavior needs a test that would fail without the change. The
suite (`tests/test_backmeup.sh`, using the bundled `shunit2`) replays
real backup scenarios in a temporary sandbox rather than mocking
`rsync`/`updatedb` — see existing tests for the pattern.
