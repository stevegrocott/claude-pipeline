#!/usr/bin/env bats
#
# test-issue-staleness-guard.bats
# Issue #846 — the pipeline machine-parses an issue's BODY and nothing else.
# When a re-scope or correction is written as a COMMENT and never applied to
# the body, the run proceeds against a stale contract and nothing warns.
#
# Two halves are covered here, both sourced from the SHIPPED bundle under
# plugins/pipeline-core/scripts/ (AC6) rather than the canonical tree, so a
# bundle regenerated from pre-fix sources fails these tests instead of
# passing green over broken code:
#
#   1. platform/read-issue.sh          — classifies each comment as pipeline
#                                        or human and surfaces the body's own
#                                        edit timestamp (AC1/AC2/AC4/AC5)
#   2. warn_if_issue_body_stale()      — the parse-issue warn/fail-closed
#      (implement-issue-orchestrator)    decision (AC1/AC3/AC4)
#

bats_require_minimum_version 1.5.0

load 'helpers/test-helper.bash'

# SCRIPT_DIR (from test-helper.bash) is .claude/scripts; the repo root is two
# levels up. Every path below deliberately reaches into the BUNDLE, not the
# canonical tree (AC6).
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUNDLE_SCRIPTS="$REPO_ROOT/plugins/pipeline-core/scripts"
BUNDLED_READ_ISSUE="$BUNDLE_SCRIPTS/platform/read-issue.sh"
BUNDLED_ORCHESTRATOR="$BUNDLE_SCRIPTS/implement-issue-orchestrator.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# read-issue.sh resolves platform.sh through resolve_consumer_file, whose
	# first lookup is $PIPELINE_CONFIG_DIR. Pin it at a fixture so resolution
	# never falls through to this repo's own .claude/config/platform.sh.
	mkdir -p "$TEST_TMP/config" "$TEST_TMP/bin"
	cat > "$TEST_TMP/config/platform.sh" <<-'PLATFORM_EOF'
		#!/bin/bash
		TRACKER="${TRACKER:-github}"
		TRACKER_CLI="${TRACKER_CLI:-gh}"
	PLATFORM_EOF
	export PIPELINE_CONFIG_DIR="$TEST_TMP/config"
	export TRACKER="github"

	install_gh_mock
	export PATH="$TEST_TMP/bin:$PATH"

	cd "$TEST_TMP" || exit 1
}

teardown() {
	if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# -----------------------------------------------------------------------------
# gh mock
#
# Logs every invocation (so the one-fetch assertion of AC4 can count them) and
# answers the two shapes read-issue.sh can issue: the GraphQL staleness fetch
# and the legacy `gh issue view` fallback.
# -----------------------------------------------------------------------------
install_gh_mock() {
	cat > "$TEST_TMP/bin/gh" <<-'GH_EOF'
		#!/usr/bin/env bash
		# Newlines are squashed so the log stays one line per invocation —
		# the GraphQL query is a multi-line -f argument, and counting raw
		# lines would report a single call as nineteen.
		printf 'gh %s\n' "${*//$'\n'/ }" >> "$TEST_TMP/gh_calls.log"

		if [[ "$1" == "api" && "$2" == "graphql" ]]; then
			printf '%s' "${MOCK_GRAPHQL_JSON:-}"
			exit "${MOCK_GRAPHQL_EXIT_CODE:-0}"
		fi

		if [[ "$1" == "issue" && "$2" == "view" ]]; then
			printf '%s' "${MOCK_GH_ISSUE_JSON:-}"
			exit "${MOCK_GH_EXIT_CODE:-0}"
		fi

		exit 0
	GH_EOF
	chmod +x "$TEST_TMP/bin/gh"
	: > "$TEST_TMP/gh_calls.log"
}

# Build a GraphQL response envelope.
#   $1 - lastEditedAt (use the literal "null" for a never-edited body)
#   $2 - createdAt
#   $3.. - comment triples: createdAt, author login, body
_graphql_response() {
	local last_edited="$1" created="$2"
	shift 2

	local nodes="[]"
	nodes=$(jq -n '[]')
	while (( $# >= 3 )); do
		nodes=$(jq --argjson nodes "$nodes" \
			--arg at "$1" --arg who "$2" --arg body "$3" \
			-n '$nodes + [{
				createdAt: $at,
				url: ("https://github.com/o/r/issues/846#issuecomment-" + $at),
				body: $body,
				author: { login: $who }
			}]')
		shift 3
	done

	jq -n --argjson nodes "$nodes" \
		--arg created "$created" --argjson lastEdited "$last_edited" \
		'{ data: { repository: { issue: {
			title: "Some issue",
			body: "## Implementation Tasks\n- [ ] `[default]` do the thing",
			state: "OPEN",
			createdAt: $created,
			lastEditedAt: $lastEdited,
			comments: { nodes: $nodes }
		} } } }'
}

