# Fix pipeline change-scope detection for .claude/**/*.bats files

The `detect_change_scope` function in `orchestrator.sh` incorrectly tags
`.claude/**/*.bats` files as "config" scope, causing pipeline test loops to
be skipped. BATS test files under `.claude/` are pipeline tests, not config.

## Implementation Tasks

- **(M)** In `.claude/scripts/implement-issue-test/triage-classify-golden.bats`,
  add a golden routing test asserting that an issue touching only
  `.claude/**/*.bats` files is routed to `full`, not `fast-path`.

- **(S)** In `.claude/scripts/implement-issue-test/test-detect-scope.bats`,
  update the scope detection tests to cover `.bats` files under `.claude/`.

## Affected files
- `.claude/scripts/implement-issue-test/triage-classify-golden.bats`
- `.claude/scripts/implement-issue-test/test-detect-scope.bats`

## Acceptance criteria

- A golden fixture covering `.claude/**/*.bats`-only issues routes to `full`
- `detect_change_scope` returns "pipeline" (not "config") for `.bats` files
