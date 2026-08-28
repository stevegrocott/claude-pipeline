#!/usr/bin/env bats
#
# tests/skill-bundle-guidance.bats
# Guards the fold-bundle-regen rule added to explore and enrich-issue
# (issue #825): `./sync.sh bundle` must be folded into the last
# .claude/scripts-editing task, never authored as a standalone task, because
# a standalone bundle-regen task lands in the same parallel batch as the
# edits it must follow and runs in a worktree that can't see them.
#
# Guidance alone can regress silently, so this is a grep-level check, not a
# semantic one — it asserts the two skills keep carrying matching wording
# rather than judging whether the prose is well-written.
#
# Acceptance criteria (issue #825 task 3):
#   * AC4: fails if either skill loses the rule
#   * AC5: runs as part of `bats tests/*.bats` in the Decision Script BATS job
#

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
EXPLORE_SKILL="$REPO_ROOT/plugins/pipeline-core/skills/explore/SKILL.md"
ENRICH_SKILL="$REPO_ROOT/plugins/pipeline-core/skills/enrich-issue/SKILL.md"

# The rule statement: a non-table prose line mentioning sync.sh bundle and
# the standalone-task prohibition. Table rows (`| ... |`) are excluded so
# this targets the prose sentence, not the Red Flags row.
# Never lets a no-match propagate as a nonzero exit — bats runs with
# errexit, and grep returning 1 on no match would abort the test before its
# own diagnostic `if` check runs.
rule_line() {
	grep -v '^\s*|' "$1" | grep -i 'sync\.sh bundle' | grep -i 'standalone' || true
}

@test "explore SKILL.md exists" {
	[[ -f "$EXPLORE_SKILL" ]]
}

@test "enrich-issue SKILL.md exists" {
	[[ -f "$ENRICH_SKILL" ]]
}

@test "explore SKILL.md states sync.sh bundle must fold into the last script-editing task, never standalone" {
	local line
	line=$(rule_line "$EXPLORE_SKILL")

	if [[ -z "$line" ]]; then
		echo "explore/SKILL.md is missing the fold-bundle-regen rule (expected a line mentioning both 'sync.sh bundle' and 'standalone')"
		return 1
	fi

	echo "$line" | grep -qi 'last' || {
		echo "explore/SKILL.md rule line doesn't say the command belongs in the LAST script-editing task: $line"
		return 1
	}
}

@test "enrich-issue SKILL.md mirrors the same fold-bundle-regen rule wording as explore" {
	local explore_line enrich_line
	explore_line=$(rule_line "$EXPLORE_SKILL")
	enrich_line=$(rule_line "$ENRICH_SKILL")

	[[ -n "$explore_line" ]] || skip "explore/SKILL.md rule missing — covered by the preceding test"

	if [[ -z "$enrich_line" ]]; then
		echo "enrich-issue/SKILL.md is missing the fold-bundle-regen rule (expected a line mentioning both 'sync.sh bundle' and 'standalone')"
		return 1
	fi

	if [[ "$explore_line" != "$enrich_line" ]]; then
		echo "explore and enrich-issue rule wording has drifted:"
		echo "  explore:      $explore_line"
		echo "  enrich-issue: $enrich_line"
		return 1
	fi
}

@test "explore Red Flags table has a row for standalone bundle-regen naming worktree isolation" {
	local table row
	table=$(sed -n '/^## Red Flags/,/^## /p' "$EXPLORE_SKILL")

	if [[ -z "$table" ]]; then
		echo "explore/SKILL.md has no ## Red Flags section"
		return 1
	fi

	row=$(echo "$table" | grep '^\s*|' | grep -i 'bundle' || true)

	if [[ -z "$row" ]]; then
		echo "explore Red Flags table has no row mentioning bundle regeneration"
		return 1
	fi

	echo "$row" | grep -qi 'worktree isolation' || {
		echo "explore Red Flags bundle-regen row doesn't name worktree isolation as the failure reason: $row"
		return 1
	}
}
