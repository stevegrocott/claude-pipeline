---
name: pipeline-feedback
description: Use when an operator observes a triage misclassification, prompt regression, criterion drift, agent misroute, or escalation loop and needs to record structured feedback for downstream audit. Prompts for kind and fields, invokes feedback-record.sh, and confirms the appended record.
argument-hint: "[kind]"
inputs:
  - name: kind
    type: string
    required: false
    description: Feedback kind (triage_misclassification, prompt_regression, criterion_drift, agent_misroute, escalation_loop); prompted interactively if omitted
outputs:
  - name: feedback_record
    type: jsonl_line
    description: One JSONL record appended to logs/feedback/<kind>.jsonl
side_effects:
  - appends_to_file: logs/feedback/<kind>.jsonl
composes: []
failure_modes:
  - id: invalid_kind
    mitigation: feedback-record.sh exits non-zero; surface the error message verbatim and do not confirm the record
  - id: missing_required_fields
    mitigation: re-prompt the operator for the missing fields before invoking feedback-record.sh
---

# Pipeline Feedback

## Overview

Record a structured observation about pipeline behavior to `logs/feedback/<kind>.jsonl`. Downstream tools (`triage-validate`, `improvement-loop`) consume these records as structured input.

**Before improving anything:** record the observation here first. This creates the audit trail that improvement work draws from.

## Kinds

| Kind | When to Use |
|------|-------------|
| `triage_misclassification` | Issue routed to wrong path (e.g., fast-path when full was needed) |
| `prompt_regression` | Agent output degraded vs. prior behavior for same input |
| `criterion_drift` | Acceptance criteria shifted since the prompt was written |
| `agent_misroute` | Wrong agent selected for a task type |
| `escalation_loop` | Agent repeatedly escalated without resolving |

## Invocation

If the caller passes `$1`, use it as the kind. Otherwise, ask:

```
AskUserQuestion: "What kind of pipeline feedback are you recording?
  1. triage_misclassification
  2. prompt_regression
  3. criterion_drift
  4. agent_misroute
  5. escalation_loop
Enter the kind name or number:"
```

## Field Collection

After kind is determined, gather the remaining fields. Ask each in one `AskUserQuestion` call listing all fields the operator must provide. Required fields:

| Field | Description | Required |
|-------|-------------|----------|
| `issue` | Issue or run reference (e.g., `issue-2840`, `run-abc`) | Yes |
| `observed` | What the pipeline actually did | Yes |
| `expected` | What it should have done | Yes |
| `evidence` | Path or URL to supporting artifact (log, screenshot) | No |
| `notes` | Any additional context | No |

## Record Append

Once fields are collected, invoke:

```bash
.claude/scripts/feedback-record.sh \
  --kind   "$KIND" \
  --issue  "$ISSUE" \
  --observed "$OBSERVED" \
  --expected "$EXPECTED" \
  [--evidence "$EVIDENCE"] \
  [--notes "$NOTES"]
```

The script validates the kind and required fields, then appends one JSONL line to `logs/feedback/<kind>.jsonl`.

## Confirmation

After the script exits with 0, emit a one-line summary:

```
Recorded $KIND for $ISSUE → logs/feedback/$KIND.jsonl
```

If the script exits non-zero, surface the error message verbatim and do not confirm.