# Run the BUNDLED read-issue.sh against the mocked gh.
_run_read_issue() {
	run bash "$BUNDLED_READ_ISSUE" "${1:-846}"
}

# Source warn_if_issue_body_stale() out of the BUNDLED orchestrator with
# stand-ins for the collaborators it logs through, so the decision can be
# exercised without the rest of the script.
source_stale_guard() {
	local fn_file="$TEST_TMP/warn_if_issue_body_stale.bash"
	_extract_function_body warn_if_issue_body_stale "$BUNDLED_ORCHESTRATOR" \
		> "$fn_file"

	grep -q 'warn_if_issue_body_stale' "$fn_file" || \
		fail "warn_if_issue_body_stale() not found in the bundled orchestrator"

	ISSUE_NUMBER="846"
	WARN_LOG="$TEST_TMP/warn.log"
	ERROR_LOG="$TEST_TMP/error.log"
	: > "$WARN_LOG"
	: > "$ERROR_LOG"

	log_warn() { printf '%s\n' "$*" >> "$WARN_LOG"; }
	log_error() { printf '%s\n' "$*" >> "$ERROR_LOG"; }
	log() { :; }

	# shellcheck disable=SC1090
	source "$fn_file"
}

# The read-issue.sh payload shape the orchestrator consumes.
_payload() {
	jq -n --arg body_at "$1" --arg comment_at "${2:-}" \
		--arg who "${3:-}" --arg url "${4:-}" \
		'{
			title: "Some issue",
			body: "## Implementation Tasks\n- [ ] `[default]` do the thing",
			status: "OPEN",
			bodyUpdatedAt: $body_at,
			latestHumanCommentAt: (if $comment_at == "" then null
				else $comment_at end),
			latestHumanCommentAuthor: (if $who == "" then null else $who end),
			latestHumanCommentUrl: (if $url == "" then null else $url end)
		}'
}

# =============================================================================
# read-issue.sh — COMMENT CLASSIFICATION (AC1, AC2)
# =============================================================================

@test "read-issue: a human comment newer than the body edit is surfaced (AC1)" {
	export MOCK_GRAPHQL_JSON
	MOCK_GRAPHQL_JSON=$(_graphql_response '"2026-08-20T10:00:00Z"' \
		"2026-08-01T09:00:00Z" \
		"2026-08-19T08:00:00Z" "stevegrocott" \
			$'## Starting Automated Processing\n###### *Posted by `implement-issue-orchestrator`*\n\nProcessing.' \
		"2026-08-25T11:30:00Z" "stevegrocott" \
			$'Re-scoping this: tasks 2 and 3 already landed in #812, drop them.')

	_run_read_issue
	[ "$status" -eq 0 ]

	expect_glob "$(jq -r '.bodyUpdatedAt' <<< "$output")" \
		'2026-08-20T10:00:00Z' "bodyUpdatedAt reports the body's own edit time"
	expect_glob "$(jq -r '.latestHumanCommentAt' <<< "$output")" \
		'2026-08-25T11:30:00Z' "the human comment's timestamp is surfaced"
	expect_glob "$(jq -r '.latestHumanCommentAuthor' <<< "$output")" \
		'stevegrocott' "the human comment's author is surfaced"
	expect_glob "$(jq -r '.latestHumanCommentUrl' <<< "$output")" \
		'https://github.com/*' "the human comment's url is surfaced"
}

