---
name: using-git-worktrees
description: Use when starting feature work that needs isolation from current workspace or before executing implementation plans - creates isolated git worktrees in .worktrees/
---

> **Note:** This skill is not used by the automated pipeline (`implement-issue`, `handle-issues`). The pipeline uses feature branches instead. This skill remains available for manual use when workspace isolation is needed.

# Using Git Worktrees

## Overview

Git worktrees create isolated workspaces sharing the same repository, allowing work on multiple branches simultaneously without switching.

**Location:** Always use `.worktrees/` (per CLAUDE.md)

**Announce at start:** "I'm using the using-git-worktrees skill to set up an isolated workspace."

## Safety Verification

**Verify `.worktrees/` is ignored before creating worktree:**

```bash
git check-ignore -q .worktrees 2>/dev/null
```

**If NOT ignored:** Add to .gitignore and commit before proceeding.

**Why critical:** Prevents accidentally committing worktree contents to repository.

## Creation Steps

### 1. Create Worktree

```bash
git worktree add .worktrees/$BRANCH_NAME -b $BRANCH_NAME $BASE_BRANCH
cd .worktrees/$BRANCH_NAME
```

### 2. Run Project Setup

**Laravel:**

Fresh worktrees don't have `vendor/` or `node_modules/`. Install dependencies first:

```bash
# 1. Create bootstrap/cache (required for composer)
mkdir -p bootstrap/cache

# 2. Install PHP dependencies
composer install --no-interaction

# 3. Run Laravel setup (migrations, seeds, caches)
php artisan migrate --seed

# 4. Build frontend assets (Vite manifest required for tests)
npm install && npm run build
```

**Why this order matters:**
- `bootstrap/cache` must exist before composer runs post-install scripts
- `vendor/` must exist before artisan commands work
- Vite manifest must exist or tests using views will fail

**Other projects:** Auto-detect from project files:
```bash
if [ -f package.json ]; then npm install; fi
if [ -f Cargo.toml ]; then cargo build; fi
if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
if [ -f pyproject.toml ]; then poetry install; fi
if [ -f go.mod ]; then go mod download; fi
```

### 3. Verify Baseline

Run tests to ensure worktree starts clean:
```bash
# Laravel
php artisan test

# Other
npm test / cargo test / pytest / go test ./...
```

**If tests fail:** Verify setup completed correctly (vendor/, node_modules/, Vite manifest all exist). Compare with main worktree to identify if failures are pre-existing.

**If tests pass:** Report ready.

### 4. Report Location

```
Worktree ready at <full-path>
Branch: <branch-name>
Tests: <N> passed (<M> pre-existing failures if any)
Ready to implement <feature-name>
```

## Quick Reference

| Situation | Action |
|-----------|--------|
| Creating worktree | `git worktree add .worktrees/$BRANCH -b $BRANCH $BASE` |
| `.worktrees/` not ignored | Add to .gitignore + commit first |
| Laravel project | `mkdir -p bootstrap/cache` → `composer install` → `php artisan migrate --seed` → `npm install && npm run build` |
| Other projects | Auto-detect from package.json, Cargo.toml, etc. |
| Tests fail during baseline | Verify setup complete (vendor/, node_modules/, Vite manifest), compare with main |

## Common Mistakes

### Skipping ignore verification

- **Problem:** Worktree contents get tracked, pollute git status
- **Fix:** Always use `git check-ignore` before creating worktree

### Running artisan commands before composer install

- **Problem:** Fresh worktrees have no `vendor/` directory - artisan commands fail
- **Fix:** Run `composer install` first, then artisan commands

### Missing bootstrap/cache directory

- **Problem:** Composer post-install scripts fail with "directory must be present and writable"
- **Fix:** Create `mkdir -p bootstrap/cache` before running `composer install`

### Skipping npm build

- **Problem:** Tests that render views fail with "Vite manifest not found"
- **Fix:** Run `npm install && npm run build` after Laravel setup

### Hardcoding setup commands

- **Problem:** Breaks on projects using different tools
- **Fix:** Use documented sequence for Laravel, auto-detect for others

## Example Workflow

```
You: I'm using the using-git-worktrees skill to set up an isolated workspace.

[Verify ignored: git check-ignore .worktrees - confirmed]
[Create worktree: git worktree add .worktrees/issue-123 -b issue-123-feature aw-next]
[mkdir -p bootstrap/cache]
[composer install --no-interaction]
[php artisan migrate --seed]
[npm install && npm run build]
[php artisan test - all tests passed]

Worktree ready at /home/user/project/.worktrees/issue-123
Branch: issue-123-feature
Tests: 639 passed (0 failures)
Ready to implement feature
```

## Red Flags

**Never:**
- Create worktree without verifying `.worktrees/` is ignored
- Run artisan commands before `composer install` in fresh worktree
- Skip `npm run build` - tests will fail on missing Vite manifest

**Always:**
- Use `.worktrees/` directory
- Verify directory is ignored
- Create `bootstrap/cache` before composer install
- Follow setup order: composer → artisan migrate → npm build

## Integration

**Called by:**
- **brainstorming** (Phase 4) - when design is approved
- **implement-issue** - for isolated feature work

**Pairs with:**
- **finishing-a-development-branch** - cleanup after work complete
- **subagent-driven-development** - work happens in this worktree
