#!/usr/bin/env bats
#
# tests/stray-file-commit-isolation.bats
# Coverage for issue #315 — "Docblock/simplify/fix-review stages can commit
# stray files (.serena/project.yml) into feature PRs".
#
# Two defenses are exercised here:
#
#   1. `.serena/` is gitignored, so a stray untracked `.serena/project.yml`
#      created by the Serena MCP server is never swept into a commit by a
#      blanket `git add -A` / `git add .`.  Verified both against the
#      repository's real `.gitignore` and via a synthetic git repository that
#      reproduces the original bug scenario (a `docs(...)` commit that swept up
#      the Serena tool config).
#
#   2. A post-commit path-allowlist guard: after a commit-producing stage
#      commits, any path outside the code/`tests/` allowlist must trip the
#      guard.  The orchestrator gains this guard in issue #315; until that
#      change merges into the branch under test the orchestrator-source
#      assertion fails (RED) — the same convention used by
#      tests/agent-name-normalization.bats, which fails RED until issue #313
#      lands.  The path-allowlist *semantics* are pinned independently with a
#      self-contained reference check (the synthetic-scenario style of
#      tests/watchdog-fd-inheritance.bats), so the contract is documented and
#      verifiable regardless of merge order.
#
# AC4: BATS tests reproduce the stray-`.serena/project.yml` scenario and
# confirm it is no longer committed, and that the guard trips on a non-code
# commit; all pass (once the sibling issue #315 tasks are merged).

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
ORCHESTRATOR="$REPO_ROOT/.claude/scripts/implement-issue-orchestrator.sh"
GITIGNORE="$REPO_ROOT/.gitignore"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Keep git from reading the developer's global / system config inside the
	# throwaway repositories created below.
	export GIT_CONFIG_GLOBAL="$TEST_TMP/gitconfig"
	export GIT_CONFIG_SYSTEM=/dev/null
	export GIT_AUTHOR_NAME="test"
	export GIT_AUTHOR_EMAIL="test@example.com"
	export GIT_COMMITTER_NAME="test"
	export GIT_COMMITTER_EMAIL="test@example.com"
	: > "$GIT_CONFIG_GLOBAL"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create an empty git repository under $TEST_TMP/<name> and echo its path.
# Optional $2 is written verbatim as the repo's .gitignore.
_make_repo() {
	local name="$1"
	local gitignore_body="${2-}"
	local dir="$TEST_TMP/$name"

	mkdir -p "$dir"
	git -C "$dir" init -q
	if [[ -n "$gitignore_body" ]]; then
		printf '%s\n' "$gitignore_body" > "$dir/.gitignore"
	fi
	printf '%s\n' "$dir"
}

# Echo the paths touched by HEAD in the repo at $1, one per line.
_head_commit_paths() {
	local dir="$1"
	git -C "$dir" show --name-only --pretty=format: HEAD | sed '/^$/d'
}

