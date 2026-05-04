---
name: escalation-policy
description: Use when a pipeline stage completes and a routing decision is needed — routes stage_result to accept, escalate (higher model), bail (terminal), or retry_same based on error_kind, escalation history, and model tier ceiling.
inputs:
  stage_result: "JSON envelope from run_stage(): {status, output, error_kind, model, elapsed_ms, raw, denials}"
  escalation_history: "Array of prior escalation records for this stage: [{stage, from_model, to_model, reason}]"
outputs:
  action: '"accept" | "escalate" | "bail" | "retry_same"'
  model: "Target model for escalate action (haiku|sonnet|opus); omitted for other actions"
  reason: "Human-readable routing rationale for logging/diagnostics"
failure_modes:
  - "Escalating when already at opus ceiling — use bail instead"
  - "retry_same on a repeated failure at the same model — check escalation_history first"
  - "accept on structured-error output — check output.status, not just stage_result.status"
---

# escalation-policy

## Overview

Given a completed `stage_result` envelope and the escalation history for that stage, decide what the pipeline should do next. The four actions are mutually exclusive and exhaustive.

Model escalation path: **haiku → sonnet → opus** (no tier above opus; opus is the ceiling).

## Input Contract

### `stage_result` — from `run_stage()` / `_emit_stage_result()`

```json
{
  "status":     "success | error | rate_limit",
  "output":     "<object | null>  — parsed structured output from Claude CLI",
  "raw":        "<string>         — raw stdout before extraction",
  "denials":    ["<tool_name>"]   ,
  "model":      "haiku | sonnet | opus",
  "error_kind": "timeout | schema_not_found | no_structured_output | max_turns_exhausted_at_ceiling | rate_limit | permission_denied | null",
  "elapsed_ms": 12345
}
```

### `escalation_history` — from `STATUS_FILE.escalations[]`

Array of records appended by `record_escalation()` each time a stage is retried at a higher model:

```json
[
  {
    "stage":      "<stage_name>",
    "from_model": "haiku | sonnet | opus",
    "to_model":   "haiku | sonnet | opus",
    "reason":     "double_timeout | max_turns_exhausted | empty_output | structured_error"
  }
]
```

Filter to records where `stage == current_stage_name` before reasoning.

## Output Contract

```json
{
  "action": "accept | escalate | bail | retry_same",
  "model":  "<target_model>",
  "reason": "<human-readable string>"
}
```

`model` is **required** when `action == "escalate"` and omitted otherwise.

---

## Action Types

### `accept`

Continue to the next pipeline stage — the current result is usable.

**When it applies:**
- `stage_result.status == "success"` AND
- `stage_result.output` is non-null and valid AND
- No `error_kind` that requires remediation

**Required output fields:** `action`, `reason`

```json
{ "action": "accept", "reason": "stage completed successfully with valid output" }
```

**Do NOT accept when:**
- `output.status == "error"` (structured error inside an HTTP-200 envelope)
- `error_kind` is set to anything other than `null`

---

### `escalate`

Re-run the stage with the next higher model tier.

**When it applies (any of):**
| `error_kind` / condition | reason tag | notes |
|--------------------------|------------|-------|
| `timeout` | `double_timeout` | Always escalate on timeout; `run_stage` handles internal first-retry before invoking the skill |
| `max_turns_exhausted_at_ceiling` is NOT set AND turns exhausted | `max_turns_exhausted` | Only escalate if not already at opus |
| `no_structured_output` | `empty_output` | Model produced no parseable result |
| `output.status == "error"` | `structured_error` | Claude returned a structured error block |

**Required output fields:** `action`, `model` (target tier), `reason`

```json
{ "action": "escalate", "model": "sonnet", "reason": "double_timeout: stage timed out twice with haiku" }
```

**Do NOT escalate when:**
- `stage_result.model == "opus"` — already at ceiling; use `bail` instead
- `error_kind == "permission_denied"` — a higher model cannot bypass permissions
- `error_kind == "schema_not_found"` — a configuration error, not a capability gap

**Model selection:** always the next tier up from `stage_result.model`:
- haiku → sonnet
- sonnet → opus
- opus → **bail** (ceiling)

---

### `bail`

Terminate the stage as a permanent failure; propagate the error to the caller.

**When it applies (any of):**
- Would escalate but `stage_result.model == "opus"` (at ceiling)
- `error_kind == "permission_denied"` — unrecoverable regardless of model
- `error_kind == "schema_not_found"` — missing schema file; fix the configuration
- `error_kind == "max_turns_exhausted_at_ceiling"` — explicitly set by `run_stage` when opus exhausted turns
- `escalation_history` shows the stage has already been escalated to opus and failed again

**Required output fields:** `action`, `reason`

```json
{ "action": "bail", "reason": "max_turns_exhausted_at_ceiling: opus already at ceiling, cannot escalate further" }
```

`bail` causes the caller to receive exit code 1. It does NOT retry.

---

### `retry_same`

Re-run the stage with the **same** model — used for transient, non-capability failures.

**When it applies:**
- `error_kind == "rate_limit"` and this is the first rate-limit hit for this stage
- Transient network or API error where the model is not the limiting factor
- `escalation_history` shows **no** prior attempt at this model for this stage

**Required output fields:** `action`, `reason`

```json
{ "action": "retry_same", "reason": "rate_limit: transient throttle, retrying with same model" }
```

**Do NOT retry_same when:**
- `escalation_history` already shows a prior retry at the same model for the same reason — escalate or bail instead
- The failure is deterministic (schema_not_found, permission_denied)

---

## Decision Flowchart

```
stage_result received
        │
        ▼
status == "success" AND output valid?
  yes → accept
  no  ↓
        │
        ▼
error_kind == "permission_denied" OR "schema_not_found"?
  yes → bail
  no  ↓
        │
        ▼
model == "opus" (ceiling)?
  yes → bail  (cannot escalate further)
  no  ↓
        │
        ▼
error_kind == "rate_limit" AND no prior retry at same model?
  yes → retry_same
  no  ↓
        │
        ▼
escalate  (double_timeout | max_turns_exhausted | empty_output | structured_error)
```

## Common Mistakes

| Mistake | Correct behaviour |
|---------|------------------|
| Accepting when `output.status == "error"` | Check `output.status`, not just `stage_result.status` |
| Escalating from opus | Check `stage_result.model == "opus"` → bail instead |
| retry_same after a prior retry | Check `escalation_history` for same stage+model; escalate if present |
| Omitting `model` on escalate action | `model` is required when action is `escalate` |
| Escalating on `permission_denied` | A higher model cannot bypass permission hooks; bail |
