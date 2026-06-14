#!/usr/bin/env bats
#
# test-followup-label.bats
# Tests asserting that create-issue.sh is invoked with the needs-explore label
# when processing adjacent_issues entries from a code-reviewer PR result, and
# that the process-pr skill's precise follow-up path also carries needs-explore.
#
# The adjacent_issues path in implement-issue-orchestrator.sh creates GitHub
# follow-up issues for major-severity adjacent issues found during PR review.
# Each created issue must receive the "needs-explore" label so that the
# enrich-issue skill can later research and enrich the issue body.
#
# The process-pr skill's precise follow-up path (Step 4g) also applies the
# needs-explore label on create-issue.sh calls, ensuring every pipeline-created
# issue is eligible for enrichment regardless of follow-up classification.
#
# Cases covered:
#   1. Static: orchestrator source contains needs-explore on the
#      adjacent_issues / create-issue.sh call site
#   2. Static: needs-explore and pipeline-followup appear together on the
#      same --labels argument
#   3. Static: the create-issue.sh call with needs-explore is inside the
#      adjacent_issues block (not some other code path)
#   4. Static: process-pr SKILL.md precise follow-up --labels argument
#      includes needs-explore
#   4a. Static: process-pr SKILL.md classification table precise row specifies
#       NO needs-explore label (precise=no-label scenario — AC4)
#   5. Functional: stub create-issue.sh receives needs-explore when verdict
#      is approved and adjacent issue has major severity
#   6. Functional: pipeline-followup label also applied (both labels present)
#   7. Functional: create-issue.sh is NOT called when verdict ≠ approved
#   8. Functional: create-issue.sh is NOT called for minor-severity issues
#   9. Functional: create-issue.sh is NOT called when adjacent_issues is empty
#

load 'helpers/test-helper.bash'

ORCHESTRATOR_SRC="$SCRIPT_DIR/implement-issue-orchestrator.sh"
PROCESS_PR_SKILL="$SCRIPT_DIR/../skills/process-pr/SKILL.md"

setup() {
	setup_test_env

	export ISSUE_NUMBER=42
	export BASE_BRANCH=main
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	export STAGE_COUNTER=0
	mkdir -p "$LOG_BASE"

	source_orchestrator_functions

	# Override PLATFORM_DIR to point at a test-controlled stub directory so
	# we can intercept create-issue.sh invocations.
	local stub_platform
	stub_platform="$TEST_TMP/stub-platform"
	mkdir -p "$stub_platform"
	PLATFORM_DIR="$stub_platform"

	# Each invocation of the stub appends every argument on its own line.
	# Tests inspect CREATE_ISSUE_CALLS_FILE after calling _run_adj_followup_loop.
	export CREATE_ISSUE_CALLS_FILE="$TEST_TMP/create-issue-calls.log"

	# Stub create-issue.sh: record args per-line, echo a fake issue number.
	cat > "$stub_platform/create-issue.sh" << 'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
	printf '%s\n' "$arg" >> "${CREATE_ISSUE_CALLS_FILE:-/dev/null}"
done
printf '101\n'
STUB
	chmod +x "$stub_platform/create-issue.sh"

	# Stub gh so the deduplication check returns an empty issue list.
	local stub_bin
	stub_bin="$TEST_TMP/stub-bin"
	mkdir -p "$stub_bin"
	cat > "$stub_bin/gh" << 'STUB'
#!/usr/bin/env bash
# Minimal gh stub: return an empty JSON array for any issue list call.
printf '[]\n'
STUB
	chmod +x "$stub_bin/gh"
	export PATH="$stub_bin:$PATH"
}

teardown() {
	teardown_test_env
}

# ---------------------------------------------------------------------------
# _run_adj_followup_loop
#
# Simulation of the adjacent_issues follow-up creation block from
# implement-issue-orchestrator.sh main() (approx. lines 7337-7391).
#
# Replicates the logic here so we can exercise it with stubs without
# running the full orchestrator, following the _simulate_state_routing
# pattern used in test-batch-orchestrator.bats.
#
# Arguments:
#   $1  review_verdict  ("approved" or other)
#   $2  review_result   JSON string with optional .adjacent_issues array
# ---------------------------------------------------------------------------
_run_adj_followup_loop() {
	local review_verdict="$1"
	local review_result="$2"

	if [[ "$review_verdict" != "approved" ]]; then
		return 0
	fi

	local adjacent_json adj_count
	adjacent_json=$(printf '%s' "$review_result" | \
		jq -c '[.adjacent_issues // [] | .[] | select(.severity == "major")]' \
		2>/dev/null || printf '[]')
	adj_count=$(printf '%s' "$adjacent_json" | \
		jq 'length' 2>/dev/null || printf '0')

	if (( adj_count == 0 )); then
		return 0
	fi

	while IFS= read -r adj_item; do
		local adj_title adj_body
		adj_title=$(printf '%s' "$adj_item" | jq -r '.title // ""')
		adj_body=$(printf '%s' "$adj_item" | jq -r '.body // ""')
		[[ -z "$adj_title" ]] && continue

		local dup_count
		dup_count=$(gh issue list --state open --json title 2>/dev/null | \
			jq --arg t "$adj_title" \
			'[.[] | select(.title == $t)] | length' \
			2>/dev/null || printf '0')
		if (( dup_count > 0 )); then
			continue
		fi

		local validated_body
		validated_body=$(_build_adj_body "$adj_body" "$adj_title")
		validated_body="<!-- pipeline-autocreated -->
${validated_body}"

		"$PLATFORM_DIR/create-issue.sh" \
			--title "$adj_title" \
			--body "$validated_body" \
			--labels "pipeline-followup,needs-explore" \
			2>/dev/null || true
	done < <(printf '%s' "$adjacent_json" | jq -c '.[]' 2>/dev/null)
}

