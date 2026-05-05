---
name: retry-policy
description: Use when a pipeline stage fails and you must decide whether to retry at the same model, escalate to a higher tier, or bail permanently — applies per-error-class retry limits, exponential back-off for rate-limit errors, and a clear threshold at which retry becomes escalation.
inputs:
  stage_result: "JSON envelope from run_stage(): {status, output, error_kind, model, elapsed_ms, raw, denials}"
  retry_count: "Integer — number of retries already attempted for this stage at the current model tier"
  error_history: "Array of prior failure records for this stage: [{error_kind, model, elapsed_ms}]"
outputs:
  action: '"retry" | "escalate" | "bail"'
  reason: "Human-readable rationale for the decision"
  backoff_ms: "Milliseconds to wait before retrying (only present when action == \"retry\" and error_kind == \"rate_limit\")"
failure_modes:
  - id: retrying_max_turns_exhausted
    mitigation: "Escalate instead — more turns cannot be given to an already-exhausted run at the same model"
  - id: retrying_unrecoverable_error
    mitigation: "Bail immediately; permission_denied and schema_not_found are configuration errors no retry can fix"
  - id: missing_backoff_on_rate_limit
    mitigation: "Always include backoff_ms and wait the computed delay before retrying on rate_limit errors"
  - id: escalating_at_opus_ceiling
    mitigation: "Check model tier before escalating; bail if already at opus ceiling"
  - id: retry_when_at_threshold
    mitigation: "Escalate when retry_count meets max_retries or error_history shows the same error_kind at the same model"
---

# retry-policy

## Overview

Given a `stage_result`, a `retry_count`, and the `error_history` for the current model tier, decide whether to retry the stage at the same model (with optional back-off), escalate to the next model tier, or bail permanently.

This skill is the **intra-tier** counterpart to `escalation-policy`. Escalation-policy handles the cross-tier routing decision; retry-policy answers: "before we escalate, should we try again at the same tier?"

## Input Contract

### `stage_result`

```json
{
  "status":     "success | error | rate_limit",
  "output":     "<object | null>",
  "raw":        "<string>",
  "denials":    ["<tool_name>"],
  "model":      "haiku | sonnet | opus",
  "error_kind": "timeout | schema_not_found | no_structured_output | max_turns_exhausted_at_ceiling | rate_limit | permission_denied | null",
  "elapsed_ms": 12345
}
```

### `retry_count`

Integer. Number of retries already attempted at the **current model tier**. Starts at `0` before the first retry (i.e. the initial stage run just failed and no retry has been attempted yet).

### `error_history`

Array of prior failures at the **current model tier** for this stage:

```json
[
  { "error_kind": "timeout",   "model": "haiku", "elapsed_ms": 60000 },
  { "error_kind": "rate_limit","model": "haiku", "elapsed_ms": 2100  }
]
```

Filter to records where `model == stage_result.model` before reasoning.

## Output Contract

```json
{
  "action":     "retry | escalate | bail",
  "reason":     "<human-readable string>",
  "backoff_ms": 30000
}
```

`backoff_ms` is **only present** when `action == "retry"` and `error_kind == "rate_limit"`. Omit it for all other cases.

---

## Max Retries Per Error Class

| `error_kind`                    | Max same-tier retries | Action when exceeded |
|---------------------------------|-----------------------|----------------------|
| `rate_limit`                    | 3                     | escalate (or bail if at opus) |
| `no_structured_output`          | 1                     | escalate |
| `timeout`                       | 1                     | escalate |
| `structured_error` (output.status == "error") | 1        | escalate |
| `max_turns_exhausted_at_ceiling`| 0                     | bail immediately |
| `permission_denied`             | 0                     | bail immediately |
| `schema_not_found`              | 0                     | bail immediately |
| *(unknown)*                     | 0                     | bail immediately |

> **Unknown `error_kind` fails closed.** Any `error_kind` not listed above receives
> `max_retries = 0`, causing the script to bail immediately rather than silently
> retrying with an unknown policy.

**`max_turns` at non-ceiling model:** 0 retries — escalate immediately (same model cannot run more turns).

> **`no_structured_output` is the canonical `error_kind`** for "empty output" — this is the value
> emitted by `run_stage` (`implement-issue-orchestrator.sh`) when the stage produces no structured
> output. Issue #212 refers to this error class informally as "empty output".

---

## Back-Off Strategy

Only `rate_limit` errors use back-off. Compute `backoff_ms` as:

```
backoff_ms = min(30_000 × 2^retry_count, 120_000)
```

`retry_count` starts at `0` (no retries done yet), so the first retry always
waits 30 seconds.

| `retry_count` | `backoff_ms` |
|---------------|-------------|
| 0             | 30,000 ms   |
| 1             | 60,000 ms   |
| 2             | 120,000 ms  |

All other error classes: no back-off. Retry immediately (or escalate).

---

## When Retry Crosses Into Escalation

Escalate (instead of retry) when **any** of these conditions hold:

1. `retry_count >= max_retries[error_kind]` — threshold exceeded for this error class.
2. `error_history` already shows the same `error_kind` at the same `model` — repeated identical failure signals a capability gap, not a transient issue.
3. `stage_result.model == "opus"` and action would be `escalate` — use `bail` instead (ceiling reached).
4. `error_kind` is `permission_denied`, `schema_not_found`, or `max_turns_exhausted_at_ceiling` — these are never retriable.

---

## Decision Flowchart

```
stage_result received
        │
        ▼
error_kind in {permission_denied, schema_not_found, max_turns_exhausted_at_ceiling}?
  yes → bail
  no  ↓
        │
        ▼
retry_count >= max_retries[error_kind]
OR error_history has same error_kind at same model?
  yes → escalate (or bail if model == "opus")
  no  ↓
        │
        ▼
action = retry
error_kind == "rate_limit"? → include backoff_ms
```

---

## Action Examples

### `retry` — rate_limit, first attempt

```json
{
  "action":     "retry",
  "reason":     "rate_limit: transient throttle, retry_count=0, waiting 30000ms",
  "backoff_ms": 30000
}
```

### `retry` — empty_output, first attempt

```json
{
  "action": "retry",
  "reason": "no_structured_output: first retry at haiku, retry_count=1"
}
```

### `escalate` — timeout threshold exceeded

```json
{
  "action": "escalate",
  "reason": "timeout: retry_count=1 meets threshold (max 1); escalating haiku → sonnet"
}
```

### `bail` — permission_denied (never retriable)

```json
{
  "action": "bail",
  "reason": "permission_denied: configuration error, retrying cannot fix this"
}
```

### `bail` — opus at ceiling, would otherwise escalate

```json
{
  "action": "bail",
  "reason": "no_structured_output: retry_count=1 meets threshold; model=opus at ceiling, cannot escalate"
}
```

---

## Common Mistakes

| Mistake | Correct behaviour |
|---------|------------------|
| Retrying `max_turns_exhausted_at_ceiling` | Bail immediately — turns cannot be restored |
| Retrying `permission_denied` | Bail immediately — a higher model cannot bypass hooks |
| Omitting `backoff_ms` on rate_limit retry | Always include it so the caller can wait |
| Escalating from opus | Check `model == "opus"` first → `bail` instead |
| Ignoring `error_history` | A second identical failure at same model means escalate, not retry |
| Retrying `schema_not_found` | This is a missing config file; fix the pipeline, don't retry |
