# Pipeline File Classification

## Core Files (synced across all projects)

These files are the orchestration engine. Changes to them should flow back to claude-pipeline and out to all projects via `sync.sh`.

### Always synced
| Path | Purpose |
|------|---------|
| `scripts/implement-issue-orchestrator.sh` | Main orchestration pipeline |
| `scripts/batch-orchestrator.sh` | Batch issue processing |
| `scripts/batch-runner.sh` | Batch runner utility |
| `scripts/model-config.sh` | Tier-to-model mapping |
| `scripts/explore-orchestrator.sh` | Research phase orchestrator |
| `scripts/apply-local.sh` | Local patch application |
| `scripts/platform/*.sh` | Platform API wrappers (GitHub/GitLab/Jira) |
| `scripts/platform/*.py` | Format converters (ADF↔markdown, markdown↔wiki) |
| `scripts/schemas/*.json` | Structured output schemas for each stage |
| `scripts/implement-issue-test/` | BATS test suite for orchestrator |
| `scripts/platform-test/` | BATS tests for platform wrappers |
| `hooks/session-start.sh` | Session initialization |
| `hooks/post-pr-simplify.sh` | Post-PR code review trigger |
| `settings.json` | Hook configuration, permissions |

### Universal skills (synced)
Process-focused, stack-agnostic skills. See `UNIVERSAL_SKILLS` array in `sync.sh` for the definitive list.

Key ones: brainstorming, explore, implement-issue, handle-issues, systematic-debugging, test-driven-development, writing-plans, writing-skills, pipeline-sync.

## Adapted Files (never synced, project-specific)

These files are rewritten during `/adapting-claude-pipeline` for each project's tech stack.

| Path | Why project-specific |
|------|---------------------|
| `agents/*.md` | Rewritten for project stack (e.g., totara-php-developer vs fastify-backend-developer) |
| `config/platform.sh` | Project's tracker (GitHub/Jira), git host, test commands, base URLs |
| `prompts/*.md` | Project-specific review checklists |
| Project-only skills | Skills created for a specific project (e.g., playwright-verification, server-health-check) |

## How to Decide

When you edit a `.claude/` file, ask:

1. **Would this change benefit other projects?** → Core file, sync it
2. **Is this specific to this project's stack or domain?** → Adapted file, don't sync
3. **Is this a bug fix in a script?** → Almost always core, sync it
4. **Is this a new skill?** → Usually project-specific unless it's process-focused

## Adding a New Universal Skill

1. Create the skill in any project
2. Add its name to `UNIVERSAL_SKILLS` in `sync.sh`
3. `./sync.sh from <project>` to pull it to claude-pipeline
4. Commit and PR upstream