# Reference implementation of the issue #315 post-commit path-allowlist
# guard, kept deliberately small.  Given a repo path, it inspects the paths
# touched by HEAD and returns non-zero (printing the offending paths) if any
# path is neither a recognised source-code file nor under `tests/`.  The
# orchestrator's own guard must agree with this contract on the cases pinned
# below — most importantly that `.serena/project.yml` is rejected and that a
# `.ts` file and a `tests/*.bats` file are accepted.
_post_commit_path_allowlist_check() {
	local dir="$1"
	local path ep
	local -a bad=() _extra=() _raw=()
	# Hoist the EXTRA_COMMIT_PATHS split outside the per-path loop.
	# Trim whitespace around each pipe-separated entry so values like
	# 'package.json | package-lock.json' work correctly.
	if [[ -n "${EXTRA_COMMIT_PATHS:-}" ]]; then
		IFS='|' read -ra _raw <<< "$EXTRA_COMMIT_PATHS"
		for ep in "${_raw[@]}"; do
			ep="${ep#"${ep%%[![:space:]]*}"}"
			ep="${ep%"${ep##*[![:space:]]}"}"
			[[ -n "$ep" ]] || continue
			_extra+=("$ep")
		done
	fi

	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		case "$path" in
			# Hard denylist — not overridable by EXTRA_COMMIT_PATHS.
			.github/workflows/**) bad+=("$path") ;;
			tests/*) continue ;;
			prisma/**) continue ;;
			docker-compose*.yml) continue ;;
			docs/**) continue ;;
			.claude/agents/**) continue ;;
			.claude/skills/**) continue ;;
			*.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.sh | *.bats)
				continue
				;;
			*)
				for ep in "${_extra[@]}"; do
					# shellcheck disable=SC2254
					case "$path" in
						$ep) continue 2 ;;
					esac
				done
				bad+=("$path") ;;
		esac
	done < <(_head_commit_paths "$dir")

	if (( ${#bad[@]} > 0 )); then
		printf 'commit touches paths outside the code/tests allowlist: %s\n' \
			"${bad[*]}" >&2
		return 1
	fi
	return 0
}

# Echo the name of a reusable commit-path-allowlist guard function defined in
# the orchestrator (issue #315 task 4), if one exists.  `sanitize_worktree_commits`
# is the pre-existing binary-file *denylist*, not the new allowlist guard, so it
# is excluded.  Echoes nothing when that orchestrator change has not landed on
# the branch under test.  Operates on the source text — no sourcing, so a
# heredoc-laden orchestrator cannot break the probe.
_orchestrator_guard_function_name() {
	[[ -f "$ORCHESTRATOR" ]] || return 0

	grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$ORCHESTRATOR" \
		| sed -E 's/\(\) \{$//' \
		| grep -E 'commit' \
		| grep -E 'allow|guard|path' \
		| grep -v -x 'sanitize_worktree_commits' \
		| head -n 1
}

# ===========================================================================
# Defense 1 — `.serena/` is gitignored
# ===========================================================================

@test "(1) repository .gitignore lists .serena/" {
	[[ -f "$GITIGNORE" ]] || fail "repo .gitignore not present"

	grep -Eq '^[[:space:]]*/?\.serena/?[[:space:]]*$' "$GITIGNORE" || {
		printf 'FAIL: .serena/ is not gitignored. .gitignore contents:\n' >&2
		cat "$GITIGNORE" >&2
		return 1
	}
}

@test "(2) a stray untracked .serena/project.yml is not swept into a blanket commit" {
	# Reproduce the original scenario: a feature stage runs a blanket
	# `git add -A` while the Serena MCP server has dropped a project.yml in
	# an untracked `.serena/` directory.  Seed the throwaway repo with the
	# repository's *real* .gitignore so this exercises the shipped fix.
	[[ -f "$GITIGNORE" ]] || fail "repo .gitignore not present"
	local repo
	repo="$(_make_repo serena-stray "$(cat "$GITIGNORE")")"

	mkdir -p "$repo/src" "$repo/.serena"
	printf 'export const x = 1;\n' > "$repo/src/app.ts"
	# A 1-line stand-in for the 107-line Serena tool config from the issue.
	printf 'project_name: demo\nlanguage: typescript\n' \
		> "$repo/.serena/project.yml"

	# Initial commit so HEAD exists, then the stage's blanket add + commit.
	git -C "$repo" add .gitignore
	git -C "$repo" commit -q -m "chore: seed"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "docs(issue-2921): add JSDoc comments"

	local paths
	paths="$(_head_commit_paths "$repo")"

	[[ "$paths" == *"src/app.ts"* ]] || {
		printf 'FAIL: expected src/app.ts in the commit, got:\n%s\n' \
			"$paths" >&2
		return 1
	}
	[[ "$paths" != *".serena/project.yml"* ]] || {
		printf 'FAIL: .serena/project.yml leaked into the commit:\n%s\n' \
			"$paths" >&2
		return 1
	}
}

@test "(3) .serena/project.yml is not reported as untracked under the repo .gitignore" {
	[[ -f "$GITIGNORE" ]] || fail "repo .gitignore not present"
	local repo
	repo="$(_make_repo serena-status "$(cat "$GITIGNORE")")"

	mkdir -p "$repo/.serena"
	printf 'project_name: demo\n' > "$repo/.serena/project.yml"

	run git -C "$repo" status --porcelain --ignored=no
	[ "$status" -eq 0 ]
	[[ "$output" != *".serena/"* ]] || {
		printf 'FAIL: git status still lists .serena/. Output:\n%s\n' \
			"$output" >&2
		return 1
	}
}

