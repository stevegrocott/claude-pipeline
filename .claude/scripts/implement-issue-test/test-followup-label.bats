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
#   4. PR review comment body: verdict, summary, findings, reviewer
#      comments (posted through a stubbed comment_pr)
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

# Resolved before setup: source_orchestrator_functions clobbers SCRIPT_DIR.
REVIEW_SCHEMA="$SCRIPT_DIR/schemas/implement-issue-review.json"

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

@test "process-pr SKILL.md documents a followups-only mode running only steps 4f and 4g" {
	[[ -f "$PROCESS_PR_SKILL" ]]
	local mode
	mode=$(awk '/^### Followups-only mode/{f=1;next} /^### |^## /{f=0} f' "$PROCESS_PR_SKILL")
	[[ -n "$mode" ]]
	grep -qF -- '--followups-only' "$PROCESS_PR_SKILL"
	grep -qE 'only Step 4f and Step 4g' <<<"$mode"
	grep -qE 'Skip .*Step 4a through 4e' <<<"$mode"
	grep -qE 'Step 5' <<<"$mode"
	grep -qE 'already merged' <<<"$mode"
}

@test "process-pr SKILL.md bash blocks have no leading assignment and no default expansion" {
	[[ -f "$PROCESS_PR_SKILL" ]]
	# The --allowedTools matcher refuses a command that starts with VAR=...
	# and any ${VAR:-x} default expansion, so no bash block may contain one.
	# No bash block at all means the scan below checked nothing.
	local blocks
	blocks=$(grep -c '^```bash[[:space:]]*$' "$PROCESS_PR_SKILL" || true)
	[ "$blocks" -gt 0 ]
	local offenders
	offenders=$(awk '
		/^```bash[[:space:]]*$/ { inb = 1; next }
		/^```/ { inb = 0; next }
		inb && (/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ || /\$\{[A-Za-z_][A-Za-z0-9_]*:?[-=+?]/) {
			printf "%d: %s\n", NR, $0
		}
	' "$PROCESS_PR_SKILL")
	if [[ -n "$offenders" ]]; then
		printf 'refused command shapes in bash blocks:\n%s\n' "$offenders" >&2
		return 1
	fi
}

# =============================================================================
# PR review comment body: verdict, summary, findings, reviewer comments
# =============================================================================

# Fails unless the review output ($1, the stage result) uses only the
# schema's field names and enum values.
_assert_review_schema() {
	jq -e --slurpfile s "$REVIEW_SCHEMA" '
		($s[0].properties) as $p
		| (.output | keys - ($p | keys)) == []
		and ($s[0].required - (.output | keys)) == []
		and ([.output.result] - $p.result.enum) == []
		and ([.output.issues // [] | .[].severity]
			- $p.issues.items.properties.severity.enum) == []
		and ([.output.issues // [] | .[] | keys[]]
			- ($p.issues.items.properties | keys)) == []
	' <<<"$1" >/dev/null
}

# Posts a review result the way the PR review stage does: the real
# _format_pr_review_comment output handed to comment_pr, here stubbed to
# record its arguments under $TEST_TMP/posted.
_post_review() {
	local review_result="$1"
	local verdict review_summary review_icon review_comment_body

	verdict=$(jq -r '.output.result' <<<"$review_result")
	review_summary=$(jq -r '.output.summary' <<<"$review_result")
	review_icon="✅"
	[[ "$verdict" == "changes_requested" ]] && review_icon="🔄"

	comment_pr() {
		mkdir -p "$TEST_TMP/posted"
		printf '%s' "$1" > "$TEST_TMP/posted/pr"
		printf '%s' "$2" > "$TEST_TMP/posted/title"
		printf '%s' "$3" > "$TEST_TMP/posted/body"
		printf '%s' "$4" > "$TEST_TMP/posted/agent"
	}

	review_comment_body=$(_format_pr_review_comment "$verdict" \
		"$review_result" "$review_summary" "$review_icon")
	comment_pr 7 "PR Review (Iteration 1)" "$review_comment_body" \
		"code-reviewer"
}

@test "review comment posts verdict, summary, every finding and the reviewer comments" {
	local review_result body
	review_result=$(jq -n '{output: {
		result: "changes_requested",
		summary: "Needs work",
		issues: [
			{severity: "major", file: "src/a.sh", line: 12,
				description: "Unquoted var"},
			{severity: "minor", file: "src/b.sh", line: 3,
				description: "Naming nit"}
		],
		comments: "Consider a helper for the retry loop."
	}}')
	_assert_review_schema "$review_result"

	_post_review "$review_result"

	body=$(< "$TEST_TMP/posted/body")
	[[ "$body" == "🔄 **Result:** changes_requested"$'\n\n''Needs work'* ]]
	[[ "$body" == *$'\n''- **major** `src/a.sh:12` — Unquoted var'$'\n'* ]]
	[[ "$body" == *$'\n''- **minor** `src/b.sh:3` — Naming nit'$'\n'* ]]
	[[ "$body" == *'Consider a helper for the retry loop.' ]]
	[ "$(< "$TEST_TMP/posted/title")" = "PR Review (Iteration 1)" ]
	[ "$(< "$TEST_TMP/posted/agent")" = "code-reviewer" ]
}

@test "review comment with no findings and no comments is verdict and summary only" {
	local review_result case_json
	printf '✅ **Result:** approved\n\nLGTM' > "$TEST_TMP/expected"

	for case_json in '{issues: [], comments: ""}' '{comments: " \n\t "}' '{}'; do
		review_result=$(jq -n "{output: ({result: \"approved\",
			summary: \"LGTM\"} + $case_json)}")
		_assert_review_schema "$review_result"
		rm -rf "$TEST_TMP/posted"

		_post_review "$review_result"

		run cmp "$TEST_TMP/expected" "$TEST_TMP/posted/body"
		[ "$status" -eq 0 ]
		run grep -cE 'Findings|Reviewer comments' "$TEST_TMP/posted/body"
		[ "$output" = "0" ]
	done
}

@test "review comment layout is summary, then findings, then reviewer comments" {
	local review_result
	review_result=$(jq -n '{output: {
		result: "approved",
		summary: "Overall fine",
		issues: [{severity: "minor", file: "a.sh", line: 1,
			description: "Bad"}],
		comments: "Nice tests."
	}}')
	_assert_review_schema "$review_result"

	_post_review "$review_result"

	printf '%s\n' '✅ **Result:** approved' '' 'Overall fine' '' \
		'### Findings' '' '- **minor** `a.sh:1` — Bad' '' \
		'### Reviewer comments' '' > "$TEST_TMP/expected"
	printf 'Nice tests.' >> "$TEST_TMP/expected"
	run cmp "$TEST_TMP/expected" "$TEST_TMP/posted/body"
	[ "$status" -eq 0 ]
}

@test "review comment posts backticks, command substitution and newlines as literal text" {
	local marker="$TEST_TMP/executed-marker"
	local desc comments review_result body
	desc="Run \`touch $marker\` or \$(touch $marker)"$'\n''second line'
	comments="Also \`touch $marker\` and \$(touch $marker)"$'\n''%s %d end'
	review_result=$(jq -n --arg d "$desc" --arg c "$comments" '{output: {
		result: "changes_requested",
		summary: "See findings",
		issues: [{severity: "major", file: "x.sh", line: 5,
			description: $d}],
		comments: $c
	}}')
	_assert_review_schema "$review_result"

	_post_review "$review_result"

	[ ! -e "$marker" ]
	body=$(< "$TEST_TMP/posted/body")
	[[ "$body" == *'- **major** `x.sh:5` — '"$desc"$'\n\n'* ]]
	[[ "$body" == *'### Reviewer comments'$'\n\n'"$comments" ]]
}
