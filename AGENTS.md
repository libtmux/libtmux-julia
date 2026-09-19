# Agent instructions

Follow the conventions already in the tree, and keep changes scoped to the
requested work.

## Which policy applies

- Setup, checks, and pull requests: [CONTRIBUTING.md](CONTRIBUTING.md).
- Documentation, user-facing text, comments, and commit messages:
  [WRITING.md](WRITING.md).

Each guide is the single home for its subject.

## Change discipline

- Check the current branch, working tree, and relevant source before editing.
  Preserve unrelated changes.
- Make the smallest coherent change that solves the verified problem. Keep
  unrelated cleanup out of it.
- Reuse an existing file, helper, API, or test before adding a new one.
- Add files for distinct responsibilities or independent reuse, not one-line
  re-exports or single-use helpers.
- Keep implementation details out of the public API until a caller needs them.
- Use language-native conventions. Sibling ports are references for behavior;
  their tooling and package layouts do not automatically apply here.
- Add tests for critical behavior. Confirm that a regression test fails for
  the intended reason before relying on its passing result.
- Run checks appropriate to the change and report what passed, failed, or was
  skipped. A skipped check is not a passing check.
- Prefer `rg`, `ag`, and `fd` for searches. Use `jq` for JSON.

## Shared resources

Give each tmux test or probe a unique, owned socket in a directory scoped to
this port. Clear inherited `TMUX` and `TMUX_PANE` values. Never use the default
tmux server for tests, and only stop servers or remove files owned by the run.
