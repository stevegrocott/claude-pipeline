---
name: triage-classify
description: Use when classifying a GitHub issue as fast-path or full pipeline route. Evaluates six criteria and routes conservative — any failing criterion forces full. Decision skill used by the implement-issue orchestrator.
inputs:
  - name: issue_body
    type: string
    required: true
    description: Full text of the GitHub issue body (title + description + implementation tasks)
outputs:
  - name: route
    type: string
    description: "Classification result: fast-path or full"
  - name: confidence
    type: string
    description: "Evaluation confidence: high, medium, or low (medium/low forces full)"
  - name: disqualifying_criterion
    type: string
    description: Snake_case name of the first criterion that failed; null when route is fast-path
  - name: triage_json
    type: file
    description: Auditable classification record written to logs/implement-issue/<run>/triage.json
side_effects:
  - writes_log: logs/implement-issue/<run>/triage.json
composes: []
failure_modes:
  - id: prompt_regression
    mitigation: run triage-validate golden suite to identify the flipped fixture; investigate before changing the manifest or prompt
  - id: low_confidence
    mitigation: route is forced to full automatically; no action needed — operator may inspect triage.json for the reason
  - id: schema_invalid_output
    mitigation: orchestrator falls back to full route and logs the raw model output for inspection
golden:
  model: haiku
  manifest: .claude/skills/triage-classify/golden.manifest.txt
  fixture_dir: .claude/scripts/implement-issue-test/fixtures/triage
  schema: .claude/scripts/schemas/implement-issue-triage.json
---

# Triage Classify

## Overview

Classify a GitHub issue into one of two pipeline routes:

- **fast-path** — surgical, test-only, well-specified change. Skips test loop, code review, deploy verify, and docs stages.
- **full** — default. Runs the complete verification pipeline.

Bias hard toward `full`. False positives (wrongly routing fast-path) cost quality; false negatives (missing fast-path) only cost time.

## Six Criteria

Every criterion must pass for `fast-path`. A single failure forces `full`.

| Criterion | Description |
|-----------|-------------|
| `test_only_scope` | All implementation task file paths match test patterns (`tests/**`, `*.spec.ts`, etc.) |
| `surgical_size` | Estimated diff under 30 lines net, across no more than 3 files |
| `established_pattern` | Change applies an existing codebase pattern (verified via `git grep`) |
| `precise_specification` | Issue has `## Implementation Tasks` with specific file paths and line numbers or code snippets |
| `benign_failure_mode` | Worst outcome of a wrong change is a failing test, not a production break |
| `no_security_concerns` | No auth, RBAC, encryption, secret handling, CORS, CSP, or token logic |

## Confidence Gate

If confidence is `medium` or `low`, route is forced to `full` regardless of criteria results.

## Golden Tests

The golden test suite (`triage-validate.sh` / `skill-golden.sh triage-classify`) runs real Haiku calls against fixture issues in `fixture_dir` and asserts the route matches the manifest. Run before merging changes to:

- The triage prompt in `implement-issue-orchestrator.sh`
- `schemas/implement-issue-triage.json`
- The Haiku tier model in `model-config.sh`

Do not auto-update fixtures or expected outcomes — flips require human investigation.
