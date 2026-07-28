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

# Subdirectories checked in addition to top-level *.sh. Kept in lockstep with
# BUNDLE_SCRIPT_SUBDIRS in sync.sh's bundle_scripts() — both lists must name
# the same directories or the generator and this guard silently diverge on
# scope again. platform/ is where PR #624's drift shipped, so it must stay
# covered here, not just at the top level.
PARITY_SUBDIRS=(platform prompts schemas)

# Print, one per line, every file under $1 that this guard is responsible
# for: top-level *.sh, plus every file (any extension) under each of
# PARITY_SUBDIRS, as a path relative to $1.
_parity_relpaths() {
	local root="$1"
	local script sub

	for script in "$root"/*.sh; do
		[[ -f "$script" ]] || continue
		printf '%s\n' "${script#"$root"/}"
	done

	for sub in "${PARITY_SUBDIRS[@]}"; do
		[[ -d "$root/$sub" ]] || continue
		while IFS= read -r script; do
			printf '%s\n' "${script#"$root"/}"
		done < <(find "$root/$sub" -type f | sort)
	done
}

@test "bundle parity: every canonical script matches its plugins/pipeline-core/scripts counterpart" {
	[[ -d "$BUNDLE_DIR" ]] || fail "bundle directory not found: $BUNDLE_DIR"

	local report="" rel canonical counterpart pair_diff
	while IFS= read -r rel; do
		canonical="$SCRIPT_DIR/$rel"
		counterpart="$BUNDLE_DIR/$rel"

		if [[ ! -f "$counterpart" ]]; then
			report+=$'\n'"MISSING: $rel has no counterpart in plugins/pipeline-core/scripts/"
			continue
		fi

		diff -q "$canonical" "$counterpart" >/dev/null 2>&1 && continue

		pair_diff="$(diff -u "$counterpart" "$canonical")" || true
		report+=$'\n'"DIFF: $rel"$'\n'"$pair_diff"
	done < <(_parity_relpaths "$SCRIPT_DIR")

	local msg="canonical/bundle drift detected — run ./sync.sh bundle to"
	msg+=" regenerate the bundle from canonical, then review and commit"
	msg+=" the result:$report"
	[[ -z "$report" ]] || fail "$msg"
}

@test "bundle parity: every bundled script has a canonical counterpart" {
	local rel
	while IFS= read -r rel; do
		[[ -f "$SCRIPT_DIR/$rel" ]] || \
			fail "bundled file $rel has no canonical counterpart in .claude/scripts/"
	done < <(_parity_relpaths "$BUNDLE_DIR")
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
