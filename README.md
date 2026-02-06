# Aaddrick's Claude Code Implementation Pipeline

This is a complete `.claude/` folder you can drop into any project. It gives Claude Code a full multi-agent development pipeline: skills, agents, hooks, orchestration scripts, and quality gates that all work together.

> **Warning:** The orchestration scripts in this pipeline use Claude's `--dangerously-skip-permissions` flag. That means Claude runs without permission prompts during automated workflows. The pipeline also interacts with your GitHub repo autonomously -- creating branches, opening PRs, and posting comments. You should only use this in a safe, sandboxed environment -- not on a machine with access to production systems or sensitive data. Review the scripts before running them, and make sure you're comfortable with what they do. If either of these behaviors isn't what you want, ask Claude to adjust the pipeline to match your preferred workflow.

## Quick Start

Get it running in three steps:

```bash
# 1. Copy the .claude folder into your project
git clone https://github.com/aaddrick/claude-pipeline.git .claude-pipeline-source
cp -r .claude-pipeline-source/.claude .claude
rm -rf .claude-pipeline-source

# 2. Start Claude Code in your project
claude

# 3. Run the adaptation skill to customize everything for your codebase
> /adapting-claude-pipeline
```

That's it. The adaptation skill walks you through a brainstorming session about your project, figures out which parts of the pipeline to keep, modify, or remove, and then handles the changes with subagents. It works for any tech stack -- not just the Laravel/web defaults that ship with the template.

## What This Is

I built this as a portable Claude Code configuration. You clone it into your project and it gives you everything you need to run structured development workflows.

Here's what's inside:

- **19 skills** for process discipline (TDD, debugging, brainstorming), implementation workflows (issue handling, PR processing), and meta-skills (writing new skills and agents)
- **10 specialized agents** including backend and frontend developers, code reviewers, test validators, orchestration writers, and documentation generators
- **2 hooks** for session initialization and post-PR code simplification
- **3 orchestration scripts** that chain Claude CLI calls for batch issue processing and end-to-end implementation
- **14 JSON schemas** for structured output from each orchestration stage
- **Quality gates** at every level: spec compliance review, code quality review, test validation, and automated simplification