@test "read-issue: comments carrying the pipeline attribution line are filtered (AC2)" {
	export MOCK_GRAPHQL_JSON
	MOCK_GRAPHQL_JSON=$(_graphql_response '"2026-08-01T09:00:00Z"' \
		"2026-08-01T09:00:00Z" \
		"2026-08-02T10:00:00Z" "stevegrocott" \
			$'## Test Loop: Results (1/2)\n###### *Written by `default`*\n\nAll green.' \
		"2026-08-03T10:00:00Z" "stevegrocott" \
			$'## Merge: Blocked (Partial Delivery)\n###### *Posted by `implement-issue-orchestrator`*\n\n1/3 delivered.' \
		"2026-08-04T10:00:00Z" "stevegrocott" \
			$'## Deploy Verify\n###### *Written by `default`*\n\nDeployed.')

	_run_read_issue
	[ "$status" -eq 0 ]

	expect_glob "$(jq -r '.latestHumanCommentAt' <<< "$output")" 'null' \
		"pipeline comments must not register as human discussion"
}

@test "read-issue: pipeline stage headings are filtered even without an attribution line (AC2)" {
	# `## Completed` is posted by the process-pr skill, which writes the
	# heading but not the `###### *Posted by ...*` attribution line — so the
	# heading list is the only thing that can classify it.
	export MOCK_GRAPHQL_JSON
	MOCK_GRAPHQL_JSON=$(_graphql_response '"2026-08-01T09:00:00Z"' \
		"2026-08-01T09:00:00Z" \
		"2026-08-05T10:00:00Z" "stevegrocott" \
			$'## Completed\n\nResolved via PR #844 (merged).\n\n### Follow-up issues created:\nNo follow-up issues needed.')

	_run_read_issue
	[ "$status" -eq 0 ]

	expect_glob "$(jq -r '.latestHumanCommentAt' <<< "$output")" 'null' \
		"a headed pipeline comment with no attribution must still be filtered"
}

@test "read-issue: a heading quoted mid-comment does not make a human comment look generated (AC2)" {
	export MOCK_GRAPHQL_JSON
	MOCK_GRAPHQL_JSON=$(_graphql_response '"2026-08-01T09:00:00Z"' \
		"2026-08-01T09:00:00Z" \
		"2026-08-06T10:00:00Z" "stevegrocott" \
			'The bot said ## Test Loop: Results but the baseline has drifted 2x.')

	_run_read_issue
	[ "$status" -eq 0 ]

	expect_glob "$(jq -r '.latestHumanCommentAt' <<< "$output")" \
		'2026-08-06T10:00:00Z' \
		"only a heading at the start of a line marks a pipeline comment"
}

@test "read-issue: the newest human comment wins when pipeline comments follow it (AC1)" {
	export MOCK_GRAPHQL_JSON
	MOCK_GRAPHQL_JSON=$(_graphql_response 'null' "2026-08-01T09:00:00Z" \
		"2026-08-10T10:00:00Z" "stevegrocott" 'First human finding.' \
		"2026-08-12T10:00:00Z" "stevegrocott" 'Second human finding.' \
		"2026-08-14T10:00:00Z" "stevegrocott" \
			$'## Merge: Complete\n###### *Posted by `implement-issue-orchestrator`*\n\nMerged.')

	_run_read_issue
	[ "$status" -eq 0 ]

	expect_glob "$(jq -r '.latestHumanCommentAt' <<< "$output")" \
		'2026-08-12T10:00:00Z' \
		"a later pipeline comment must not mask an earlier human one"
}

# =============================================================================
# read-issue.sh — BODY TIMESTAMP AND COST (AC4, AC5)
# =============================================================================

@test "read-issue: a never-edited body falls back to createdAt (AC4)" {
	export MOCK_GRAPHQL_JSON
	MOCK_GRAPHQL_JSON=$(_graphql_response 'null' "2026-08-01T09:00:00Z")

	_run_read_issue
	[ "$status" -eq 0 ]

	expect_glob "$(jq -r '.bodyUpdatedAt' <<< "$output")" \
		'2026-08-01T09:00:00Z' \
		"lastEditedAt is null until the body is edited, so createdAt stands in"
}

@test "read-issue: the staleness fields cost exactly one tracker fetch (AC4)" {
	export MOCK_GRAPHQL_JSON
	MOCK_GRAPHQL_JSON=$(_graphql_response '"2026-08-20T10:00:00Z"' \
		"2026-08-01T09:00:00Z" \
		"2026-08-05T10:00:00Z" "stevegrocott" 'A human note.')

	_run_read_issue
	[ "$status" -eq 0 ]

	local calls
	calls=$(wc -l < "$TEST_TMP/gh_calls.log" | tr -d ' ')
	expect_glob "$calls" '1' \
		"body and comment timestamps must come from a single fetch"
}

