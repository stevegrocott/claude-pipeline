---
name: model-fallback
description: Use when selecting the next model after a stage failure — maps current_model and error_kind to the next model in the haiku → sonnet → opus escalation chain, detecting the opus ceiling and errors that skip fallback entirely.
inputs:
  current_model: "The model that failed: haiku | sonnet | opus"
  error_kind: "The error class from stage_result: timeout | no_structured_output | max_turns_exhausted | structured_error | rate_limit | permission_denied | schema_not_found | max_turns_exhausted_at_ceiling"
outputs:
  next_model: "The model to use next (haiku | sonnet | opus), or null when no fallback is possible"
  at_ceiling: "true when current_model is opus or the error_kind makes escalation impossible"
  reason: "Human-readable rationale for the decision"
side_effects: []
composes: []
failure_modes:
  - id: non_escalatable_error_escalated
    mitigation: "Check error_kind against permission_denied, schema_not_found, and max_turns_exhausted_at_ceiling before any escalation; return at_ceiling=true, next_model=null for these classes"
  - id: ceiling_not_detected
    mitigation: "Check current_model == 'opus' before computing next_model; opus is the ceiling — return at_ceiling=true, next_model=null"
  - id: premature_escalation_on_rate_limit
    mitigation: "Consult retry-policy before escalating on rate_limit; escalate only when the per-tier retry limit is met, not on the first rate_limit hit"
---

# model-fallback

## Overview

Given a failed stage's current model and error kind, determine whether to advance to the next model tier or stop. The escalation path is linear and capped:

```
haiku → sonnet → opus → (ceiling — no further fallback)
```

This skill answers a single question: **what model comes next?** It does not decide retry counts or back-off timing — see `retry-policy` for intra-tier retry logic and `escalation-policy` for the broader routing decision.

## Tier Definitions

| Tier     | Model  | Cognitive role                        |
|----------|--------|---------------------------------------|
| light    | haiku  | Mechanical: parse, template, simplify |
| standard | sonnet | Judgment: review, fix, match          |
| advanced | opus   | Deep reasoning: complex implementation |

Source: `.claude/scripts/model-config.sh` — `_tier_to_model()` and `_next_model_up()`.

## Input Contract

```json
{
  "current_model": "haiku | sonnet | opus",
  "error_kind":    "timeout | no_structured_output | max_turns_exhausted | structured_error | rate_limit | permission_denied | schema_not_found | max_turns_exhausted_at_ceiling"
}
```

## Output Contract

```json
{
  "next_model": "haiku | sonnet | opus | null",
  "at_ceiling": true,
  "reason":     "<human-readable string>"
}
```

`next_model` is `null` when `at_ceiling` is `true`. `at_ceiling` is `true` in two cases:

1. `current_model` is already `opus`
2. `error_kind` is one that no higher model can fix (see below)

## Escalation Chain

```
_next_model_up() in model-config.sh:
  haiku  → sonnet
  sonnet → opus
  opus   → opus   (at_ceiling = true, next_model = null)
```

## Error Classification

### Escalatable — advance to next tier

| `error_kind`            | Why escalation helps |
|-------------------------|----------------------|
| `timeout`               | Higher model is faster/more efficient |
| `no_structured_output`  | Capability gap — higher model produces valid output |
| `max_turns_exhausted`   | Model needed more reasoning depth |
| `structured_error`      | Logic error in output; better model may avoid it |
| `rate_limit`            | After retry threshold exceeded; escalate to a separate quota |

> For `rate_limit`: exhaust same-tier retries first (see `retry-policy`). Only escalate when the per-tier retry limit is met.

### Non-escalatable — at_ceiling = true, next_model = null

| `error_kind`                      | Why escalation cannot help |
|-----------------------------------|---------------------------|
| `permission_denied`               | A hook blocked the call; higher model faces the same hook |
| `schema_not_found`                | Missing config file; no model can read a non-existent schema |
| `max_turns_exhausted_at_ceiling`  | Already at opus; `run_stage` set this explicitly |

## Decision Logic

```
error_kind in {permission_denied, schema_not_found, max_turns_exhausted_at_ceiling}?
  → at_ceiling=true, next_model=null

current_model == "opus"?
  → at_ceiling=true, next_model=null

otherwise:
  haiku  → next_model="sonnet", at_ceiling=false
  sonnet → next_model="opus",   at_ceiling=false
```

## Output Examples

### Escalate: timeout on haiku

```json
{
  "next_model": "sonnet",
  "at_ceiling": false,
  "reason": "timeout: escalating haiku → sonnet"
}
```

### Escalate: no_structured_output on sonnet

```json
{
  "next_model": "opus",
  "at_ceiling": false,
  "reason": "no_structured_output: escalating sonnet → opus"
}
```

### Ceiling reached: max_turns_exhausted on opus

```json
{
  "next_model": null,
  "at_ceiling": true,
  "reason": "max_turns_exhausted: current_model=opus is the ceiling, no further fallback"
}
```

### Non-escalatable: permission_denied

```json
{
  "next_model": null,
  "at_ceiling": true,
  "reason": "permission_denied: a higher model cannot bypass permission hooks"
}
```

### Non-escalatable: schema_not_found

```json
{
  "next_model": null,
  "at_ceiling": true,
  "reason": "schema_not_found: missing configuration file, no model can fix this"
}
```

## Common Mistakes

| Mistake | Correct behaviour |
|---------|------------------|
| Escalating on `permission_denied` | Return `at_ceiling=true, next_model=null` — hooks block all models |
| Escalating from opus | Check `current_model == "opus"` first; return ceiling |
| Returning `next_model="opus"` when already at ceiling | Return `null`; opus → opus is a ceiling signal, not a valid target |
| Escalating on `max_turns_exhausted_at_ceiling` | `run_stage` set this because opus already exhausted turns; bail |
| Skipping `rate_limit` to escalate immediately | Check retry-policy first; escalate only when per-tier retry limit is met |

## Related Skills

- `retry-policy` — per-error-class same-tier retry limits and back-off; call before model-fallback
- `escalation-policy` — full routing (accept/escalate/bail/retry_same) using stage_result + history