# ===========================================================================
# Defense 2 — post-commit path-allowlist guard
# ===========================================================================

@test "(4) reference allowlist check accepts a commit of only code + tests/ paths" {
	local repo
	repo="$(_make_repo guard-ok)"

	mkdir -p "$repo/src" "$repo/lib" "$repo/tests"
	printf 'export const a = 1;\n' > "$repo/src/a.ts"
	printf 'module.exports = {};\n' > "$repo/lib/b.js"
	printf '@test "x" { true; }\n' > "$repo/tests/c.bats"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "feat: code + tests"

	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -eq 0 ] || {
		printf 'FAIL: allowlist check rejected a code+tests commit: %s\n' \
			"$output" >&2
		return 1
	}
}

@test "(5) reference allowlist check rejects a commit that includes .serena/project.yml" {
	local repo
	repo="$(_make_repo guard-serena)"

	mkdir -p "$repo/src" "$repo/.serena"
	printf 'export const a = 1;\n' > "$repo/src/a.ts"
	printf 'project_name: demo\n' > "$repo/.serena/project.yml"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "docs(issue-2921): add JSDoc comments"

	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -ne 0 ] || fail "allowlist check accepted a .serena/ commit"
	[[ "$output" == *".serena/project.yml"* ]] || {
		printf 'FAIL: expected the error to name .serena/project.yml, got:\n%s\n' \
			"$output" >&2
		return 1
	}
}

@test "(4a) reference allowlist check accepts a commit of only prisma/ paths" {
	local repo
	repo="$(_make_repo guard-prisma)"

	mkdir -p "$repo/prisma/migrations/20260519_add_users"
	printf 'datasource db {\n  provider = "postgresql"\n}\n' \
		> "$repo/prisma/schema.prisma"
	printf 'CREATE TABLE users (id serial PRIMARY KEY);\n' \
		> "$repo/prisma/migrations/20260519_add_users/migration.sql"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "feat: add users migration"

	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -eq 0 ] || {
		printf 'FAIL: allowlist check rejected a prisma/ commit: %s\n' \
			"$output" >&2
		return 1
	}
}

@test "(4b) reference allowlist check accepts a commit of only docker-compose*.yml paths" {
	local repo
	repo="$(_make_repo guard-docker)"

	printf 'services:\n  backend:\n    environment:\n      JWT_SECRET: s3cr3t\n' \
		> "$repo/docker-compose.base.yml"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "feat: add JWT_SECRET env var"

	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -eq 0 ] || {
		printf 'FAIL: allowlist check rejected a docker-compose.base.yml commit: %s\n' \
			"$output" >&2
		return 1
	}
}

@test "(4c) reference allowlist check accepts a commit of only docs/ paths" {
	local repo
	repo="$(_make_repo guard-docs)"

	mkdir -p "$repo/docs"
	printf '# Architecture\n\nService overview.\n' \
		> "$repo/docs/01-ARCHITECTURE.md"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "docs: update architecture overview"

	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -eq 0 ] || {
		printf 'FAIL: allowlist check rejected a docs/ commit: %s\n' \
			"$output" >&2
		return 1
	}
}

@test "(4d) reference allowlist check accepts a commit of only .claude/agents/ paths" {
	local repo
	repo="$(_make_repo guard-claude-agents)"

	mkdir -p "$repo/.claude/agents"
	printf '# Agent\n\nInstructions.\n' \
		> "$repo/.claude/agents/code-reviewer.md"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "chore: update code-reviewer agent instructions"

	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -eq 0 ] || {
		printf 'FAIL: allowlist check rejected a .claude/agents/ commit: %s\n' \
			"$output" >&2
		return 1
	}
}

@test "(4e) reference allowlist check accepts a commit of only .claude/skills/ paths" {
	local repo
	repo="$(_make_repo guard-claude-skills)"

	mkdir -p "$repo/.claude/skills/pr-review"
	printf '# Skill\n\nInstructions.\n' \
		> "$repo/.claude/skills/pr-review/SKILL.md"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "chore: update pr-review skill"

	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -eq 0 ] || {
		printf 'FAIL: allowlist check rejected a .claude/skills/ commit: %s\n' \
			"$output" >&2
		return 1
	}
}

