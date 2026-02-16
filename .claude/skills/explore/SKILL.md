---
name: explore
description: Turn a vague idea or bug observation into a fully-planned GitHub Issue with research, evaluation, implementation tasks, and acceptance criteria
argument-hint: "<description of idea or problem>"
---

# Explore

## Overview

Turn a vague idea, bug observation, or feature request into a fully-researched, implementation-ready GitHub Issue. This is Phase 1 of a two-phase workflow where GitHub Issues are the single source of truth.

**Phase 1 (this skill):** idea → research → evaluate → plan → GH issue
**Phase 2 (`/implement-issue`):** GH issue → parse tasks → implement → test → review → PR

**Announce at start:** "Using explore to investigate and plan: $DESCRIPTION"

## Process

### Step 1: Understand the Idea

Refine the vague input into concrete requirements:
- Ask 1-2 clarifying questions if the description is too vague (use AskUserQuestion)
- If the description is specific enough, proceed without questions
- Identify: what's wrong / what's wanted, who's affected, what success looks like

### Step 2: Research the Codebase

Explore relevant files, patterns, and dependencies:
- Use available code exploration tools (Serena, Grep, Glob, etc.) for code exploration
- Use Context7 for framework/library documentation when available
- Identify affected files, services, components
- Document current behavior vs desired behavior
- Note architectural patterns to follow

### Step 3: Evaluate Approaches

Determine the best implementation strategy:
- Propose 2-3 approaches with trade-offs
- Select recommended approach with rationale
- Identify risks and mitigations
- Note alternatives considered and why rejected

### Step 4: Generate Implementation Plan

Break the chosen approach into implementable tasks:
- Each task specifies an agent type (see Task Format below)
- Tasks are ordered by dependency (data layer first, then presentation)
- Each task is a single logical unit of work
- Include acceptance criteria for the overall issue

### Step 5: Create GitHub Issue

Create the issue using `gh issue create` with the structured body format:

```bash
gh issue create --title "$TITLE" --body "$(cat <<'EOF'
## Context
[What was discovered and why it matters — 2-3 sentences]

## Research Findings
[Codebase exploration results]

**Files affected:**
- `path/to/file.ts` — [what needs changing]
- `path/to/other.ts` — [what needs changing]

**Current behavior:** [what happens now]
**Desired behavior:** [what should happen]

## Evaluation
**Approach:** [chosen approach — 1 sentence]
**Rationale:** [why this approach — 2-3 sentences]

**Risks:**
- [risk 1 + mitigation]
- [risk 2 + mitigation]

**Alternatives considered:**
- [alternative 1] — rejected because [reason]
- [alternative 2] — rejected because [reason]

## Implementation Tasks
- [ ] `[agent-name]` Description of task 1
- [ ] `[agent-name]` Description of task 2
- [ ] `[agent-name]` Description of task 3
- [ ] `[default]` Description of general task (e.g., tests, config)

## Acceptance Criteria
- [ ] AC1: [measurable criterion]
- [ ] AC2: [measurable criterion]
- [ ] AC3: [measurable criterion]
EOF
)"
```

### Step 6: Report

Output the created issue URL and a brief summary:
```
Created issue #NNN: "Title"
URL: https://github.com/...

Ready for implementation: /implement-issue NNN main
```

## Task Format Specification

The `## Implementation Tasks` section must use this parseable convention:

```markdown
- [ ] `[agent-name]` Task description
```

**Agent values** (adapt to your project's agents):
- Use whatever agent names are configured in `.claude/agents/`
- Common patterns: `[backend-developer]`, `[frontend-developer]`, `[default]`
- `[default]` for general tasks (config, tests, documentation, mixed)

**Parsing rule:** Regex `- \[[ x]\] \x60\[(.+?)\]\x60 (.+)` extracts agent and description. Task IDs assigned sequentially.

## Key Principles

- **One issue per problem** — don't combine unrelated work
- **Research before planning** — understand the codebase before proposing changes
- **Parseable output** — the task list format must be mechanically extractable by the orchestrator
- **YAGNI** — only plan what's needed, don't gold-plate
- **Minimal questions** — if the description is clear enough, proceed without asking

## Integration

**Produces:** A GitHub Issue ready for `/implement-issue N main`
**Consumes:** Vague natural language descriptions
**Followed by:** `/implement-issue` skill (Phase 2)

## Red Flags

| Temptation | Why It Fails |
|------------|--------------|
| Skip research, jump to planning | Plan won't account for existing patterns |
| Create local plan files | GH issue IS the plan — single source of truth |
| Over-plan with 20+ tasks | Keep it focused; split into multiple issues if needed |
| Combine multiple concerns in one issue | One issue = one problem = one PR |
| Ask too many clarifying questions | 0-2 questions max; research answers most questions |
