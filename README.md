# Claude Pipeline (stevegrocott fork)

> Forked from [aaddrick/claude-pipeline](https://github.com/aaddrick/claude-pipeline) — a portable `.claude/` folder for structured Claude Code development workflows.

This fork modifies the pipeline to use **GitHub Issues as the single source of truth** for plans and tasks. Instead of generating local plan files during implementation, plans are written to GitHub Issues during a discovery phase and read back during implementation.

## Changes from Upstream

### Two-Phase Workflow

The original pipeline runs 4 stages before implementation (setup → research → evaluate → plan) that generate local artifacts. This fork replaces that with a two-phase approach:

**Phase 1: Discovery (`/explore`)**
```
/explore "vague idea or bug observation"
```
Chains: understand → research codebase → evaluate approaches → plan → `gh issue create`

The GH issue body contains the full plan with a **parseable task list**:
```markdown
## Implementation Tasks
- [ ] `[backend-developer]` Add migration for new column
- [ ] `[backend-developer]` Update service with new logic
- [ ] `[frontend-developer]` Add UI component
- [ ] `[default]` Add test coverage
```

**Phase 2: Implementation (`/implement-issue`)**
```
/implement-issue 42 main
```
Reads the GH issue body → extracts tasks → implements → tests → reviews → creates PR.

### No Git Worktrees

The upstream pipeline uses git worktrees for isolation. This fork uses **feature branches** in the current working directory instead, which is simpler and avoids merge conflicts from parallel worktree execution.

### Simplified Orchestrator Stages

| Upstream | This Fork |
|----------|-----------|
| setup (worktree) → research → evaluate → plan → implement | parse_issue → validate_plan → implement |

The research, evaluation, and planning happen during Phase 1 (`/explore`). Phase 2 just reads the result.

## Quick Start

```bash
# 1. Copy the .claude folder into your project
git clone https://github.com/stevegrocott/claude-pipeline.git .claude-pipeline-source
cp -r .claude-pipeline-source/.claude .claude
rm -rf .claude-pipeline-source

# 2. Start Claude Code in your project
claude

# 3. Run the adaptation skill to customize for your codebase
> /adapting-claude-pipeline
```

The adaptation skill walks you through a brainstorming session about your project and customizes the pipeline for your tech stack.

## What's Inside

- **22 skills** including the new `/explore` discovery skill
- **10 specialized agents** (backend/frontend developers, reviewers, validators)
- **2 hooks** for session initialization and post-PR simplification
- **3 orchestration scripts** for batch issue processing and end-to-end implementation
- **11 JSON schemas** for structured output (reduced from 14 — removed redundant pre-implementation schemas)
- **Quality gates** at every level: spec compliance, code quality, test validation

## Architecture

### Two-Phase Workflow

```
Phase 1: Discovery
  /explore "idea"
    → understand → research → evaluate → plan
    → gh issue create (with structured plan)

Phase 2: Implementation
  /implement-issue N main
    → parse GH issue → validate plan
    → implement → test → review → PR
```

### Orchestration Hierarchy

```
handle-issues (skill) → batch-orchestrator.sh
                             |
                   implement-issue-orchestrator.sh (per issue)
                      parse_issue → validate → implement → test → review → pr
                             |
                   process-pr (skill)
                      merge + follow-ups  OR  re-run implementation
```

### Skill Categories

| Category | Skills | Purpose |
|----------|--------|---------|
| **Discovery** | explore | Turn ideas into fully-planned GH issues |
| **Process** | brainstorming, TDD, systematic-debugging, writing-plans, dispatching-parallel-agents | Enforce discipline and methodology |
| **Workflow** | handle-issues, implement-issue, process-pr, subagent-driven-development, executing-plans | Automate multi-step development workflows |
| **Domain** | bulletproof-frontend, ui-design-fundamentals, write-docblocks, review-ui | Tech-stack-specific guidance |
| **Meta** | using-skills, writing-skills, writing-agents, adapting-claude-pipeline, improvement-loop | Maintain and extend the pipeline itself |

## Usage

### Discovery → Implementation Flow

```bash
# Phase 1: Discover and plan
> /explore "users can't reset their password from the settings page"
# Creates GH issue #42 with full plan

# Phase 2: Implement
> /implement-issue 42 main
# Reads plan from issue, implements, creates PR
```

### Batch Processing

```bash
> /handle-issues "open issues assigned to me, priority order"
```

Issues are processed sequentially on feature branches. Each issue goes through the full implementation pipeline.

### Day-to-Day Skills

```
/brainstorming          # Before any creative work
/systematic-debugging   # When you hit a bug
/writing-plans          # Create an implementation plan
```

## Task Format Specification

The orchestrator parses tasks from GH issue bodies using this convention:

```markdown
- [ ] `[agent-name]` Task description
```

**Parsing rule:** Regex `- \[[ x]\] ` `` `\[(.+?)\]` `` ` (.+)` extracts agent and description.

**Agent values** should match your `.claude/agents/` directory. The adaptation skill sets these up for your tech stack.

## Extending the Pipeline

Create new skills:
```
> /writing-skills
```

Create new agents:
```
> /writing-agents
```

After resolving a bug or observing a recurring problem:
```
> /improvement-loop
```

## Hooks

- **Session Start** (`hooks/session-start.sh`): Injects `using-skills` into every conversation
- **Post-PR Simplify** (`hooks/post-pr-simplify.sh`): Runs code-simplifier after PR creation

## Testing

```bash
cd .claude/scripts/implement-issue-test
./run-tests.sh
```

## Philosophy

This fork preserves the upstream's core philosophy while adding one key principle:

**GitHub Issues are the single source of truth.** Plans, research, and task lists live in GH issues, not in local files. This prevents drift between what was planned and what the pipeline executes.

Other preserved principles:
- **Skills are TDD for process documentation** — tested with subagents before deployment
- **Agents should be specialized, not general** — each has clear scope boundaries
- **Fix first, improve later** — pipeline changes happen after understanding the problem
- **Quality gates over trust** — every implementation goes through multiple reviews
- **Delete aggressively** — remove what you don't need

## License

MIT — see [LICENSE](LICENSE)

## Credits

- Original pipeline: [aaddrick/claude-pipeline](https://github.com/aaddrick/claude-pipeline)
- Skills adapted from: [obra/superpowers](https://github.com/obra/superpowers)
- Fork maintained by: [stevegrocott](https://github.com/stevegrocott)
