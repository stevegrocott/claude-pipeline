---
name: enrich-issue
description: Enrich a pipeline-autocreated issue by running explore's research and planning steps, rewriting the body in place, then removing the needs-explore label (idempotent — no-op if marker absent)
argument-hint: "<issue_number>"
inputs:
  - name: issue_number
    type: integer
    required: true
    description: GitHub issue number to enrich
outputs:
  - name: issue_url
    type: url
    description: GitHub issue URL that was enriched
side_effects:
  - rewrites_github_issue
  - removes_github_label: needs-explore
failure_modes:
  - id: marker_absent
    mitigation: bail with a clear no-op message — do not modify the issue
  - id: already_enriched
    mitigation: bail with a clear no-op message — idempotent, label already removed
  - id: gh_api_unauthorized
    mitigation: surface the gh auth error to the operator, do not retry
composes:
  - mcp-tools
  - explore
---

# Enrich Issue

## Overview

Enrich an existing pipeline-autocreated GitHub issue. Reads the issue body, verifies the `<!-- pipeline-autocreated -->` HTML comment marker is present, then runs the same research + planning pipeline as `/explore` and rewrites the issue body in place with full context, research findings, evaluation, implementation tasks, and acceptance criteria.

On success, removes the `needs-explore` label from the issue.

**This skill is idempotent:** if the `<!-- pipeline-autocreated -->` marker is absent (e.g. the issue was human-authored or already enriched and the marker stripped), the skill logs a no-op message and exits without modifying the issue. Similarly, if the `needs-explore` label is already absent, the skill logs "already enriched — no-op" and exits.

**Announce at start:** "Using enrich-issue to research and enrich issue #$ISSUE_NUMBER"

**Arguments:**
- `$1` — Issue number (required, e.g. `456`)

**Examples:**
- `/enrich-issue 456`
- `/enrich-issue 789`

## Process

### Step 1: Read Issue and Validate Marker

Read the issue body and title:

```bash
PLATFORM_DIR=".claude/scripts/platform"
ISSUE_BODY=$(gh issue view "$ISSUE_NUMBER" --json body,title,labels \
  --jq '{title: .title, body: .body, labels: [.labels[].name]}')

TITLE=$(printf '%s' "$ISSUE_BODY" | jq -r '.title')
BODY=$(printf '%s' "$ISSUE_BODY" | jq -r '.body')
LABELS=$(printf '%s' "$ISSUE_BODY" | jq -r '.labels[]' 2>/dev/null || echo "")
```

**Idempotency checks — bail early (no-op) if:**

1. **Marker absent** — The `<!-- pipeline-autocreated -->` HTML comment is not present in the issue body:

   ```bash
   if ! printf '%s' "$BODY" | grep -q '<!-- pipeline-autocreated -->'; then
     echo "enrich-issue #${ISSUE_NUMBER}: no-op — pipeline-autocreated marker absent; skipping to avoid overwriting a human-edited issue."
     exit 0
   fi
   ```

2. **Label already removed** — The `needs-explore` label is not present (issue was already enriched):

   ```bash
   if ! printf '%s' "$LABELS" | grep -q 'needs-explore'; then
     echo "enrich-issue #${ISSUE_NUMBER}: no-op — needs-explore label is absent; issue is already enriched."
     exit 0
   fi
   ```

If both checks pass, proceed with enrichment.

### Step 2: Research the Codebase

Extract the description from the existing issue body (the raw content between the `<!-- pipeline-autocreated -->` marker and any existing sections). Use this as the seed for research.

**Framework/library documentation (use Context7 first):**
- `context7.resolve_library_id` → `context7.get_library_docs` for framework API docs
- Fall back to web search only if Context7 doesn't have the library or is unavailable
- See `mcp-tools` skill for full decision matrix

**Code structure and patterns (use Serena for structural queries):**
- Use Serena for class hierarchies, method signatures, call graphs
- Use Grep/Glob for text-based file search and discovery

**Document findings:**
- Identify affected files, services, components
- Document current behaviour vs desired behaviour
- Note architectural patterns to follow

**Test Surface Discovery (run after identifying affected files):**

Run Phases 0–3 of the `test-discovery` skill against the touched files (cap at 5 files).

> **Graceful fallback:** If `.claude/skills/test-discovery/SKILL.md` does not exist, skip this sub-step and note "test-discovery skill unavailable" in the research findings.

### Step 3: Evaluate Approaches

Determine the best implementation strategy:
- Propose 2-3 approaches with trade-offs
- Select recommended approach with rationale
- Identify risks and mitigations
- Note alternatives considered and why rejected

### Step 4: Generate Implementation Plan

