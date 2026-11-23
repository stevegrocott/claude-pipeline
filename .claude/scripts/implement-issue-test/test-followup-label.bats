#!/usr/bin/env bats
#
# test-followup-label.bats
# Tests for the process-pr skill's follow-up labelling (precise follow-ups
# carry no needs-explore label) and the PR review comment body.
#
# Cases covered:
#   1. Static: process-pr SKILL.md precise follow-up --labels argument
#      does NOT include needs-explore
#   2. Static: process-pr SKILL.md classification table: precise row
#      specifies no needs-explore label (AC4)
#   3. Static: process-pr SKILL.md Step 4g wrapper contract
#   4. PR review comment body formatting
#
# The orchestrator's former adjacent_issues block was unreachable (the
# reviewer never emits adjacent_issues) and was removed along with the
# tests that fed it hand-built data.
#

load 'helpers/test-helper.bash'

# Prefer the post-git-mv plugin layout (plugins/pipeline-core/skills/) and fall
# back to the legacy .claude/skills/ layout so this works on both sides of the
# restructure.
PROCESS_PR_SKILL="$SCRIPT_DIR/../../plugins/pipeline-core/skills/process-pr/SKILL.md"
[[ -f "$PROCESS_PR_SKILL" ]] || PROCESS_PR_SKILL="$SCRIPT_DIR/../skills/process-pr/SKILL.md"

setup() {
	setup_test_env

	export ISSUE_NUMBER=42
	export BASE_BRANCH=main
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	export STAGE_COUNTER=0
	mkdir -p "$LOG_BASE"

	source_orchestrator_functions
}

teardown() {
	teardown_test_env
}

@test "process-pr SKILL.md precise follow-up --labels argument does NOT include needs-explore" {
	# Precise follow-ups must NOT carry needs-explore — precise issues already
	# have full context, so adding needs-explore would trigger a wasteful
	# enrich-issue call that overwrites the precise body with exploratory prose.
	# Scope the check to the --labels argument line only; the heading may
	# reference "needs-explore" in negation context.
	local block labels_line
	block=$(awk '/Precise follow-up/,/Vague follow-up/' "$PROCESS_PR_SKILL" 2>/dev/null)
	labels_line=$(printf '%s\n' "$block" | grep -- '--labels' | head -1)
	[[ "$labels_line" != *"needs-explore"* ]]
}

@test "process-pr SKILL.md classification table: precise row specifies no needs-explore label" {
	# AC4 (precise=no-label scenario): the classification table must document that
	# precise follow-ups (specific file+function reference, ≤2 files in scope) do
	# NOT receive the needs-explore label.  Precise issues already carry full
	# context; adding needs-explore would trigger a wasteful /enrich-issue call
	# that overwrites the precise body with exploratory prose.
	local precise_row
	precise_row=$(grep '\*\*precise\*\*' "$PROCESS_PR_SKILL" | head -1)
	[[ "$precise_row" == *"no \`needs-explore\` label"* ]]
}

# =============================================================================
# process-pr SKILL.md Step 4g wrapper contract
# =============================================================================

@test "process-pr SKILL.md resolves platform dir with one bare command and literal paths after" {
	[[ -f "$PROCESS_PR_SKILL" ]]
	# The bare command appears on its own line
	grep -qx 'pipeline-core-platform-dir' "$PROCESS_PR_SKILL"
	# No denied VAR="$(...)" form or $PLATFORM_DIR expansion remains
	run grep -nE 'PLATFORM_DIR="\$\(|"\$PLATFORM_DIR' "$PROCESS_PR_SKILL"
	[ "$status" -eq 1 ]
	# Later commands use the literal placeholder
	grep -q '"<PLATFORM_DIR>/comment-issue.sh"' "$PROCESS_PR_SKILL"
}

@test "process-pr SKILL.md Step 4g calls the platform create-followup-issue.sh wrapper bare" {
	[[ -f "$PROCESS_PR_SKILL" ]]
	grep -q '^"<PLATFORM_DIR>/create-followup-issue.sh" \\$' "$PROCESS_PR_SKILL"
	# The denied dual-mode resolution form is gone
	run grep -nE 'CREATE_FOLLOWUP=|command -v pipeline-core-create-followup-issue' "$PROCESS_PR_SKILL"
	[ "$status" -eq 1 ]
	# The skill tells the model to record the printed number
	grep -q 'prints the created issue number' "$PROCESS_PR_SKILL"
}

@test "process-pr SKILL.md Step 4g states exit 1 meaning and that printed numbers fill follow_up_issues" {
	[[ -f "$PROCESS_PR_SKILL" ]]
	local step
	step=$(awk '/^### Step 4g/{f=1;next} /^### |^## /{f=0} f' "$PROCESS_PR_SKILL")
	grep -qE 'Exit code 1 means .*failed `assert_issue_valid`' <<<"$step"
	grep -qE 'duplicate' <<<"$step"
	grep -qE 'not a failure' <<<"$step"
	grep -qE 'nothing was created' <<<"$step"
	grep -qE 'numbers .*fill the `follow_up_issues`' <<<"$step"
}

@test "process-pr SKILL.md Step 4g forbids a hash-leading line in a quoted argument and shows the quoted heredoc form" {
	[[ -f "$PROCESS_PR_SKILL" ]]
	local step
	step=$(awk '/^### Step 4g/{f=1;next} /^### |^## /{f=0} f' "$PROCESS_PR_SKILL")
	grep -qE 'Never put a line starting with `#` inside a quoted argument' <<<"$step"
	grep -qF "cat <<'EOF'" <<<"$step"
}

# =============================================================================
# PR review comment body: findings then reviewer comments
# =============================================================================

@test "review comment lists every finding with severity, file:line and description" {
	local review_result body
	review_result=$(jq -n '{output: {issues: [
		{severity: "major", file: "src/a.sh", line: 12, description: "Unquoted var"},
		{severity: "minor", file: "src/b.sh", description: "Naming nit"}
	]}}')

	body=$(_format_pr_review_comment "changes_requested" "$review_result" \
		"Needs work" "R")

	[[ "$body" == *'**major** `src/a.sh:12` — Unquoted var'* ]]
	[[ "$body" == *'**minor** `src/b.sh` — Naming nit'* ]]
}

@test "review comment puts findings before the reviewer comments" {
	local review_result body
	review_result=$(jq -n '{output: {issues: [
		{severity: "major", file: "a.sh", line: 1, description: "Bad"}
	]}}')

	body=$(_format_pr_review_comment "approved" "$review_result" \
		"Overall fine" "OK")

	[[ "$body" == "OK **Result:** approved"* ]]
	local before_findings="${body%%### Findings*}"
	local before_comments="${body%%### Reviewer comments*}"
	(( ${#before_findings} < ${#before_comments} ))
	[[ "$body" == *'### Reviewer comments'$'\n\n''Overall fine' ]]
}

@test "review comment omits findings section when there are none" {
	local body
	body=$(_format_pr_review_comment "approved" '{"output":{}}' "LGTM" "OK")

	[[ "$body" != *"### Findings"* ]]
	[[ "$body" == *"LGTM" ]]
}
