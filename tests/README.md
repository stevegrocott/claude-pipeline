# tests/

BATS test suite for the decision-script layer (`decide-action.sh`,
`decide-retry.sh`, `decide-model-fallback.sh`).

## Prerequisites

- [bats-core](https://github.com/bats-core/bats-core) **>= 1.5.0**
  (`bats_require_minimum_version` is declared in every file and will
  fail fast on older versions)
- `jq` (used both by the scripts under test and by assertion helpers)
- `claude` CLI — required only for the live-API tests
  (`*-live.bats`); all other tests mock it

Install on macOS:

```sh
brew install bats-core jq
```

Install on Ubuntu/Debian:

```sh
sudo apt-get install bats jq
```

## Running the suite

```sh
# All tests (from repo root)
bats tests/

# Single file
bats tests/decide-action.bats

# Skip live-API tests (no ANTHROPIC_API_KEY required)
bats tests/ --filter-tags '!live'
# — or target only the golden/unit files explicitly:
bats tests/decide-action.bats \
     tests/escalation-policy-golden.bats \
     tests/retry-policy-golden.bats \
     tests/model-fallback-golden.bats \
     tests/triage-classify-golden.bats
```

Set `ANTHROPIC_API_KEY` in your environment before running
`retry-policy-live.bats`; without it the live tests call the real
Claude API and will fail with an auth error.

CI (`skill-golden.yml`) uses the same commands:
- **With** `ANTHROPIC_API_KEY`: `bats tests/`
- **Without** `ANTHROPIC_API_KEY`: runs every `*.bats` file whose name
  does **not** end in `-live.bats`

## Environment variables

| Variable | Default | Effect |
|---|---|---|
| `ESCALATION_POLICY_BACKEND` | `claude` | `bash` forces the inline decision tree in `decide-action.sh`, skipping the Claude skill invocation |
| `RETRY_POLICY_BACKEND` | `claude` | `bash` forces the inline tree in `decide-retry.sh` |
| `MODEL_FALLBACK_BACKEND` | `claude` | `bash` forces the inline tree in `decide-model-fallback.sh` |
| `ANTHROPIC_API_KEY` | — | Required for live-API tests (`retry-policy-live.bats`) |

## Test files

### `decide-action.bats`

Unit tests for `.claude/scripts/decide-action.sh` — the orchestrator
glue between the pipeline and the `escalation-policy` skill.

The script accepts a `stage_result` JSON envelope and an escalation
history, delegates to `decide-retry.sh` via `_compose_decide`, and
returns a `{action, model?, reason}` envelope to stdout.  When
`ESCALATION_POLICY_BACKEND=bash` is set, or when the skill returns
schema-invalid JSON, it falls back to an inline bash decision tree so
the orchestrator never crashes mid-flight.

Tests:
1. `ESCALATION_POLICY_BACKEND=bash` returns a valid action via the
   inline tree and never invokes the skill (tripwire mock).
2. Schema-invalid skill output triggers the bash fallback without
   crashing.
3. Valid skill output is echoed through to stdout (round-trips
   `action`, `model`, and `reason` fields).
4. `status=success` without `.output.status` produces `accept` (bash
   backend) — regression for issue #252.
5. `status=success` without `.output.status` produces `accept`
   (compose backend) — same regression, compose path.
6. `_compose_decide` returns non-zero and emits a diagnostic for an
   unrecognised `retry_action` value.

---

### `escalation-policy-golden.bats`

Golden fixture tests for the escalation-policy bash decision tree
inside `decide-action.sh`.

Drives the script with `ESCALATION_POLICY_BACKEND=bash` and
pre-baked JSON fixtures from `tests/fixtures/escalation-policy/`.
No live Claude invocations.

Decision paths pinned:
- **accept** — `accept-success.json`: `status=success` with valid
  output and no `error_kind`
- **escalate** — `timeout-first-attempt.json`: timeout on haiku
  → `model=sonnet`
- **bail** — `bail-permission-denied.json`: `permission_denied` →
  unrecoverable
- **retry_same** — `retry-same-rate-limit.json`: `rate_limit` on
  first attempt with empty history

---

### `retry-policy-golden.bats`

Golden fixture tests for the retry-policy bash decision tree inside
`decide-retry.sh`.

Drives the script with `RETRY_POLICY_BACKEND=bash` and fixtures from
`tests/fixtures/retry-policy/`.  No live Claude invocations.

Decision paths pinned:
- **retry** — `retry-under-limit.json`: `rate_limit` on first attempt
  → retry with `backoff_ms`
- **escalate** — `at-limit-escalate.json`: timeout at `retry_count=1`
  meets the limit → escalate haiku to sonnet
- **bail** — `unretryable-bail.json`: `permission_denied` is never
  retryable

---

### `retry-policy-live.bats`

Tests for the live (Claude) backend path of `decide-retry.sh`.
Requires `ANTHROPIC_API_KEY` in CI; locally it installs a mock
`claude` binary to verify routing without hitting the real API.

Tests:
1. `RETRY_POLICY_BACKEND=bash` does not invoke claude (tripwire).
2. `RETRY_POLICY_BACKEND=claude` passes valid `retry` action JSON
   through to stdout, including `backoff_ms`.
3. Unset `RETRY_POLICY_BACKEND` routes to the claude path, not bash.
4. `RETRY_POLICY_BACKEND=claude` forwards a `bail` action from claude
   unchanged.

---

### `model-fallback-golden.bats`

Golden fixture tests for the model-fallback bash decision tree inside
`decide-model-fallback.sh`.

Drives the script with `MODEL_FALLBACK_BACKEND=bash` and fixtures from
`tests/fixtures/model-fallback/`.  No live Claude invocations.

Decision paths pinned:
- **upgrade** — `haiku-timeout-upgrade.json`: timeout on haiku →
  `next_model=sonnet`
- **upgrade** — `sonnet-timeout-upgrade.json`: timeout on sonnet →
  `next_model=opus`
- **ceiling** — `opus-ceiling.json`: error on opus →
  `at_ceiling=true`, `next_model=null`
- **no-upgrade** — `unknown-error-no-upgrade.json`: unrecognised
  `error_kind` → `next_model=null`, `at_ceiling=false`

---

### `triage-classify-golden.bats`

Golden fixture tests for the `triage-classify` skill.

Sources `skill-golden-lib.sh` and `prompts/triage-prompt.sh` in
process, installs a mock `claude` binary (routed via
`MOCK_CLAUDE_ROUTE`), and asserts routing outcomes without live Claude
invocations.  Fixtures live in
`.claude/scripts/implement-issue-test/fixtures/triage/`.

Decision paths pinned:
- **fast-path** — `issue-2836.md`: all six criteria pass →
  `route=fast-path`
- **full** — `issue-2752.md`: `test_only_scope` fails (non-test files
  in scope) → `route=full`
- **disqualify** — `issue-auth-test.md`: `no_security_concerns` fails
  (auth login flow) → `route=full`

## Fixtures

`tests/fixtures/` holds the JSON envelopes consumed by the golden
tests.  Each sub-directory maps to one script:

```
tests/fixtures/
  escalation-policy/   # decide-action.sh golden inputs
  retry-policy/        # decide-retry.sh golden inputs
  model-fallback/      # decide-model-fallback.sh golden inputs
```

Triage fixtures live with the skill implementation rather than here:
`.claude/scripts/implement-issue-test/fixtures/triage/`.