Some of the skills are adapted from [obra/superpowers](https://github.com/obra/superpowers). I keep all skills in the project folder rather than installing them globally. That way you can modify them to fit your project without worrying about updates breaking things or changes bleeding into other projects.

## Architecture

### Multi-Agent Collaboration

Each agent has a clear role. They don't try to do everything. Instead, they defer to each other when the work crosses boundaries.

```
bulletproof-frontend-developer <-> laravel-backend-developer  (frontend/backend split)
bash-script-craftsman -> bats-test-validator                  (write -> validate)
code-reviewer                                                 (quality gate)
spec-reviewer                                                 (spec compliance gate)
php-test-validator                                            (test integrity gate)
cc-orchestration-writer                                       (builds orchestration scripts)
```

### Orchestration Hierarchy

The orchestration flows from top to bottom. You start with an issue, and the pipeline handles the rest.

```
handle-issues (skill) -> batch-orchestrator.sh
                             |
                   implement-issue-orchestrator.sh (per issue)
                      setup -> plan -> implement -> test -> review -> pr
                             |
                   process-pr (skill)
                      merge + follow-ups  OR  re-run implementation
```

### Skill Categories

| Category | Skills | Purpose |
|----------|--------|---------|
| **Process** | brainstorming, TDD, systematic-debugging, writing-plans, dispatching-parallel-agents | Enforce discipline and methodology |
| **Workflow** | handle-issues, implement-issue, process-pr, subagent-driven-development, executing-plans | Automate multi-step development workflows |
| **Domain** | bulletproof-frontend, ui-design-fundamentals, write-docblocks, review-ui | Tech-stack-specific guidance |
| **Meta** | using-skills, writing-skills, writing-agents, adapting-claude-pipeline, improvement-loop | Maintain and extend the pipeline itself |

## Installation

### Quick Start

You can get this running in about two minutes. Clone the repo into your project and then use the built-in adaptation skill to customize it.

1. Clone this repo into your project:

```bash
# From your project root
git clone https://github.com/aaddrick/claude-pipeline.git .claude-pipeline-source
cp -r .claude-pipeline-source/.claude .claude
rm -rf .claude-pipeline-source
```

2. Adapt it to your project:

```bash
# Start a Claude Code session in your project
claude

# Use the adaptation skill
> /adapting-claude-pipeline
```

The adaptation skill walks you through a brainstorming session. It audits the pipeline against your tech stack, writes a plan, and then executes the changes with subagents.

### Manual Installation

If you'd rather cherry-pick the parts you need, here's the layout:

```
.claude/
├── agents/           # Copy agents relevant to your stack
├── hooks/            # Copy hooks, modify for your tools
├── prompts/          # Copy or replace with your templates
├── scripts/          # Copy orchestrators if using GitHub Issues workflow
├── skills/           # Copy skills by category (process skills are universal)
└── settings.json     # Copy and modify hook configurations
```

### What to Keep vs. What to Remove

**Always keep these.** They're universal process skills that work with any stack:
- brainstorming, writing-plans, systematic-debugging, test-driven-development
- dispatching-parallel-agents, subagent-driven-development, executing-plans
- using-skills, writing-skills, writing-agents, using-git-worktrees
- adapting-claude-pipeline, improvement-loop
- investigating-codebase-for-user-stories

**Keep these if you're using GitHub Issues and PRs:**
- handle-issues, implement-issue, process-pr
- All orchestration scripts and schemas

**Replace or remove these.** They're tied to specific tech stacks:
- bulletproof-frontend, review-ui, ui-design-fundamentals (web/CSS only)
- write-docblocks (PHP only)
- laravel-backend-developer, bulletproof-frontend-developer, code-simplifier, phpdoc-writer, php-test-validator (Laravel/PHP only)

## Usage

### Day-to-Day Development

Skills get invoked automatically when they're relevant. You can also call them manually with slash commands:

```
/brainstorming          # Before any creative work
/systematic-debugging   # When you hit a bug
/implement-issue 42     # Implement GitHub issue #42
/writing-plans          # Create an implementation plan
```

### Batch Processing

Use the `handle-issues` skill to process multiple GitHub issues. Tell Claude which issues you want handled and it takes care of the rest:

```
> /handle-issues Process issues 12, 15, and 23 against main branch using the backend developer agent
```

The skill coordinates the batch orchestrator under the hood -- rate limiting, status tracking, and circuit breakers are all handled for you.

### Single Issue Implementation

Use the `implement-issue` skill to go end-to-end on a single GitHub issue:

```
> /implement-issue 42
```

It handles the full cycle: setup, research, planning, implementation, testing, review, and PR creation.

### Extending the Pipeline

You can grow the pipeline as your needs change. There are skills for that too.

Create new skills:
```
> /writing-skills
```

Create new agents:
```
> /writing-agents
```

## The Improvement Loop

This one's important enough to call out on its own. The improvement loop is how the pipeline gets better over time.

When a skill, agent, or hook produces bad output, don't immediately edit it. Finish what you're working on first. Get to the correct solution. Only then go back and update the pipeline with what you learned.

The skill enforces this:

```
> /improvement-loop
```

It checks that your current issue is actually resolved before letting you make pipeline changes. That way you're encoding real understanding, not guesses. It also watches for recurring problems and suggests improvements proactively -- but it always asks before making changes.

I've found this makes a real difference. The instinct is to jump in and tweak things the moment something goes wrong. That doesn't work well because you end up encoding partial understanding. The loop keeps you honest.

## Hooks

### Session Start (`hooks/session-start.sh`)

This injects the `using-skills` skill into every conversation. It makes sure Claude always checks for relevant skills and uses them.

### Post-PR Simplify (`hooks/post-pr-simplify.sh`)

After `gh pr create` succeeds, this automatically runs the code-simplifier agent on your changed files. You don't have to think about it.

### Settings Guards (`settings.json`)

These protect you from common mistakes:

- **File protection:** Blocks writes to `.env`, credentials, `package-lock.json`
- **Deploy protection:** Blocks `deploy_to_production` commands
- **Auto-formatting:** Runs your project formatter on edited files
- **Desktop notifications:** Alerts you when Claude is waiting for input

## Testing

I've included a comprehensive BATS test suite for the orchestration scripts:

```bash
cd .claude/scripts/implement-issue-test
./run-tests.sh
```

Tests cover argument parsing, status management, rate limit handling, JSON parsing edge cases, and integration flows.

## Project Structure

```
.claude/
├── agents/                          # 10 specialized agent definitions
│   ├── bash-script-craftsman.md
│   ├── bats-test-validator.md
│   ├── bulletproof-frontend-developer.md
│   ├── cc-orchestration-writer.md
│   ├── code-reviewer.md
│   ├── code-simplifier.md
│   ├── laravel-backend-developer.md
│   ├── phpdoc-writer.md
│   ├── php-test-validator.md
│   └── spec-reviewer.md
├── hooks/                           # Lifecycle hooks
│   ├── session-start.sh
│   └── post-pr-simplify.sh
├── prompts/                         # Prompt templates
│   └── frontend/
│       ├── audit-blade.md
│       ├── refactor-blade-basic.md
│       └── refactor-blade-thorough.md
├── scripts/                         # Orchestration scripts
│   ├── batch-orchestrator.sh
│   ├── batch-runner.sh
│   ├── implement-issue-orchestrator.sh
│   ├── schemas/                     # 14 JSON schemas
│   └── implement-issue-test/        # BATS test suite
├── skills/                          # 21 skills
│   ├── adapting-claude-pipeline/
│   ├── brainstorming/
│   ├── bulletproof-frontend/
│   ├── dispatching-parallel-agents/
│   ├── executing-plans/
│   ├── handle-issues/
│   ├── implement-issue/
│   ├── improvement-loop/
│   ├── investigating-codebase-for-user-stories/
│   ├── process-pr/
│   ├── review-ui/
│   ├── subagent-driven-development/
│   ├── systematic-debugging/
│   ├── test-driven-development/
│   ├── ui-design-fundamentals/
│   ├── using-git-worktrees/
│   ├── using-skills/
│   ├── write-docblocks/
│   ├── writing-agents/
│   ├── writing-plans/
│   └── writing-skills/
└── settings.json                    # Hook and guard configurations
```

## Philosophy

I built this pipeline around a few ideas that I've found make a real difference.

**Skills are TDD for process documentation.** Every skill follows RED-GREEN-REFACTOR. You test that agents fail without the skill, write the skill, then verify they comply. It keeps things honest.

**Agents should be specialized, not general.** Each agent has a clear persona, explicit scope boundaries, and anti-patterns drawn from real-world research. They defer to each other rather than trying to do everything. That's the whole point.

**Fix first, improve later.** The improvement loop enforces that pipeline changes only happen after you fully understand the problem. You don't tweak things during active debugging.

**Quality gates over trust.** Every implementation goes through spec compliance review, code quality review, and test validation. The pipeline doesn't trust any single agent's output, and you shouldn't either.

**Delete aggressively.** When you adapt this to a new project, remove what you don't need. A focused pipeline beats a comprehensive one every time.

## Further Reading

I wrote a detailed walkthrough of the patterns and thinking behind this pipeline: [My Claude Project Implementation Patterns Guide](https://aaddrick.com/blog/my-claude-project-implementation-patterns-guide)

## License

MIT