# =============================================================================
# STATIC ANALYSIS: orchestrator source code contains needs-explore label
# on the adjacent_issues / create-issue.sh call site
# =============================================================================

@test "orchestrator source contains needs-explore label" {
	grep -q 'needs-explore' "$ORCHESTRATOR_SRC"
}

@test "needs-explore and pipeline-followup appear on the same --labels argument" {
	grep -q 'pipeline-followup,needs-explore' "$ORCHESTRATOR_SRC"
}

@test "create-issue.sh call with needs-explore is inside the adjacent_issues block" {
	# Extract the adjacent_issues processing block and assert both
	# create-issue.sh and needs-explore appear within it.
	local block
	block=$(awk '/adjacent_issues.*major/,/followup_comment/' \
		"$ORCHESTRATOR_SRC" 2>/dev/null)
	[[ "$block" == *"needs-explore"* ]]
	[[ "$block" == *"create-issue.sh"* ]]
}

@test "process-pr SKILL.md precise follow-up --labels argument includes needs-explore" {
	# Extract the precise follow-up section and assert needs-explore is present.
	local block
	block=$(awk '/Precise follow-up/,/Vague follow-up/' "$PROCESS_PR_SKILL" 2>/dev/null)
	[[ "$block" == *"needs-explore"* ]]
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
# FUNCTIONAL: approved verdict + major adjacent issue → needs-explore applied
# =============================================================================

@test "approved + major adjacent issue: create-issue.sh receives needs-explore" {
	local review_result
	review_result=$(jq -n '{
		adjacent_issues: [
			{
				title: "Fix memory leak in connection pool",
				body: "## Implementation Tasks\n\n- `[default]` **(M)** Fix the leak",
				severity: "major"
			}
		]
	}')

	_run_adj_followup_loop "approved" "$review_result"

	[[ -f "$CREATE_ISSUE_CALLS_FILE" ]]
	grep -q 'needs-explore' "$CREATE_ISSUE_CALLS_FILE"
}

@test "approved + major adjacent issue: pipeline-followup label also applied" {
	local review_result
	review_result=$(jq -n '{
		adjacent_issues: [
			{
				title: "Add input validation layer",
				body: "",
				severity: "major"
			}
		]
	}')

	_run_adj_followup_loop "approved" "$review_result"

	[[ -f "$CREATE_ISSUE_CALLS_FILE" ]]
	grep -q 'pipeline-followup' "$CREATE_ISSUE_CALLS_FILE"
}

@test "approved + major adjacent issue: both labels on single --labels arg" {
	local review_result
	review_result=$(jq -n '{
		adjacent_issues: [
			{
				title: "Refactor auth token handling",
				body: "",
				severity: "major"
			}
		]
	}')

	_run_adj_followup_loop "approved" "$review_result"

	grep -q 'pipeline-followup,needs-explore' "$CREATE_ISSUE_CALLS_FILE"
}

# =============================================================================
# FUNCTIONAL: non-approved verdict → create-issue.sh is NOT called
# =============================================================================

@test "changes_requested verdict: create-issue.sh is NOT called" {
	local review_result
	review_result=$(jq -n '{
		adjacent_issues: [
			{
				title: "Fix something important",
				body: "",
				severity: "major"
			}
		]
	}')

	_run_adj_followup_loop "changes_requested" "$review_result"

	[[ ! -f "$CREATE_ISSUE_CALLS_FILE" ]]
}

# =============================================================================
# FUNCTIONAL: minor-severity adjacent issue → create-issue.sh is NOT called
# =============================================================================

@test "minor-severity adjacent issue: create-issue.sh is NOT called" {
	local review_result
	review_result=$(jq -n '{
		adjacent_issues: [
			{
				title: "Style tweak in sidebar",
				body: "",
				severity: "minor"
			}
		]
	}')

	_run_adj_followup_loop "approved" "$review_result"

	[[ ! -f "$CREATE_ISSUE_CALLS_FILE" ]]
}

# =============================================================================
# FUNCTIONAL: empty adjacent_issues → create-issue.sh is NOT called
# =============================================================================

@test "empty adjacent_issues array: create-issue.sh is NOT called" {
	_run_adj_followup_loop "approved" '{"adjacent_issues": []}'

	[[ ! -f "$CREATE_ISSUE_CALLS_FILE" ]]
}