Break the chosen approach into implementable tasks following the same conventions as `/explore`:
- Each task specifies an agent type (see [Task Format](#task-format))
- Tasks are ordered by dependency (data layer first, then presentation)
- Each task is a single logical unit of work
- Each task should target 5-30 minutes of subagent execution time
- Add a complexity hint: `- [ ] \`[agent]\` **(S)** Description` where S=small, M=medium, L=large
- **Parseable format required:** Every task line in `## Implementation Tasks` MUST begin with `- [ ] \`[agent-name]\``
- **Every task MUST include at least one file path**

### Step 5: Rewrite Issue Body In Place

Construct the enriched issue body and update via `gh issue edit`:

```bash
ENRICHED_BODY=$(cat <<'EOF'
<!-- pipeline-autocreated -->

## Context
[What was discovered and why it matters — 2-3 sentences]

## Research Findings
[Codebase exploration results]

**Files affected:**
- `path/to/file.ts` — [what needs changing]

**Current behavior:** [what happens now]
**Desired behavior:** [what should happen]

## Relevant Existing Tests
**Unit tests:**
- `path/to/unit.test.ts:L1-30` — [what behavior is covered]

**Consumer tests:**
- `path/to/integration.test.ts:L1-30` — [what integration is covered]

**E2E specs:**
- `path/to/spec.e2e.ts:L1-30` — [what user flow is covered]

**Coverage gaps:**
- [what is not tested]

## Evaluation
**Approach:** [chosen approach — 1 sentence]
**Rationale:** [why this approach — 2-3 sentences]

**Risks:**
- [risk 1 + mitigation]

**Alternatives considered:**
- [alternative 1] — rejected because [reason]

## Implementation Tasks
- [ ] `[agent-name]` **(S)** Task description — `src/path/file.ts:L10-40`

## Acceptance Criteria
- [ ] AC1: [measurable criterion]
- [ ] AC2: [measurable criterion]
EOF
)

gh issue edit "$ISSUE_NUMBER" --body "$ENRICHED_BODY"
```

> **Preserve the marker:** The rewritten body MUST retain the `<!-- pipeline-autocreated -->` HTML comment at the top so subsequent runs remain idempotent.

### Step 6: Remove the needs-explore Label

After successfully rewriting the body, remove the `needs-explore` label:

```bash
gh issue edit "$ISSUE_NUMBER" --remove-label "needs-explore"
```

Log the result:
```
enrich-issue #${ISSUE_NUMBER}: enrichment complete — needs-explore label removed.
```

### Step 7: Write Enrich Log

After the issue is confirmed updated, write a status.json log:

```bash
ISSUE_NUM="$ISSUE_NUMBER"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOG_DIR="logs/enrich-issue/enrich-${ISSUE_NUM}-${TIMESTAMP}"
mkdir -p "$LOG_DIR"
cat > "$LOG_DIR/status.json" <<EOF
{
  "state": "completed",
  "issue": "${ISSUE_NUM}",
  "stages": {
    "validate": { "status": "completed", "started_at": "${NOW}", "completed_at": "${NOW}" },
    "research": { "status": "completed", "started_at": "${NOW}", "completed_at": "${NOW}" },
    "plan": { "status": "completed", "started_at": "${NOW}", "completed_at": "${NOW}" },
    "rewrite_issue": { "status": "completed", "started_at": "${NOW}", "completed_at": "${NOW}" },
    "remove_label": { "status": "completed", "started_at": "${NOW}", "completed_at": "${NOW}" }
  },
  "task_summary": {
    "completed": { "S": 1, "M": 0, "L": 0 },
    "failed": { "S": 0, "M": 0, "L": 0 },
    "sp_completed": 1,
    "sp_total": 1
  },
  "escalations": [],
  "log_dir": "${LOG_DIR}"
}
EOF
```

### Step 8: Report

```
Enriched issue #NNN: "Title"
URL: https://github.com/...

Ready for implementation: /implement-issue NNN main
```

## Task Format

The `## Implementation Tasks` section must use this parseable convention (identical to `/explore`):

```markdown
- [ ] `[agent-name]` **(M)** Task description — `src/path/file.ts:L10-40`
```

**Agent values** — use agents defined in `.claude/agents/`:

| Agent | Use for |
|-------|---------|
| `[fastify-backend-developer]` | API routes, services, backend logic |
| `[react-frontend-developer]` | React components, pages, CSS, hooks |
| `[playwright-test-developer]` | E2E tests only (when `TEST_E2E_CMD` configured) |
| `[bash-script-craftsman]` | Shell scripts, CI scripts, bash tooling |
| `[cc-orchestration-writer]` | Claude Code orchestration scripts |
| `[default]` | General tasks: config, unit tests, documentation, mixed |

**Parsing rule:** Regex `- \[[ x]\] \x60\[(.+?)\]\x60 (.+)` extracts agent and description. Task IDs assigned sequentially.

## Key Principles

- **Idempotent** — checking for the `<!-- pipeline-autocreated -->` marker before every run guards against overwriting human-authored issues; a missing marker means bail with a no-op log message and exit
- **Preserve marker** — the rewritten body always retains `<!-- pipeline-autocreated -->` at the top
- **Research before planning** — same discipline as `/explore`
- **Parseable output** — the task list format must be mechanically extractable by the orchestrator
- **YAGNI** — only plan what's needed

## Integration

**Called by:**
- `batch-orchestrator.sh --enrich-followups` (post-batch sweep)
- Operator directly: `/enrich-issue NNN`

**Produces:** A fully-researched issue ready for `/implement-issue N main`
**Consumes:** A sparse pipeline-autocreated issue with `needs-explore` label
**Followed by:** `/implement-issue` skill

## Red Flags

| Temptation | Why It Fails |
|------------|--------------|
| Skip the marker check | Overwrites human-authored issues — data loss |
| Strip the marker from the rewritten body | Next run re-enriches an already-complete issue |
| Bail when label is absent without logging | Silent no-op is hard to debug; always log |
| Remove label before rewriting body | Label removal signals completion; do it last |
| Skip research, jump to planning | Plan won't account for existing patterns |
| Task has no file paths | Subagent reads 13+ files to orient; include at least 1 file path per task |
