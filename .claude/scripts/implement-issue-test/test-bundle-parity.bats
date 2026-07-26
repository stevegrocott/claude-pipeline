#!/usr/bin/env bats
#
# test-bundle-parity.bats
# Bundle parity guard (issue #623) — the repo maintains two hand-edited
# copies of every pipeline script: .claude/scripts/ (what this repo's own
# pipeline runs) and plugins/pipeline-core/scripts/ (what consumers install
# via the plugin bundle). Nothing enforced agreement between them: v0.3.0
# was tagged and installed with a bundled orchestrator that did not contain
# the turn-budget fix from #619, because the fix had landed only in
# .claude/scripts/. This test diffs every *.sh pair by basename and reports
# drift instead of letting it ship silently.

bats_require_minimum_version 1.5.0

load 'helpers/test-helper.bash'

# SCRIPT_DIR (set by test-helper.bash) is .claude/scripts — the canonical
# tree. Repo root is two levels up (.claude/scripts -> .claude -> repo root).
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUNDLE_DIR="$REPO_ROOT/plugins/pipeline-core/scripts"

@test "bundle parity: every .claude/scripts/*.sh matches its plugins/pipeline-core/scripts counterpart" {
	[[ -d "$BUNDLE_DIR" ]] || fail "bundle directory not found: $BUNDLE_DIR"

	local report="" script base counterpart pair_diff
	for script in "$SCRIPT_DIR"/*.sh; do
		base=$(basename "$script")
		counterpart="$BUNDLE_DIR/$base"

		if [[ ! -f "$counterpart" ]]; then
			report+=$'\n'"MISSING: $base has no counterpart in plugins/pipeline-core/scripts/"
			continue
		fi

		diff -q "$script" "$counterpart" >/dev/null 2>&1 && continue

		pair_diff="$(diff -u "$counterpart" "$script")" || true
		report+=$'\n'"DIFF: $base"$'\n'"$pair_diff"
	done

	[[ -z "$report" ]] || fail "canonical/bundle drift detected — port the missing side by hand:$report"
}

@test "bundle parity: every plugins/pipeline-core/scripts/*.sh has a canonical counterpart" {
	local script base
	for script in "$BUNDLE_DIR"/*.sh; do
		base=$(basename "$script")
		[[ -f "$SCRIPT_DIR/$base" ]] || fail "bundled script $base has no canonical counterpart in .claude/scripts/"
	done
}

# =============================================================================
# Syntax guard (AC3) — a diff test only catches drift from the canonical
# tree; it says nothing about whether the shipped bundle actually parses.
# Run `bash -n` over every bundled script so a syntax error in
# plugins/pipeline-core/scripts/ fails CI instead of shipping in a tag.
# =============================================================================

@test "bundle syntax: every plugins/pipeline-core/scripts/**/*.sh passes bash -n" {
	local report="" script syntax_error

	while IFS= read -r script; do
		syntax_error="$(bash -n "$script" 2>&1)" && continue
		report+=$'\n'"SYNTAX ERROR: ${script#"$REPO_ROOT"/}"$'\n'"$syntax_error"
	done < <(find "$BUNDLE_DIR" -name '*.sh' -type f | sort)

	[[ -z "$report" ]] || fail "bash -n failed on the bundled tree:$report"
}