@test "(4f) reference allowlist: accepts package.json and lock file when EXTRA_COMMIT_PATHS opts them in" {
	local repo
	repo="$(_make_repo guard-pkg-json)"

	printf '{"name":"app","version":"1.0.0"}\n' \
		> "$repo/package.json"
	printf '# auto-generated lockfile\n' \
		> "$repo/package-lock.json"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "feat: install sanitize-html"

	# Rejected when EXTRA_COMMIT_PATHS is unset.
	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -ne 0 ] \
		|| fail "expected rejection without EXTRA_COMMIT_PATHS"
	[[ "$output" == *"package.json"* \
		|| "$output" == *"package-lock.json"* ]] || {
		printf \
			'FAIL: expected error to name package.json/lock, got:\n%s\n' \
			"$output" >&2
		return 1
	}

	# Accepted when EXTRA_COMMIT_PATHS opts them in.
	export EXTRA_COMMIT_PATHS="package.json|package-lock.json"
	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -eq 0 ] || {
		printf \
			'FAIL: expected acceptance with package.json in EXTRA_COMMIT_PATHS:\n%s\n' \
			"$output" >&2
		return 1
	}
}

@test "(5a) reference allowlist check rejects a commit that includes .github/workflows/ paths" {
	local repo
	repo="$(_make_repo guard-github-workflows)"

	mkdir -p "$repo/.github/workflows" "$repo/src"
	printf 'export const a = 1;\n' > "$repo/src/a.ts"
	printf 'name: ci\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n' \
		> "$repo/.github/workflows/ci.yml"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "feat: add ci workflow"

	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -ne 0 ] \
		|| fail "allowlist check accepted a .github/workflows/ commit"
	[[ "$output" == *".github/workflows/ci.yml"* ]] || {
		printf 'FAIL: expected error to name .github/workflows/ci.yml, got:\n%s\n' \
			"$output" >&2
		return 1
	}
}

@test "(5b) reference allowlist: .github/workflows/*.yml stays blocked even with EXTRA_COMMIT_PATHS" {
	local repo
	repo="$(_make_repo guard-workflows-nodoor)"

	mkdir -p "$repo/.github/workflows"
	printf \
		'name: ci\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n' \
		> "$repo/.github/workflows/ci.yml"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "chore: add workflow"

	# Stays blocked even when EXTRA_COMMIT_PATHS explicitly targets workflows.
	export EXTRA_COMMIT_PATHS=".github/workflows/**"
	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -ne 0 ] || {
		fail ".github/workflows/ must remain blocked regardless of EXTRA_COMMIT_PATHS"
	}
	[[ "$output" == *".github/workflows/ci.yml"* ]] || {
		printf \
			'FAIL: expected .github/workflows/ci.yml named in error:\n%s\n' \
			"$output" >&2
		return 1
	}
}

@test "(7) simplify-* and fix-review-* prompts carry the selective-staging instruction" {
	[[ -f "$ORCHESTRATOR" ]] || fail "orchestrator script not present"

	# The instruction must appear at least once inside the simplify_prompt
	# variable assignment so the simplify-* stage never uses git add -A / git add .
	grep -A 20 'local simplify_prompt=' "$ORCHESTRATOR" \
		| grep -qF "git diff --name-only" || {
		printf 'FAIL: simplify_prompt missing selective-staging instruction\n' >&2
		return 1
	}

	# The instruction must appear at least once inside the quality-loop
	# fix_prompt variable assignment (fix-review-* stage).
	grep -A 30 "Address code review feedback in working directory" \
		"$ORCHESTRATOR" \
		| grep -qF "git diff --name-only" || {
		printf 'FAIL: fix-review fix_prompt missing selective-staging instruction\n' >&2
		return 1
	}
}

