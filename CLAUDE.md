# herdr-hunk-review

A Claude Code plugin, developed in its own standalone repository. Conventions from any
surrounding workspace (branch naming, promotion chains, required reviewers) do NOT apply
here. Work on `main`.

## Versioning

- The version lives in `.claude-plugin/plugin.json` and changes **only at a release**.
- To release: `sh scripts/bump.sh [patch|minor|major]`, commit as
  `chore: release <version>`, then `git tag v<version>` and `git push --follow-tags`.
- Ordinary commits never touch the version.
- The README badge reads the newest git tag from GitHub — never hand-edit it.

## Commits

- Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`).
- Stage specific files; no `git add -A` outside a release commit.
- **Never add `Co-Authored-By`, "Generated with Claude Code", or any robot footer**
  to a commit message or PR description.

## Shell rules

Target POSIX `sh`; `/bin/bash` here is 3.2. No `flock` (use `mkdir` locking), no
`sha256sum`/`shasum` (a missing `shasum` makes both sides of a hash comparison resolve
to the same empty string and silently discards real changes — use `cmp -s` to compare
file content directly instead). Every hook exits 0 and writes nothing to stdout.

## Tests

`bats tests/` — requires `brew install bats-core`.
