#!/usr/bin/env bats
#
# tests/sync-bundle.bats
# `sync.sh bundle` regenerates plugins/pipeline-core/scripts/ from
# .claude/scripts/ (issue #623 task 4) — the bundle is PRODUCED from the
# canonical tree rather than hand-edited, so drift like the one that shipped
# v0.3.0 without the #619 turn-budget fix can't happen silently.
#
# Runs against a fake temp repo (a copy of sync.sh plus fake .claude/scripts
# and plugins/pipeline-core/scripts trees) rather than the real repo, so the
# generator's copy/overwrite/remove behaviour can be asserted against known
# fixtures without depending on — or mutating — real repo content.
#
# The two trees are reconciled as of issue #623 task 2, so a live
# `./sync.sh bundle` is a safe no-op; test-bundle-parity.bats is the guard
# that keeps it that way.
#

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SYNC_SH="$REPO_ROOT/sync.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Scratch space OUTSIDE the fixture repo. Test artifacts written inside
	# TEST_TMP would show up in `git status` once TEST_TMP becomes a git repo,
	# and the bundle-regeneration tests assert on a clean working tree.
	TEST_SCRATCH=$(mktemp -d)
	export TEST_SCRATCH

	cp "$SYNC_SH" "$TEST_TMP/sync.sh"
	mkdir -p "$TEST_TMP/.claude/scripts" "$TEST_TMP/plugins/pipeline-core/scripts"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
	if [[ -n "$TEST_SCRATCH" && -d "$TEST_SCRATCH" ]]; then
		rm -rf "$TEST_SCRATCH"
	fi
}

# =============================================================================
# Structural — sync.sh must define bundle_scripts and wire it into a bundle
# command.
# =============================================================================

@test "sync.sh defines a bundle_scripts function" {
	grep -qE '^bundle_scripts\(\) \{' "$SYNC_SH" || {
		printf 'FAIL: bundle_scripts() not defined in sync.sh\n' >&2
		return 1
	}
}

@test "sync.sh bundle case calls bundle_scripts" {
	awk '/^[[:space:]]+bundle\)/{f=1} f{print} /^[[:space:]]+;;/{f=0}' \
		"$SYNC_SH" | grep -q 'bundle_scripts' || {
		printf 'FAIL: bundle) case does not call bundle_scripts\n' >&2
		return 1
	}
}

# The generator (sync.sh) and the drift guard (test-bundle-parity.bats) each
# carry their own list of bundled subdirectories. If they disagree, the
# generator regenerates a directory the guard never checks (or vice versa) and
# drift goes silent again — exactly the #623 failure mode. Comments alone
# don't enforce that, so assert the two lists are byte-identical.
@test "bundle subdir list matches the parity guard's subdir list" {
	local parity_bats bundle_list parity_list
	parity_bats="$REPO_ROOT/.claude/scripts/implement-issue-test"
	parity_bats+="/test-bundle-parity.bats"

	[[ -f "$parity_bats" ]] || {
		printf 'FAIL: parity guard not found: %s\n' "$parity_bats" >&2
		return 1
	}

	bundle_list=$(sed -n 's/^BUNDLE_SCRIPT_SUBDIRS=(\(.*\))$/\1/p' "$SYNC_SH")
	parity_list=$(sed -n 's/^PARITY_SUBDIRS=(\(.*\))$/\1/p' "$parity_bats")

	[[ -n "$bundle_list" ]] || {
		printf 'FAIL: BUNDLE_SCRIPT_SUBDIRS not found in sync.sh\n' >&2
		return 1
	}
	[[ -n "$parity_list" ]] || {
		printf 'FAIL: PARITY_SUBDIRS not found in %s\n' "$parity_bats" >&2
		return 1
	}

	[[ "$bundle_list" == "$parity_list" ]] || {
		printf 'FAIL: subdir lists diverged\n  sync.sh:  %s\n  parity:   %s\n' \
			"$bundle_list" "$parity_list" >&2
		return 1
	}
}

# =============================================================================
# Integration — run `sync.sh bundle` against a fake repo.
# =============================================================================