@test "(6) orchestrator implements a post-commit path-allowlist guard" {
	[[ -f "$ORCHESTRATOR" ]] || fail "orchestrator script not present"

	# The guard must be reusable by commit-producing stages — i.e. a function.
	local guard
	guard="$(_orchestrator_guard_function_name)"

	# The issue specifies it inspects the new commit's file list with
	# `git show --name-only --pretty=format:`.
	local has_show_wiring=0
	grep -Fq 'git show --name-only --pretty=format:' "$ORCHESTRATOR" \
		&& has_show_wiring=1

	if [[ -z "$guard" && "$has_show_wiring" -eq 0 ]]; then
		printf 'FAIL: orchestrator has no commit-path-allowlist guard yet ' >&2
		printf '(expected a reusable guard function and/or a ' >&2
		printf '"git show --name-only --pretty=format:" commit inspection)\n' >&2
		return 1
	fi
}

# ===========================================================================
# EXTRA_COMMIT_PATHS — runtime-configurable additional allowlist entries
# ===========================================================================

@test "(8) reference allowlist: EXTRA_COMMIT_PATHS single glob allows blocked path" {
	local repo
	repo="$(_make_repo guard-extra-single)"

	mkdir -p "$repo/config"
	printf '{"env": "prod"}\n' > "$repo/config/app.json"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "feat: add app config"

	# Without EXTRA_COMMIT_PATHS the path is rejected.
	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -ne 0 ] \
		|| fail "expected rejection without EXTRA_COMMIT_PATHS"

	# With EXTRA_COMMIT_PATHS covering config/ it is accepted.
	export EXTRA_COMMIT_PATHS="config/**"
	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -eq 0 ] || {
		printf \
			'FAIL: expected acceptance with EXTRA_COMMIT_PATHS=config/**, got:\n%s\n' \
			"$output" >&2
		return 1
	}
}

@test "(9) reference allowlist: EXTRA_COMMIT_PATHS pipe-separated patterns each work" {
	local repo
	repo="$(_make_repo guard-extra-multi)"

	mkdir -p "$repo/config"
	printf '{"env": "prod"}\n' > "$repo/config/app.json"
	printf '{"name":"app","version":"1.0.0"}\n' > "$repo/package.json"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "feat: add config and package manifest"

	# Both paths blocked without EXTRA_COMMIT_PATHS.
	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -ne 0 ] \
		|| fail "expected rejection without EXTRA_COMMIT_PATHS"

	# Both paths allowed with pipe-separated patterns.
	export EXTRA_COMMIT_PATHS="config/**|package.json"
	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -eq 0 ] || {
		printf \
			'FAIL: pipe-separated EXTRA_COMMIT_PATHS still rejected commit:\n%s\n' \
			"$output" >&2
		return 1
	}
}

@test "(10) reference allowlist: EXTRA_COMMIT_PATHS does not open the floodgates" {
	local repo
	repo="$(_make_repo guard-extra-narrow)"

	mkdir -p "$repo/config" "$repo/.serena"
	printf '{"env": "prod"}\n' > "$repo/config/app.json"
	printf 'project_name: demo\n' > "$repo/.serena/project.yml"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m "chore: config commit with accidental serena file"

	# config/** allows config/app.json but NOT .serena/project.yml.
	export EXTRA_COMMIT_PATHS="config/**"
	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -ne 0 ] \
		|| fail "expected rejection: .serena/project.yml not in EXTRA_COMMIT_PATHS"
	[[ "$output" == *".serena/project.yml"* ]] || {
		printf \
			'FAIL: expected .serena/project.yml named in error, got:\n%s\n' \
			"$output" >&2
		return 1
	}
}

@test "(9a) reference allowlist: EXTRA_COMMIT_PATHS pipe patterns work with spaces around separators" {
	local repo
	repo="$(_make_repo guard-extra-spaces)"

	mkdir -p "$repo/config"
	printf '{"env": "prod"}\n' > "$repo/config/app.json"
	printf '{"name":"app","version":"1.0.0"}\n' > "$repo/package.json"
	git -C "$repo" add -A
	git -C "$repo" commit -q \
		-m "feat: add config and package manifest"

	# Both paths allowed even when spaces surround the pipe separator.
	export EXTRA_COMMIT_PATHS="config/** | package.json"
	run _post_commit_path_allowlist_check "$repo"
	[ "$status" -eq 0 ] || {
		printf \
			'FAIL: spaces around pipe in EXTRA_COMMIT_PATHS still rejected commit:\n%s\n' \
			"$output" >&2
		return 1
	}
}