@test "read-issue: the payload carries no comment body text (AC5)" {
	export MOCK_GRAPHQL_JSON
	MOCK_GRAPHQL_JSON=$(_graphql_response '"2026-08-01T09:00:00Z"' \
		"2026-08-01T09:00:00Z" \
		"2026-08-05T10:00:00Z" "stevegrocott" \
			'DROP TASK 3 and add a new acceptance criterion AC9.')

	_run_read_issue
	[ "$status" -eq 0 ]

	[[ "$output" != *"DROP TASK 3"* ]] || \
		fail "comment prose leaked into the parsed payload — comments must stay non-authoritative"
	[[ "$output" != *"AC9"* ]] || \
		fail "comment prose leaked into the parsed payload — comments must stay non-authoritative"

	# The body the pipeline parses must be exactly what the tracker returned.
	expect_glob "$(jq -r '.body' <<< "$output")" '## Implementation Tasks*' \
		"the parsed body is the issue body, untouched by comment content"
}

@test "read-issue: still returns title/body/status when the staleness fetch fails" {
	export MOCK_GRAPHQL_JSON=""
	export MOCK_GRAPHQL_EXIT_CODE=1
	export MOCK_GH_ISSUE_JSON='{"title":"My Issue","body":"Description here","state":"OPEN"}'

	_run_read_issue
	[ "$status" -eq 0 ]

	expect_glob "$(jq -r '.title' <<< "$output")" 'My Issue' \
		"the legacy fetch still satisfies existing callers"
	expect_glob "$(jq -r '.body' <<< "$output")" 'Description here' \
		"the legacy fetch still satisfies existing callers"
	expect_glob "$(jq -r '.status' <<< "$output")" 'OPEN' \
		"the legacy fetch still satisfies existing callers"
}

# =============================================================================
# warn_if_issue_body_stale() — WARN PATH (AC1)
# =============================================================================

@test "stale guard: warns and names the newer comment (AC1)" {
	source_stale_guard

	run warn_if_issue_body_stale \
		"$(_payload "2026-08-20T10:00:00Z" "2026-08-25T11:30:00Z" \
			"stevegrocott" "https://github.com/o/r/issues/846#issuecomment-9")"
	[ "$status" -eq 0 ]

	local warned
	warned=$(cat "$WARN_LOG")
	expect_glob "$warned" '*2026-08-25T11:30:00Z*' \
		"the warning names the newer comment's timestamp"
	expect_glob "$warned" '*stevegrocott*' \
		"the warning names the comment's author"
	expect_glob "$warned" '*issuecomment-9*' \
		"the warning links the comment"
	expect_glob "$warned" '*2026-08-20T10:00:00Z*' \
		"the warning names the body edit it is being compared against"
}

@test "stale guard: silent when the body is newer than every comment (AC4)" {
	source_stale_guard

	run warn_if_issue_body_stale \
		"$(_payload "2026-08-26T09:00:00Z" "2026-08-25T11:30:00Z" \
			"stevegrocott" "https://example.invalid/c/1")"
	[ "$status" -eq 0 ]

	expect_glob "$(cat "$WARN_LOG")" '' \
		"a body newer than every comment must produce no warning"
}

@test "stale guard: silent when every comment was pipeline-generated (AC2)" {
	source_stale_guard

	# read-issue.sh filtered them all out, so no human timestamp is reported.
	run warn_if_issue_body_stale "$(_payload "2026-08-01T09:00:00Z")"
	[ "$status" -eq 0 ]

	expect_glob "$(cat "$WARN_LOG")" '' \
		"pipeline comments must never trigger the warning"
}

@test "stale guard: silent when the tracker reports no timestamps at all" {
	source_stale_guard

	# The jira path (and any pre-#846 payload) carries neither field.
	run warn_if_issue_body_stale \
		'{"title":"t","body":"b","status":"OPEN"}'
	[ "$status" -eq 0 ]

	expect_glob "$(cat "$WARN_LOG")" '' \
		"a payload without timestamps is not evidence of staleness"
}

