---
name: pipeline-sync
description: Sync core pipeline files between claude-pipeline and project repos. Use when the user says "sync pipeline", "upstream this fix", "pull latest pipeline", "push to upstream", or when they've fixed a bug in a project's .claude/scripts/ that should be shared. Also use proactively after editing core files (scripts, hooks, schemas) to remind the user to sync. Includes a PostToolUse hook that auto-detects core file edits.
inputs:
  - name: direction
    type: string
    required: true
    description: Sync direction — "to" pushes core files from claude-pipeline into the project, "from" pulls a fix from the project back to claude-pipeline, "diff" shows what differs without modifying anything
  - name: project_path
    type: file_path
    required: true
    description: Absolute path to the project repository to sync with (e.g. ~/Projects/my-project)
outputs:
  - name: diff_output
    type: string
    description: List of files that differ between the pipeline and the project (always produced; non-empty only when files diverge)
side_effects:
  - may_modify_project_files: syncs core scripts/hooks/schemas into the project when direction is "to"
  - may_modify_pipeline_files: pulls changed core files into the claude-pipeline repo when direction is "from"
  - may_create_git_commits: commits the pulled fix in claude-pipeline when direction is "from"
composes: []
failure_modes:
  - id: sync_sh_missing
    mitigation: verify the claude-pipeline repo location and that sync.sh exists at its root; if missing, ask the user to locate or reinstall the pipeline
  - id: project_dir_not_found
    mitigation: confirm the project_path with the user; do not attempt to create the directory
---

# Pipeline Sync

Manage core pipeline files across the claude-pipeline repo and project repos that use the pipeline.

The orchestration engine (scripts, hooks, schemas, universal skills) is shared across all projects. When a bug is fixed in one project's copy, it needs to flow back to the pipeline repo and out to other projects. Without this, fixes get stranded and the same bug gets rediscovered repeatedly.

## Hook: Automatic Core File Detection

A PostToolUse hook at `scripts/detect-core-edit.sh` fires on every Edit/Write. When the edited file is a core pipeline file (script, hook, or universal skill), it outputs a reminder with the sync command. This means you don't need to remember to check — the hook tells you.

The hook is registered in `settings.json` and must be present for automatic detection to work. If it's missing, add it during `/adapting-claude-pipeline`:

```json
{
  "matcher": "Edit|Write",
  "hooks": [{
    "type": "command",
    "command": "\"$CLAUDE_PROJECT_DIR/.claude/skills/pipeline-sync/scripts/detect-core-edit.sh\"",
    "timeout": 5
  }]
}
```

## Prerequisites

`sync.sh` at the root of the claude-pipeline repo. Verify:
```bash
ls ~/Projects/claude-pipeline/sync.sh
```

## Workflows

### 1. Push upstream changes TO a project

```bash
cd ~/Projects/claude-pipeline
./sync.sh diff ~/Projects/<project-name>    # Check first
./sync.sh to ~/Projects/<project-name>      # Push core files
```

Never touches project-specific files (agents, `config/platform.sh`, prompts).

### 2. Pull a fix FROM a project

```bash
cd ~/Projects/claude-pipeline
./sync.sh diff ~/Projects/<project-name>    # See what changed
./sync.sh from ~/Projects/<project-name>    # Pull the fix
git diff                                     # Review
git checkout -b fix/<name>
git add -A && git commit -m "fix: <description>"
```

### 3. PR to upstream (stevegrocott/claude-pipeline)

```bash
cd ~/Projects/claude-pipeline
git push origin fix/<branch-name>
gh pr create --repo stevegrocott/claude-pipeline \
  --head scullers68:fix/<branch-name> --base main \
  --title "fix: <title>" --body "<summary + context + test plan>"
```

### 4. Pull upstream updates and distribute

```bash
cd ~/Projects/claude-pipeline
git fetch upstream && git merge upstream/main && git push origin main
./sync.sh to ~/Projects/allied-universal-assign
./sync.sh to ~/Projects/<other-project>
```

## File Classification

For the full breakdown of which files are core (synced) vs adapted (project-specific), read `references/file-classification.md`. In summary:

| Synced (core) | Never synced (project-specific) |
|---------------|-------------------------------|
| `scripts/**`, `hooks/**`, `settings.json` | `agents/*.md`, `config/platform.sh`, `prompts/*.md` |
| Universal skills (brainstorming, TDD, etc.) | Project-only skills |

## Adding a New Universal Skill

1. Add the skill name to `UNIVERSAL_SKILLS` in `sync.sh`
2. `./sync.sh from ~/Projects/<project>` to pull it
3. Commit and PR upstream
