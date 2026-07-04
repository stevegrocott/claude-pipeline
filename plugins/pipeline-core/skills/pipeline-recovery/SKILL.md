---
name: pipeline-recovery
description: Use when the pipeline is experiencing repeated rate-limit errors, when batch execution is stalling with 429 responses, or when you want to check whether the current run has hit a rate-limit cluster before continuing work.
inputs:
  - name: events_file
    type: file_path
    required: true
    description: "Path to the run's events.jsonl JSONL event stream (one file per run under logs/implement-issue/<run_id>/)"
outputs:
  - name: pause_recommended
    type: boolean
    description: "true when >=3 rate_limit_hit events fall within any 60-second window in the current run; false otherwise"
side_effects: []
composes: []
failure_modes:
  - id: wrong_log_source
    mitigation: "Read events.jsonl, not orchestrator.log — orchestrator.log format is not stable; events.jsonl is the contract"
  - id: missing_run_id_filter
    mitigation: "Always scope jq queries to the current run_id; the events file accumulates events across restarts and mixing runs produces false positives"
  - id: wall_clock_instead_of_event_ts
    mitigation: "Use the ts field from each rate_limit_hit event for sliding-window arithmetic, not the current wall-clock time"
---

# Pipeline Recovery

## Overview

Reads the structured JSONL event stream to detect operational failure patterns and recommend corrective action. The event stream at `logs/implement-issue/issue-*/events.jsonl` is the canonical source — do not parse `orchestrator.log`.

## Rule: Rate-Limit Cluster → Pause

**Condition:** `>=3 rate_limit_hit events within any 60-second window in the current run`

**Action:** Recommend pausing the batch. Do not retry immediately.

## Locating the Event Stream

Each run writes to its own file:
```
logs/implement-issue/<run_id>/events.jsonl
```

Where `<run_id>` matches the `run_id` field in every event. Find the active run's file:
```bash
EVENTS_FILE="logs/implement-issue/${RUN_ID}/events.jsonl"
```

Or discover the most recent run:
```bash
EVENTS_FILE=$(ls -t logs/implement-issue/*/events.jsonl 2>/dev/null | head -1)
```

## Checking the Rate-Limit Rule

```bash
#!/usr/bin/env bash
# Returns 0 (trigger) if >=3 rate_limit_hit events fall within any 60s window.
# Returns 1 (clear) otherwise.

check_rate_limit_cluster() {
  local events_file="$1"
  local window=60
  local threshold=3

  [[ -f "$events_file" ]] || return 1

  # Extract epoch timestamps of rate_limit_hit events for current run_id.
  # Read run_id from status.json (the orchestrator's authoritative source) —
  # do NOT pull it from the first line of events.jsonl, which may belong to
  # an earlier run if the file accumulates events across restarts.
  local status_file="${events_file%/events.jsonl}/status.json"
  local run_id
  run_id=$(jq -r '.log_dir // ""' "$status_file" 2>/dev/null)
  run_id="${run_id##*/}"
  [[ -n "$run_id" ]] || return 1

  local timestamps
  timestamps=$(jq -r --arg rid "$run_id" \
    'select(.run_id == $rid and .event == "rate_limit_hit") | .ts' \
    "$events_file" | \
    while IFS= read -r ts; do
      date -d "$ts" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null
    done | \
    sort -n)

  # Sliding window: find any window of 60s with >=3 hits
  local count=0
  local -a epochs=()
  while IFS= read -r epoch; do
    epochs+=("$epoch")
  done <<< "$timestamps"

  local n=${#epochs[@]}
  for (( i=0; i<n; i++ )); do
    count=1
    for (( j=i+1; j<n; j++ )); do
      if (( epochs[j] - epochs[i] <= window )); then
        (( count++ ))
        if (( count >= threshold )); then
          return 0  # rule fires
        fi
      else
        break
      fi
    done
  done
  return 1  # rule clear
}
```

## Using the Rule

```bash
if check_rate_limit_cluster "$EVENTS_FILE"; then
  echo "PAUSE RECOMMENDED: >=3 rate_limit_hit events detected within 60s."
  echo "Wait for rate limit window to reset before resuming the batch."
  exit 1
fi
```

## Event Shape Reference

`rate_limit_hit` events look like:
```jsonl
{"ts":"2026-04-09T18:34:59Z","run_id":"issue-158-20260409-183459","stage":"implement","event":"rate_limit_hit","model":"sonnet","retry_after_seconds":60}
```

All events share the envelope fields: `ts`, `run_id`, `stage`, `event`. Optional: `task`.

## Quick Reference

| Field | Description |
|-------|-------------|
| `events.jsonl` | One JSONL file per run, append-only |
| `event` | Event type: `rate_limit_hit`, `escalation`, `retry`, `stage_start`, `stage_end`, etc. |
| `run_id` | Unique per pipeline run; filters events to current run |
| `ts` | ISO 8601 UTC; convert to epoch for window arithmetic |

## Common Mistakes

- **Parsing `orchestrator.log` instead of `events.jsonl`** — log format is not stable; events.jsonl is the contract
- **Not filtering by `run_id`** — the file accumulates events across restarts; always scope to the current run
- **Using wall-clock time instead of event `ts`** — check event timestamps, not when you ran the query