@test "stale guard: tolerates a malformed payload without erroring" {
	source_stale_guard

	run warn_if_issue_body_stale "not json at all"
	[ "$status" -eq 0 ]

	expect_glob "$(cat "$WARN_LOG")" '' \
		"an unparseable payload must not fabricate a staleness warning"
}

# =============================================================================
# warn_if_issue_body_stale() — FAIL-CLOSED FLAG (AC3)
# =============================================================================

@test "stale guard: non-fatal by default (AC3)" {
	source_stale_guard
	unset FAIL_ON_STALE_ISSUE_BODY

	run warn_if_issue_body_stale \
		"$(_payload "2026-08-20T10:00:00Z" "2026-08-25T11:30:00Z" \
			"stevegrocott" "https://example.invalid/c/1")"
	expect_glob "$status" '0' \
		"an unset flag must leave the run going"
	expect_glob "$(cat "$ERROR_LOG")" '' \
		"the default path logs a warning, not an error"
}

@test "stale guard: FAIL_ON_STALE_ISSUE_BODY=1 fails closed (AC3)" {
	source_stale_guard
	export FAIL_ON_STALE_ISSUE_BODY=1

	run warn_if_issue_body_stale \
		"$(_payload "2026-08-20T10:00:00Z" "2026-08-25T11:30:00Z" \
			"stevegrocott" "https://example.invalid/c/1")"
	expect_glob "$status" '1' \
		"the opt-in flag must turn the warning into a hard stop"
	expect_glob "$(cat "$ERROR_LOG")" '*FAIL_ON_STALE_ISSUE_BODY*' \
		"the failure names the flag that caused it"
}

@test "stale guard: FAIL_ON_STALE_ISSUE_BODY=1 still passes a current body (AC3)" {
	source_stale_guard
	export FAIL_ON_STALE_ISSUE_BODY=1

	run warn_if_issue_body_stale \
		"$(_payload "2026-08-26T09:00:00Z" "2026-08-25T11:30:00Z" \
			"stevegrocott" "https://example.invalid/c/1")"
	expect_glob "$status" '0' \
		"failing closed must only fire on an actually stale body"
}

@test "stale guard: an unset flag is not treated as 1 (AC3)" {
	source_stale_guard
	export FAIL_ON_STALE_ISSUE_BODY=0

	run warn_if_issue_body_stale \
		"$(_payload "2026-08-20T10:00:00Z" "2026-08-25T11:30:00Z" \
			"stevegrocott" "https://example.invalid/c/1")"
	expect_glob "$status" '0' \
		"an explicit 0 must behave exactly like the default"
}

# =============================================================================
# WIRING (AC1, AC5)
# =============================================================================

@test "stale guard: parse_issue consults the guard on the payload it already fetched (AC1/AC4)" {
	local main_def
	main_def=$(_extract_function_body main "$BUNDLED_ORCHESTRATOR")

	[[ "$main_def" == *"warn_if_issue_body_stale"* ]] || \
		fail "main() never calls warn_if_issue_body_stale — the guard is dead code"

	# The guard must be fed the SAME read-issue.sh payload parse_issue already
	# has, not a second fetch of its own (AC4).
	local read_issue_calls
	read_issue_calls=$(grep -c 'read-issue\.sh' <<< "$main_def")
	expect_glob "$read_issue_calls" '1' \
		"parse_issue must not add a second read-issue.sh fetch"
}

@test "stale guard: nothing downstream parses comment content (AC5)" {
	local fn_file="$TEST_TMP/guard.bash"
	_extract_function_body warn_if_issue_body_stale "$BUNDLED_ORCHESTRATOR" \
		> "$fn_file"

	# The guard may only read timestamps/author/url — never a comment body,
	# and never the task or acceptance-criteria sections.
	! grep -qE 'latestHumanCommentBody|comments\[\]|_fetch_issue_comment_bodies' \
		"$fn_file" || \
		fail "the staleness guard reads comment content — comments must stay non-authoritative"

	local read_issue_fields
	read_issue_fields=$(grep -c 'body' "$BUNDLED_READ_ISSUE")
	(( read_issue_fields > 0 )) || fail "read-issue.sh no longer returns a body"

	# The emitted payload must not expose comment prose to any caller.
	! grep -qE 'latestHumanCommentBody' "$BUNDLED_READ_ISSUE" || \
		fail "read-issue.sh exposes comment prose — comments must stay non-authoritative"
}