@test "(AC) bundle copies a canonical script the bundle is missing" {
	printf '#!/usr/bin/env bash\necho hi\n' \
		> "$TEST_TMP/.claude/scripts/new-script.sh"

	run bash "$TEST_TMP/sync.sh" bundle
	[ "$status" -eq 0 ] || {
		printf 'bundle exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	local bundled="$TEST_TMP/plugins/pipeline-core/scripts/new-script.sh"
	[[ -f "$bundled" ]] || fail "new-script.sh was not copied into the bundle"
	diff -q "$TEST_TMP/.claude/scripts/new-script.sh" "$bundled" || \
		fail "copied script content differs from canonical"
}

@test "(AC) bundle overwrites a stale bundled script with canonical content" {
	printf '#!/usr/bin/env bash\necho new\n' \
		> "$TEST_TMP/.claude/scripts/existing.sh"
	printf '#!/usr/bin/env bash\necho old\n' \
		> "$TEST_TMP/plugins/pipeline-core/scripts/existing.sh"

	run bash "$TEST_TMP/sync.sh" bundle
	[ "$status" -eq 0 ] || {
		printf 'bundle exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	grep -q 'echo new' "$TEST_TMP/plugins/pipeline-core/scripts/existing.sh" || \
		fail "stale bundled script was not overwritten with canonical content"
}

@test "(AC) bundle removes a bundled script with no canonical counterpart" {
	printf '#!/usr/bin/env bash\necho orphan\n' \
		> "$TEST_TMP/plugins/pipeline-core/scripts/orphan.sh"

	run bash "$TEST_TMP/sync.sh" bundle
	[ "$status" -eq 0 ] || {
		printf 'bundle exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	[[ ! -f "$TEST_TMP/plugins/pipeline-core/scripts/orphan.sh" ]] || \
		fail "orphaned bundled script was not removed"
}

@test "(AC4) bundle produces no diff when trees are already in sync" {
	printf '#!/usr/bin/env bash\necho same\n' \
		> "$TEST_TMP/.claude/scripts/same.sh"
	cp "$TEST_TMP/.claude/scripts/same.sh" \
		"$TEST_TMP/plugins/pipeline-core/scripts/same.sh"

	run bash "$TEST_TMP/sync.sh" bundle
	[ "$status" -eq 0 ] || {
		printf 'bundle exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	diff -q "$TEST_TMP/.claude/scripts/same.sh" \
		"$TEST_TMP/plugins/pipeline-core/scripts/same.sh" || \
		fail "bundle introduced drift on an already-synced pair"
}

@test "bundle does not touch non-.sh content in the bundle" {
	mkdir -p "$TEST_TMP/plugins/pipeline-core/scripts/platform"
	echo "keep me" > "$TEST_TMP/plugins/pipeline-core/scripts/platform/foo.txt"

	run bash "$TEST_TMP/sync.sh" bundle
	[ "$status" -eq 0 ] || {
		printf 'bundle exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	[[ -f "$TEST_TMP/plugins/pipeline-core/scripts/platform/foo.txt" ]] || \
		fail "bundle touched files outside the top-level *.sh scope"
}

@test "bundle is idempotent — a second run makes no further changes" {
	printf '#!/usr/bin/env bash\necho v1\n' \
		> "$TEST_TMP/.claude/scripts/a.sh"

	run bash "$TEST_TMP/sync.sh" bundle
	[ "$status" -eq 0 ]

	run bash "$TEST_TMP/sync.sh" bundle
	[ "$status" -eq 0 ] || {
		printf 'second bundle run exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	diff -q "$TEST_TMP/.claude/scripts/a.sh" \
		"$TEST_TMP/plugins/pipeline-core/scripts/a.sh" || \
		fail "second bundle run diverged from canonical"
}

# =============================================================================
# Consumer sync scope (issue #632)
#
# `.claude/scripts/` is this repo's DOGFOOD tree. Consumers get the same
# scripts from the pipeline-core plugin bundle, so copying the canonical tree
# into a consumer leaves dead duplicates: 132 orphaned files in
# stevegrocott/beegee-farm-3, 53 of them .bats suites targeting orchestrators
# the plugin migration had already removed. The synced copies are also
# unrepairable in place (upstream's platform/ needs ../resolve-pipeline-root.sh,
# which the plugin migration deletes from the consumer), so the fix is scope
# narrowing, not content updates.
#
# These run `sync.sh to` against a throwaway fixture consumer — never a real
# repo.
# =============================================================================

# Populate the fake pipeline repo created in setup() with the tree shape
# `sync.sh to` reads: a canonical scripts/ tree, hooks/, consumer config, and
# a plugin bundle that already provides the scripts.
_make_fake_pipeline() {
	mkdir -p "$TEST_TMP/.claude/scripts/platform" \
		"$TEST_TMP/.claude/hooks" \
		"$TEST_TMP/.claude/config" \
		"$TEST_TMP/plugins/pipeline-core/scripts/platform"

	printf '#!/usr/bin/env bash\necho orchestrator\n' \
		> "$TEST_TMP/.claude/scripts/implement-issue-orchestrator.sh"
	printf '#!/usr/bin/env bash\necho create-issue\n' \
		> "$TEST_TMP/.claude/scripts/platform/create-issue.sh"
	# Every hook on sync.sh's BUNDLE_HOOKS allowlist must exist: bundle_hooks
	# (issue #640) fails loudly on an allowlisted hook that is missing, which
	# is the drift guard working as intended. A fixture carrying only some of
	# them makes `sync.sh bundle` exit 1 for a reason unrelated to what these
	# tests are asserting. Read the allowlist from sync.sh rather than
	# hardcoding it, so adding a hook there cannot silently rot this fixture.
	local _hook
	while IFS= read -r _hook; do
		[[ -n "$_hook" ]] || continue
		printf '#!/usr/bin/env bash\necho hook\n' \
			> "$TEST_TMP/.claude/hooks/$_hook"
	done < <(awk '/^BUNDLE_HOOKS=\(/{f=1;next} f&&/^\)/{exit} f{gsub(/[[:space:]]/,"");print}' \
		"$SYNC_SH")
	printf 'TRACKER=github\n' > "$TEST_TMP/.claude/config/platform.sh"
	printf '# pipeline context\n' > "$TEST_TMP/.claude/config/context.md"

	# The plugin bundle already provides the whole scripts tree.
	cp "$TEST_TMP/.claude/scripts/implement-issue-orchestrator.sh" \
		"$TEST_TMP/plugins/pipeline-core/scripts/"
	cp "$TEST_TMP/.claude/scripts/platform/create-issue.sh" \
		"$TEST_TMP/plugins/pipeline-core/scripts/platform/"
}

# A throwaway consumer repo shaped like one /adapting-claude-pipeline produced:
# a .claude/ with an agents/ dir (patch_agents walks it) and nothing else.
_make_fake_consumer() {
	CONSUMER="$TEST_TMP/consumer"
	mkdir -p "$CONSUMER/.claude/agents"
	printf -- '---\nname: local-agent\n---\n' \
		> "$CONSUMER/.claude/agents/local-agent.md"
}

@test "(#632 AC1) consumer sync writes no files under .claude/scripts/" {
	_make_fake_pipeline
	_make_fake_consumer

	run bash "$TEST_TMP/sync.sh" to "$CONSUMER"
	[ "$status" -eq 0 ] || {
		printf 'sync to exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	local written
	written=$(find "$CONSUMER/.claude/scripts" -type f 2>/dev/null | wc -l)
	written=${written// /}

	[[ "$written" == "0" ]] || {
		printf 'FAIL: consumer sync wrote %s file(s) under .claude/scripts/:\n' \
			"$written" >&2
		find "$CONSUMER/.claude/scripts" -type f >&2
		return 1
	}
}

@test "(#632 AC2) consumer sync leaves no path the plugin already provides" {
	_make_fake_pipeline
	_make_fake_consumer

	run bash "$TEST_TMP/sync.sh" to "$CONSUMER"
	[ "$status" -eq 0 ] || {
		printf 'sync to exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	local written rel shadowed=""
	while IFS= read -r written; do
		rel="${written#"$CONSUMER/.claude/"}"
		if [[ -e "$TEST_TMP/plugins/pipeline-core/$rel" ]]; then
			shadowed+="  .claude/$rel"$'\n'
		fi
	done < <(find "$CONSUMER/.claude" -type f)

	[[ -z "$shadowed" ]] || {
		printf 'FAIL: consumer paths shadow the plugin bundle:\n%s' \
			"$shadowed" >&2
		return 1
	}
}

@test "(#632 AC3) a sync that would write a plugin-provided path fails with a named reason" {
	_make_fake_pipeline
	_make_fake_consumer

	# Re-widen the scope the way it was before this fix: put "scripts" back
	# into CORE_DIRS. The guard — not the constant — is what must stop this.
	awk '/^CORE_DIRS=\(/ { print; print "    \"scripts\""; next } { print }' \
		"$TEST_TMP/sync.sh" > "$TEST_TMP/sync-widened.sh"

	run bash "$TEST_TMP/sync-widened.sh" to "$CONSUMER"

	[ "$status" -ne 0 ] || {
		printf 'FAIL: widened sync succeeded silently:\n%s\n' "$output" >&2
		return 1
	}
	[[ "$output" == *"pipeline-core"* ]] || {
		printf 'FAIL: failure does not name the plugin:\n%s\n' "$output" >&2
		return 1
	}
	[[ "$output" == *"scripts/implement-issue-orchestrator.sh"* ]] || {
		printf 'FAIL: failure does not name the offending path:\n%s\n' \
			"$output" >&2
		return 1
	}
	[[ ! -f "$CONSUMER/.claude/scripts/implement-issue-orchestrator.sh" ]] || {
		printf 'FAIL: guard fired but the file was written anyway\n' >&2
		return 1
	}
}

@test "(#632 AC4) consumer config still syncs" {
	_make_fake_pipeline
	_make_fake_consumer

	run bash "$TEST_TMP/sync.sh" to "$CONSUMER"
	[ "$status" -eq 0 ] || {
		printf 'sync to exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	[[ -f "$CONSUMER/.claude/config/platform.sh" ]] || {
		printf 'FAIL: config/platform.sh was not synced\n' >&2
		return 1
	}
	[[ -f "$CONSUMER/.claude/config/context.md" ]] || {
		printf 'FAIL: config/context.md was not synced\n' >&2
		return 1
	}
}

# config/ is consumer-OWNED (tracker, git host, test commands). Seeding a repo
# that has none is useful; overwriting one that has its own is destructive, so
# the sync must leave an existing file alone.
@test "(#632 AC4) an existing consumer config is not clobbered" {
	_make_fake_pipeline
	_make_fake_consumer

	mkdir -p "$CONSUMER/.claude/config"
	printf 'TRACKER=jira\n' > "$CONSUMER/.claude/config/platform.sh"

	run bash "$TEST_TMP/sync.sh" to "$CONSUMER"
	[ "$status" -eq 0 ] || {
		printf 'sync to exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	grep -q 'TRACKER=jira' "$CONSUMER/.claude/config/platform.sh" || {
		printf 'FAIL: consumer platform.sh was clobbered:\n%s\n' \
			"$(cat "$CONSUMER/.claude/config/platform.sh")" >&2
		return 1
	}
}

# =============================================================================
# Consumer with no .claude/agents/ (issue #641)
#
# patch_agents() guards on .claude/agents/ existing with
# `[[ -d "$agents_dir" ]] || return`. A bare `return` propagates the failed
# `[[ -d ]]` test's own exit status (1), and patch_agents is the last call in
# the `to` branch, so that 1 becomes sync.sh's own exit status even though
# every file synced correctly. All nine local consumers happen to have an
# agents/ dir, so this only bites a brand-new consumer being onboarded.
# =============================================================================

# A throwaway consumer shaped like a brand-new onboarding: a .claude/ with no
# agents/ subdirectory at all — patch_agents's not-applicable case.
_make_fake_consumer_no_agents() {
	CONSUMER="$TEST_TMP/consumer-no-agents"
	mkdir -p "$CONSUMER/.claude"
}

@test "(#641 AC1) sync.sh to exits 0 against a consumer with no .claude/agents/" {
	_make_fake_pipeline
	_make_fake_consumer_no_agents

	[[ ! -d "$CONSUMER/.claude/agents" ]] || {
		printf 'FAIL: fixture unexpectedly has an agents/ dir\n' >&2
		return 1
	}

	run bash "$TEST_TMP/sync.sh" to "$CONSUMER"
	[ "$status" -eq 0 ] || {
		printf 'FAIL: sync to exited %d against an agents-less consumer:\n%s\n' \
			"$status" "$output" >&2
		return 1
	}
}

@test "(#641 AC2) that sync still writes .claude/config/ and .claude/hooks/" {
	_make_fake_pipeline
	_make_fake_consumer_no_agents

	run bash "$TEST_TMP/sync.sh" to "$CONSUMER"
	[ "$status" -eq 0 ] || {
		printf 'sync to exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	[[ -f "$CONSUMER/.claude/config/platform.sh" ]] || {
		printf 'FAIL: config/platform.sh was not synced\n' >&2
		return 1
	}

	local hooks_written
	hooks_written=$(find "$CONSUMER/.claude/hooks" -type f 2>/dev/null | wc -l)
	hooks_written=${hooks_written// /}
	(( hooks_written > 0 )) || {
		printf 'FAIL: no hooks were synced to the agents-less consumer\n' >&2
		return 1
	}
}

# AC4: pin the fix at its defect site, not just its symptom. Re-widen the
# guard back to a bare `return` (the #641 regression) and confirm THIS test
# suite catches it — mirrors the (#632 AC3) pattern above, where the fixture
# proves the specific line is what stops the regression.
@test "(#641 AC4) a bare 'return' in the patch_agents guard fails this suite" {
	_make_fake_pipeline
	_make_fake_consumer_no_agents

	sed 's/\[\[ -d "\$agents_dir" \]\] || return 0/[[ -d "$agents_dir" ]] || return/' \
		"$TEST_TMP/sync.sh" > "$TEST_TMP/sync-regressed.sh"
	grep -qF '[[ -d "$agents_dir" ]] || return' \
		"$TEST_TMP/sync-regressed.sh" || {
		printf 'FAIL: regression fixture did not reintroduce the bare return\n' >&2
		return 1
	}
	! grep -qF '[[ -d "$agents_dir" ]] || return 0' \
		"$TEST_TMP/sync-regressed.sh" || {
		printf 'FAIL: regression fixture still has the fixed "return 0"\n' >&2
		return 1
	}

	run bash "$TEST_TMP/sync-regressed.sh" to "$CONSUMER"
	[ "$status" -ne 0 ] || {
		printf 'FAIL: regressed guard did not reproduce the exit-1 bug\n' >&2
		return 1
	}
}

# =============================================================================
# Bundle regeneration inside the pipeline (issue #632, second gap)
#
# `./sync.sh bundle` is the generator, but nothing in the pipeline ran it, so
# every pipeline PR touching a canonical script arrived with a stale bundle and
# a red `Bundle Parity & Syntax` check (#620 PR #628 stayed red across two full
# fix iterations; #633 hit the same). The PR-review loop reads diff logic, not
# CI conclusions, so no reviewer raised it.
#
# The hook lives in implement-issue-orchestrator.sh before the PR stage. These
# tests extract that one function and drive it against a throwaway git repo.
# =============================================================================

ORCHESTRATOR="$REPO_ROOT/.claude/scripts/implement-issue-orchestrator.sh"

# Extract a single top-level function body from the orchestrator so it can be
# sourced without running the 10k-line script (or its main()).
_extract_orchestrator_fn() {
	local fn="$1" out="$2"

	awk -v fn="$fn" '
		$0 ~ "^" fn "\\(\\) \\{" { f = 1 }
		f { print }
		f && /^\}$/ { exit }
	' "$ORCHESTRATOR" > "$out"

	[[ -s "$out" ]] || {
		printf 'FAIL: %s() not found in %s\n' "$fn" "$ORCHESTRATOR" >&2
		return 1
	}
}

# Run the extracted hook with the orchestrator's logging helpers stubbed.
_run_regen_hook() {
	local work_dir="$1" base="$2"
	local fn_file="$TEST_SCRATCH/regen-fn.bash"

	_extract_orchestrator_fn regenerate_bundle_if_needed "$fn_file" || return 1

	run bash -c '
		set -uo pipefail
		ISSUE_NUMBER=632
		log() { printf "%s\n" "$*" >&2; }
		log_error() { printf "ERROR: %s\n" "$*" >&2; }
		log_warn() { printf "WARN: %s\n" "$*" >&2; }
		# shellcheck disable=SC1090
		. "$1"
		regenerate_bundle_if_needed "$2" "$3"
	' _ "$fn_file" "$work_dir" "$base"
}

# Build a git repo holding the fake pipeline, with the canonical tree and the
# bundle in sync on the base branch.
_init_pipeline_git_repo() {
	_make_fake_pipeline

	git -C "$TEST_TMP" init -q -b main
	git -C "$TEST_TMP" config user.email "test@example.com"
	git -C "$TEST_TMP" config user.name "Test"
	git -C "$TEST_TMP" add -A
	git -C "$TEST_TMP" commit -qm "base"
}

# A correct function that main() never calls fixes nothing — the #628 failure
# was a missing CALL, not a missing capability. Assert the wiring, and assert
# it lands before the PR is opened.
@test "(#632 AC7) the regeneration hook runs before the PR stage" {
	local call_line pr_line

	call_line=$(grep -n '^[[:space:]]*regenerate_bundle_if_needed "' \
		"$ORCHESTRATOR" | head -1 | cut -d: -f1)
	[[ -n "$call_line" ]] || {
		printf 'FAIL: regenerate_bundle_if_needed is never called\n' >&2
		return 1
	}

	pr_line=$(grep -n 'run_stage "pr" ' "$ORCHESTRATOR" | head -1 | cut -d: -f1)
	[[ -n "$pr_line" ]] || {
		printf 'FAIL: could not locate the PR stage in %s\n' "$ORCHESTRATOR" >&2
		return 1
	}

	(( call_line < pr_line )) || {
		printf 'FAIL: regeneration (line %s) runs after the PR stage (line %s)\n' \
			"$call_line" "$pr_line" >&2
		return 1
	}
}

@test "(#632 AC7/AC8) a canonical script edit leaves the bundle in sync and committed" {
	_init_pipeline_git_repo

	# Replay the #620 / PR #628 state: canonical orchestrator edited on a
	# feature branch, bundle untouched.
	git -C "$TEST_TMP" checkout -q -b wt/i632
	printf '#!/usr/bin/env bash\necho orchestrator v2\n' \
		> "$TEST_TMP/.claude/scripts/implement-issue-orchestrator.sh"
	git -C "$TEST_TMP" add -A
	git -C "$TEST_TMP" commit -qm "feat: edit canonical orchestrator"

	# Precondition: the trees HAVE diverged, i.e. the state that went red.
	! diff -q "$TEST_TMP/.claude/scripts/implement-issue-orchestrator.sh" \
		"$TEST_TMP/plugins/pipeline-core/scripts/implement-issue-orchestrator.sh" \
		> /dev/null 2>&1 || {
		printf 'FAIL: fixture did not reproduce a stale bundle\n' >&2
		return 1
	}

	_run_regen_hook "$TEST_TMP" main || return 1
	[ "$status" -eq 0 ] || {
		printf 'regen hook exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	# AC7: bundle back in sync.
	diff -q "$TEST_TMP/.claude/scripts/implement-issue-orchestrator.sh" \
		"$TEST_TMP/plugins/pipeline-core/scripts/implement-issue-orchestrator.sh" \
		> /dev/null || {
		printf 'FAIL: bundle still stale after the regeneration hook\n' >&2
		return 1
	}

	# The regenerated bundle must be COMMITTED, not left dangling in the
	# working tree — the PR is created from the branch, not the worktree.
	local dirty
	dirty=$(git -C "$TEST_TMP" status --porcelain)
	[[ -z "$dirty" ]] || {
		printf 'FAIL: regenerated bundle left uncommitted:\n%s\n' "$dirty" >&2
		return 1
	}

	# AC7 (CI equivalence): `./sync.sh bundle` is now a no-op, which is
	# exactly what Bundle Parity & Syntax asserts.
	bash "$TEST_TMP/sync.sh" bundle > /dev/null
	dirty=$(git -C "$TEST_TMP" status --porcelain)
	[[ -z "$dirty" ]] || {
		printf 'FAIL: bundle parity would still be red:\n%s\n' "$dirty" >&2
		return 1
	}
}

@test "(#632) the regeneration hook is a no-op when no canonical script changed" {
	_init_pipeline_git_repo

	git -C "$TEST_TMP" checkout -q -b wt/i632
	printf '# docs only\n' > "$TEST_TMP/README.md"
	git -C "$TEST_TMP" add -A
	git -C "$TEST_TMP" commit -qm "docs: readme"

	local head_before
	head_before=$(git -C "$TEST_TMP" rev-parse HEAD)

	_run_regen_hook "$TEST_TMP" main || return 1
	[ "$status" -eq 0 ] || {
		printf 'regen hook exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	[[ "$(git -C "$TEST_TMP" rev-parse HEAD)" == "$head_before" ]] || {
		printf 'FAIL: hook committed on a run with no canonical script change\n' >&2
		return 1
	}
}

# Consumers install the orchestrator from the plugin bundle and have neither
# sync.sh nor plugins/pipeline-core/. The hook must be inert there rather than
# failing the run just before the PR stage.
@test "(#632) the regeneration hook is inert in a repo with no bundle generator" {
	mkdir -p "$TEST_TMP/consumer-repo/.claude/scripts"
	git -C "$TEST_TMP/consumer-repo" init -q -b main
	git -C "$TEST_TMP/consumer-repo" config user.email "test@example.com"
	git -C "$TEST_TMP/consumer-repo" config user.name "Test"
	printf '#!/usr/bin/env bash\necho x\n' \
		> "$TEST_TMP/consumer-repo/.claude/scripts/local.sh"
	git -C "$TEST_TMP/consumer-repo" add -A
	git -C "$TEST_TMP/consumer-repo" commit -qm "base"
	git -C "$TEST_TMP/consumer-repo" checkout -q -b feature
	printf '#!/usr/bin/env bash\necho y\n' \
		> "$TEST_TMP/consumer-repo/.claude/scripts/local.sh"
	git -C "$TEST_TMP/consumer-repo" add -A
	git -C "$TEST_TMP/consumer-repo" commit -qm "edit"

	_run_regen_hook "$TEST_TMP/consumer-repo" main || return 1
	[ "$status" -eq 0 ] || {
		printf 'FAIL: hook failed in a consumer repo (exit %d):\n%s\n' \
			"$status" "$output" >&2
		return 1
	}
}

# The AC7 hook only covers commits that exist before the PR is opened. A
# PR-review fix stage commits AFTER that point and can touch a canonical
# .claude/scripts/ file just as easily as the initial implementation — left
# alone, that post-PR commit re-diverges the bundle and the push carries a
# stale one. Assert a second call site exists, and that it sits immediately
# before the fix-stage's push, not just somewhere in the file.
@test "(#675) the regeneration hook also runs before the post-PR fix-stage push" {
	local -a regen_lines
	local push_line closest_regen line between

	push_line=$(grep -n 'git push origin "\$branch"' "$ORCHESTRATOR" \
		| head -1 | cut -d: -f1)
	[[ -n "$push_line" ]] || {
		printf 'FAIL: could not locate the fix-stage push in %s\n' \
			"$ORCHESTRATOR" >&2
		return 1
	}

	while IFS= read -r line; do
		regen_lines+=("$line")
	done < <(grep -n '^[[:space:]]*regenerate_bundle_if_needed "' \
		"$ORCHESTRATOR" | cut -d: -f1)

	(( ${#regen_lines[@]} >= 2 )) || {
		printf 'FAIL: expected a pre-PR call and a fix-stage call, found %d\n' \
			"${#regen_lines[@]}" >&2
		return 1
	}

	# The regeneration call closest to (and before) the push is the one that
	# must guard it.
	closest_regen=0
	for line in "${regen_lines[@]}"; do
		(( line < push_line )) && closest_regen=$line
	done
	(( closest_regen > 0 )) || {
		printf 'FAIL: no regenerate_bundle_if_needed call precedes the fix-stage push (line %s)\n' \
			"$push_line" >&2
		return 1
	}

	# No `git commit`/`git add` may sit between the guarding call and the
	# push — that would slip a commit past the regeneration hook and
	# re-diverge the bundle right before the push carries it. Other
	# additions between the two calls (retry logic, status logging) are
	# fine and must not fail this test, so assert on the specific hazard
	# (a commit slipping past the guard) rather than on any code at all
	# sitting between them.
	between=$(sed -n "$((closest_regen + 1)),$((push_line - 1))p" \
		"$ORCHESTRATOR" \
		| grep -E '\bgit([[:space:]]+-C[[:space:]]+\S+)?[[:space:]]+(commit|add)\b' \
		|| true)
	[[ -z "$between" ]] || {
		printf 'FAIL: git commit/add between regeneration and push:\n%s\n' \
			"$between" >&2
		return 1
	}
}

# The structural test above only proves the fix-stage call site exists; it
# says nothing about whether a regeneration run at THAT point in history
# actually lands the trees in sync. This drives the extracted hook through
# the full #666/#651 replay — an implementation commit, the pre-PR
# regeneration, then a fix-pr-review commit touching the same canonical
# script — and asserts the bundle matches at the moment a push would carry
# it (AC1/AC2).
@test "(#675) a fix-pr-review commit touching a canonical script leaves the bundle in sync at push time" {
	_init_pipeline_git_repo

	# Implementation commit, pre-PR (#666 / #651 replay).
	git -C "$TEST_TMP" checkout -q -b wt/i675
	printf '#!/usr/bin/env bash\necho orchestrator v2\n' \
		> "$TEST_TMP/.claude/scripts/implement-issue-orchestrator.sh"
	git -C "$TEST_TMP" add -A
	git -C "$TEST_TMP" commit -qm "feat: implementation commit"

	# The #632 pre-PR call site.
	_run_regen_hook "$TEST_TMP" main || return 1
	[ "$status" -eq 0 ] || {
		printf 'pre-PR regen hook exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}
	diff -q "$TEST_TMP/.claude/scripts/implement-issue-orchestrator.sh" \
		"$TEST_TMP/plugins/pipeline-core/scripts/implement-issue-orchestrator.sh" \
		> /dev/null || {
		printf 'FAIL: fixture bundle not in sync after the pre-PR regeneration\n' >&2
		return 1
	}

	# The PR is now open. A fix-pr-review-iterN commit lands afterwards and
	# edits the same canonical script again — the entire #675 failure mode.
	printf '#!/usr/bin/env bash\necho orchestrator v3 (fix-pr-review)\n' \
		> "$TEST_TMP/.claude/scripts/implement-issue-orchestrator.sh"
	git -C "$TEST_TMP" add -A
	git -C "$TEST_TMP" commit -qm "fix-pr-review-iter1: address review comment"

	# Precondition: the fix commit re-diverged the bundle, i.e. the state
	# that went red in #620 / #666 / #651 and needed a human to run
	# sync.sh by hand.
	! diff -q "$TEST_TMP/.claude/scripts/implement-issue-orchestrator.sh" \
		"$TEST_TMP/plugins/pipeline-core/scripts/implement-issue-orchestrator.sh" \
		> /dev/null 2>&1 || {
		printf 'FAIL: fixture did not reproduce the post-PR re-divergence\n' >&2
		return 1
	}

	# The fix-stage's guarding call, immediately before its push.
	_run_regen_hook "$TEST_TMP" main || return 1
	[ "$status" -eq 0 ] || {
		printf 'fix-stage regen hook exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	# AC1/AC2: at push time — right now, since a real push carries whatever
	# HEAD holds — the bundle matches the canonical tree.
	diff -q "$TEST_TMP/.claude/scripts/implement-issue-orchestrator.sh" \
		"$TEST_TMP/plugins/pipeline-core/scripts/implement-issue-orchestrator.sh" \
		> /dev/null || {
		printf 'FAIL: bundle still stale at push time after the fix-stage commit\n' >&2
		return 1
	}

	# The regenerated bundle must be committed — a push carries HEAD, not
	# the working tree.
	local dirty
	dirty=$(git -C "$TEST_TMP" status --porcelain)
	[[ -z "$dirty" ]] || {
		printf 'FAIL: regenerated bundle left uncommitted at push time:\n%s\n' \
			"$dirty" >&2
		return 1
	}

	# CI equivalence: Bundle Parity & Syntax would be green on the commit
	# that gets pushed.
	bash "$TEST_TMP/sync.sh" bundle > /dev/null
	dirty=$(git -C "$TEST_TMP" status --porcelain)
	[[ -z "$dirty" ]] || {
		printf 'FAIL: Bundle Parity & Syntax would still be red:\n%s\n' \
			"$dirty" >&2
		return 1
	}
}

# AC3: the fix-stage call site reuses the same hook as the pre-PR call, but
# that must not be assumed — assert directly that a fix-pr-review commit
# touching no canonical script triggers neither a regeneration nor a commit
# at the point the fix-stage push would carry it. Without this, a future
# change that makes the fix-stage call unconditional (e.g. dropping the base
# diff) would slip a spurious "chore(bundle)" commit into every review-fix
# push, unnoticed.
@test "(#675 AC3) the fix-stage regeneration is a no-op when the fix-pr-review commit changes no canonical script" {
	_init_pipeline_git_repo

	# Implementation commit, pre-PR (#666 / #651 replay) — same setup as the
	# AC1/AC2 test above, so the bundle is already in sync before the
	# fix-pr-review commit under test lands.
	git -C "$TEST_TMP" checkout -q -b wt/i675-ac3
	printf '#!/usr/bin/env bash\necho orchestrator v2\n' \
		> "$TEST_TMP/.claude/scripts/implement-issue-orchestrator.sh"
	git -C "$TEST_TMP" add -A
	git -C "$TEST_TMP" commit -qm "feat: implementation commit"

	_run_regen_hook "$TEST_TMP" main || return 1
	[ "$status" -eq 0 ] || {
		printf 'pre-PR regen hook exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	# A fix-pr-review-iterN commit that touches only non-canonical content —
	# the case where the fix-stage call must do nothing.
	printf '# review note\n' > "$TEST_TMP/README.md"
	git -C "$TEST_TMP" add -A
	git -C "$TEST_TMP" commit -qm "fix-pr-review-iter1: address review comment"

	local head_before
	head_before=$(git -C "$TEST_TMP" rev-parse HEAD)

	# The fix-stage's guarding call, immediately before its push.
	_run_regen_hook "$TEST_TMP" main || return 1
	[ "$status" -eq 0 ] || {
		printf 'fix-stage regen hook exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	# The hook diffs base_branch...HEAD (the whole PR so far), not just the
	# latest commit, so it re-examines the earlier implementation commit here
	# too — that is by design (#632) and cheap, per the #675 evaluation's own
	# "negligible" framing. What AC3 actually forbids is an observable
	# regeneration: a new commit, or the bundle tree changing underneath it.
	[[ "$(git -C "$TEST_TMP" rev-parse HEAD)" == "$head_before" ]] || {
		printf 'FAIL: fix-stage hook committed although no canonical script changed\n' >&2
		return 1
	}

	local dirty
	dirty=$(git -C "$TEST_TMP" status --porcelain)
	[[ -z "$dirty" ]] || {
		printf 'FAIL: fix-stage hook left the working tree dirty on a no-op run:\n%s\n' \
			"$dirty" >&2
		return 1
	}
}

# AC4: consumers install the orchestrator from the plugin bundle and have
# neither sync.sh nor plugins/pipeline-core/ (#632 AC8). The fix-stage call
# site must stay inert there too, across the same pre-PR-then-fix-pr-review
# replay used by the AC1/AC2 and AC3 tests above — not just on a single call,
# as the pre-existing (#632) inert test already covers.
@test "(#675 AC4) the fix-stage regeneration stays inert across a fix-pr-review commit in a repo with no bundle generator" {
	mkdir -p "$TEST_TMP/consumer-repo/.claude/scripts"
	git -C "$TEST_TMP/consumer-repo" init -q -b main
	git -C "$TEST_TMP/consumer-repo" config user.email "test@example.com"
	git -C "$TEST_TMP/consumer-repo" config user.name "Test"
	printf '#!/usr/bin/env bash\necho x\n' \
		> "$TEST_TMP/consumer-repo/.claude/scripts/local.sh"
	git -C "$TEST_TMP/consumer-repo" add -A
	git -C "$TEST_TMP/consumer-repo" commit -qm "base"

	# Implementation commit, pre-PR call — mirrors the pipeline-repo replay,
	# but against a consumer with no generator.
	git -C "$TEST_TMP/consumer-repo" checkout -q -b wt/i675-ac4
	printf '#!/usr/bin/env bash\necho y\n' \
		> "$TEST_TMP/consumer-repo/.claude/scripts/local.sh"
	git -C "$TEST_TMP/consumer-repo" add -A
	git -C "$TEST_TMP/consumer-repo" commit -qm "feat: implementation commit"

	_run_regen_hook "$TEST_TMP/consumer-repo" main || return 1
	[ "$status" -eq 0 ] || {
		printf 'FAIL: pre-PR hook failed in a consumer repo (exit %d):\n%s\n' \
			"$status" "$output" >&2
		return 1
	}

	# fix-pr-review-iterN commit touching the canonical-shaped path again —
	# still must not blow up or fabricate a bundle in a repo with no
	# generator.
	printf '#!/usr/bin/env bash\necho z\n' \
		> "$TEST_TMP/consumer-repo/.claude/scripts/local.sh"
	git -C "$TEST_TMP/consumer-repo" add -A
	git -C "$TEST_TMP/consumer-repo" commit -qm "fix-pr-review-iter1: address review comment"

	local head_before
	head_before=$(git -C "$TEST_TMP/consumer-repo" rev-parse HEAD)

	_run_regen_hook "$TEST_TMP/consumer-repo" main || return 1
	[ "$status" -eq 0 ] || {
		printf 'FAIL: fix-stage hook failed in a consumer repo (exit %d):\n%s\n' \
			"$status" "$output" >&2
		return 1
	}

	[[ "$(git -C "$TEST_TMP/consumer-repo" rev-parse HEAD)" == "$head_before" ]] || {
		printf 'FAIL: fix-stage hook committed in a repo with no bundle generator\n' >&2
		return 1
	}
	[[ ! -e "$TEST_TMP/consumer-repo/plugins" ]] || {
		printf 'FAIL: fix-stage hook fabricated a plugins/ tree in a consumer repo\n' >&2
		return 1
	}
}
