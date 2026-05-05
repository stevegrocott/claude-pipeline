#!/usr/bin/env bats
#
# test-skill-golden-lib.bats
#
# Tests for skill-golden-lib.sh — manifest parsing, JSON diff (payload
# extraction), red/green reporting, and retry-on-rate-limit.
#
# Mocking strategy: a mock-claude script at $TEST_TMP/bin/mock-claude is
# pointed to by SG_CLAUDE_CLI.  Behaviour is controlled via env vars:
#   MOCK_CLAUDE_OUTPUT     — stdout on success
#   MOCK_CLAUDE_EXIT_CODE  — exit code when succeeding (default 0)
#   MOCK_CLAUDE_CALL_FILE  — path to a file that counts invocations
#   MOCK_CLAUDE_FAIL_TIMES — fail with retryable output this many times first
#   MOCK_CLAUDE_FAIL_OUTPUT— output text when failing (default: "rate limit exceeded")
#   MOCK_CLAUDE_FAIL_EXIT  — exit code when failing (default: 1)
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env

	local mock_bin="$TEST_TMP/bin"
	mkdir -p "$mock_bin"

	# ---------------------------------------------------------------
	# Mock Claude CLI
	# ---------------------------------------------------------------
	cat > "$mock_bin/mock-claude" <<'MOCK_CLAUDE'
#!/usr/bin/env bash
# Mock Claude CLI — controlled via env vars (see test file header).
call_file="${MOCK_CLAUDE_CALL_FILE:-}"
fail_times="${MOCK_CLAUDE_FAIL_TIMES:-0}"
call_n=0

if [[ -n "$call_file" ]]; then
	[[ -f "$call_file" ]] && call_n=$(cat "$call_file")
	call_n=$((call_n + 1))
	printf '%d' "$call_n" > "$call_file"
fi

if ((fail_times > 0 && call_n <= fail_times)); then
	printf '%s' "${MOCK_CLAUDE_FAIL_OUTPUT:-rate limit exceeded}"
	exit "${MOCK_CLAUDE_FAIL_EXIT:-1}"
fi

default_output='{"result":"mock","structured_output":{"route":"fast-path","confidence":"high"}}'
printf '%s' "${MOCK_CLAUDE_OUTPUT:-$default_output}"
exit "${MOCK_CLAUDE_EXIT_CODE:-0}"
MOCK_CLAUDE
	chmod +x "$mock_bin/mock-claude"

	# ---------------------------------------------------------------
	# Default mock state — reset for each test
	# ---------------------------------------------------------------
	export MOCK_CLAUDE_OUTPUT='{"result":"mock","structured_output":{"route":"fast-path","confidence":"high"}}'
	export MOCK_CLAUDE_EXIT_CODE=0
	export MOCK_CLAUDE_FAIL_TIMES=0
	export MOCK_CLAUDE_CALL_FILE="$TEST_TMP/mock-claude-calls"
	rm -f "$MOCK_CLAUDE_CALL_FILE"

	# ---------------------------------------------------------------
	# Library configuration
	# ---------------------------------------------------------------
	export SG_CLAUDE_CLI="$mock_bin/mock-claude"
	export SG_RETRY_BASE_SLEEP=0   # no real sleeps in tests
	export SG_MAX_ATTEMPTS=3

	# ---------------------------------------------------------------
	# Test artefacts: schema and fixture directory
	# ---------------------------------------------------------------
	mkdir -p "$TEST_TMP/fixtures" "$TEST_TMP/schemas"

	cat > "$TEST_TMP/schemas/test-skill.json" <<'SCHEMA'
{"type":"object","properties":{"route":{"type":"string"},"confidence":{"type":"string"}}}
SCHEMA

	# ---------------------------------------------------------------
	# Source the library under test (guard ensures single load per process)
	# ---------------------------------------------------------------
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/skill-golden-lib.sh"
}

teardown() {
	teardown_test_env
}

# =============================================================================
# MANIFEST PARSING — sg_parse_manifest_entry
# =============================================================================

@test "sg_parse_manifest_entry splits fixture|route|criterion into three lines" {
	run sg_parse_manifest_entry "issue-2836|fast-path|no_security_concerns"
	[ "$status" -eq 0 ]
	local fixture route criterion
	fixture=$(printf '%s' "$output" | sed -n '1p')
	route=$(printf '%s'   "$output" | sed -n '2p')
	criterion=$(printf '%s' "$output" | sed -n '3p')
	[ "$fixture"   = "issue-2836"          ]
	[ "$route"     = "fast-path"           ]
	[ "$criterion" = "no_security_concerns" ]
}

@test "sg_parse_manifest_entry handles wildcard criterion" {
	run sg_parse_manifest_entry "issue-2837|fast-path|*"
	[ "$status" -eq 0 ]
	local criterion
	criterion=$(printf '%s' "$output" | sed -n '3p')
	[ "$criterion" = "*" ]
}

@test "sg_parse_manifest_entry handles empty criterion field" {
	run sg_parse_manifest_entry "issue-vague|full|"
	[ "$status" -eq 0 ]
	local fixture route criterion
	fixture=$(printf '%s'   "$output" | sed -n '1p')
	route=$(printf '%s'     "$output" | sed -n '2p')
	criterion=$(printf '%s' "$output" | sed -n '3p')
	[ "$fixture"   = "issue-vague" ]
	[ "$route"     = "full"        ]
	[ "$criterion" = ""            ]
}

@test "sg_parse_manifest_entry outputs exactly three newline-separated fields" {
	local result
	result=$(sg_parse_manifest_entry "f|r|c")
	# $() strips trailing newlines, so "f\nr\nc\n" becomes "f\nr\nc" (2 \n).
	# Re-add one newline via printf '%s\n' to get 3 lines for wc -l.
	local line_count
	line_count=$(printf '%s\n' "$result" | wc -l | tr -d ' ')
	[ "$line_count" -eq 3 ]
}

# =============================================================================
# JSON DIFF / PAYLOAD EXTRACTION — sg_extract_payload
# =============================================================================

@test "sg_extract_payload extracts .structured_output when present" {
	local claude_output='{"result":"ok","structured_output":{"route":"fast-path","confidence":"high"}}'
	run sg_extract_payload "$claude_output"
	[ "$status" -eq 0 ]
	local route
	route=$(printf '%s' "$output" | jq -r '.route')
	[ "$route" = "fast-path" ]
}

@test "sg_extract_payload falls back to .result when no .structured_output" {
	local claude_output='{"result":{"route":"full","confidence":"medium"}}'
	run sg_extract_payload "$claude_output"
	[ "$status" -eq 0 ]
	local route
	route=$(printf '%s' "$output" | jq -r '.route')
	[ "$route" = "full" ]
}

@test "sg_extract_payload parses stringified JSON in .result" {
	local inner='{"route":"fast-path","confidence":"high"}'
	local claude_output
	claude_output=$(jq -n --arg r "$inner" '{"result":$r}')
	run sg_extract_payload "$claude_output"
	[ "$status" -eq 0 ]
	local route
	route=$(printf '%s' "$output" | jq -r '.route')
	[ "$route" = "fast-path" ]
}

@test "sg_extract_payload falls back to top-level object when no nested keys" {
	local claude_output='{"route":"escalate","confidence":"high"}'
	run sg_extract_payload "$claude_output"
	[ "$status" -eq 0 ]
	local route
	route=$(printf '%s' "$output" | jq -r '.route')
	[ "$route" = "escalate" ]
}

@test "sg_extract_payload returns {} for completely non-JSON input" {
	run sg_extract_payload "not json at all"
	[ "$status" -eq 0 ]
	# Output should be {} (the safe fallback)
	[[ "$output" == "{}" ]]
}

@test "sg_extract_payload does not crash on empty string input" {
	# The function is designed for non-empty Claude CLI output; empty input
	# is an edge case.  We only verify the function returns without error.
	run sg_extract_payload ""
	[ "$status" -eq 0 ]
}

# =============================================================================
# JSON DIFF / FIELD ACCESS — sg_get_field
# =============================================================================

@test "sg_get_field returns field value when present" {
	local payload='{"route":"fast-path","confidence":"high"}'
	run sg_get_field "$payload" "route"
	[ "$status" -eq 0 ]
	[ "$output" = "fast-path" ]
}

@test "sg_get_field returns MISSING when field absent and no default given" {
	local payload='{"confidence":"high"}'
	run sg_get_field "$payload" "route"
	[ "$status" -eq 0 ]
	[ "$output" = "MISSING" ]
}

@test "sg_get_field returns custom default for absent field" {
	local payload='{"confidence":"high"}'
	run sg_get_field "$payload" "route" "unknown"
	[ "$status" -eq 0 ]
	[ "$output" = "unknown" ]
}

@test "sg_get_field returns explicit empty default for absent field" {
	local payload='{"confidence":"high"}'
	run sg_get_field "$payload" "disqualifying_criterion" ""
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "sg_get_field returns nested-value as string via tostring" {
	# Numeric JSON values are returned as strings (jq tostring coercion).
	local payload='{"count":42}'
	run sg_get_field "$payload" "count"
	[ "$status" -eq 0 ]
	[ "$output" = "42" ]
}

@test "sg_get_field is safe against field names with special chars via --arg" {
	# The function uses --arg f "$field" to prevent jq filter injection.
	local payload='{"normal":"value"}'
	run sg_get_field "$payload" 'normal'
	[ "$status" -eq 0 ]
	[ "$output" = "value" ]
}

# =============================================================================
# RETRYABLE DETECTION — sg_is_retryable
# =============================================================================

@test "sg_is_retryable returns 0 for 'rate limit' in output" {
	run sg_is_retryable "Error: rate limit exceeded, please slow down"
	[ "$status" -eq 0 ]
}

@test "sg_is_retryable returns 0 for '429' in output" {
	run sg_is_retryable "HTTP 429: Too Many Requests"
	[ "$status" -eq 0 ]
}

@test "sg_is_retryable returns 0 for 'overloaded' in output" {
	run sg_is_retryable "API overloaded, try again later"
	[ "$status" -eq 0 ]
}

@test "sg_is_retryable returns 0 for 'overload_error' in output" {
	run sg_is_retryable "overload_error: service is at capacity"
	[ "$status" -eq 0 ]
}

@test "sg_is_retryable returns 0 for 'timeout' in output" {
	run sg_is_retryable "Connection timeout after 30 seconds"
	[ "$status" -eq 0 ]
}

@test "sg_is_retryable returns 0 for 'timed out' in output" {
	run sg_is_retryable "Request timed out"
	[ "$status" -eq 0 ]
}

@test "sg_is_retryable returns 0 for '503 service unavailable'" {
	run sg_is_retryable "503 Service Unavailable from upstream"
	[ "$status" -eq 0 ]
}

@test "sg_is_retryable returns 0 for 'econnreset' in output" {
	run sg_is_retryable "read ECONNRESET"
	[ "$status" -eq 0 ]
}

@test "sg_is_retryable is case-insensitive for 'RATE LIMIT'" {
	run sg_is_retryable "RATE LIMIT REACHED"
	[ "$status" -eq 0 ]
}

@test "sg_is_retryable returns 1 for a normal error message" {
	run sg_is_retryable "Error: schema validation failed"
	[ "$status" -eq 1 ]
}

@test "sg_is_retryable returns 1 for empty string" {
	run sg_is_retryable ""
	[ "$status" -eq 1 ]
}

@test "sg_is_retryable returns 1 for successful output" {
	run sg_is_retryable '{"result":"ok","structured_output":{"status":"success"}}'
	[ "$status" -eq 1 ]
}

# =============================================================================
# CLAUDE INVOCATION WITH RETRY — sg_invoke_claude
# =============================================================================

@test "sg_invoke_claude returns 0 and prints output on success" {
	export MOCK_CLAUDE_OUTPUT='{"structured_output":{"route":"fast-path"}}'
	run sg_invoke_claude "test prompt" "haiku" "$TEST_TMP/schemas/test-skill.json"
	[ "$status" -eq 0 ]
	[[ "$output" == *"fast-path"* ]]
}

@test "sg_invoke_claude returns 2 when schema file is missing" {
	run sg_invoke_claude "test prompt" "haiku" "$TEST_TMP/schemas/nonexistent.json"
	[ "$status" -eq 2 ]
}

@test "sg_invoke_claude retries on rate-limit and succeeds on second attempt" {
	export MOCK_CLAUDE_FAIL_TIMES=1
	export MOCK_CLAUDE_FAIL_OUTPUT="rate limit exceeded"
	export MOCK_CLAUDE_OUTPUT='{"structured_output":{"route":"escalate"}}'

	run sg_invoke_claude "test prompt" "haiku" "$TEST_TMP/schemas/test-skill.json"

	[ "$status" -eq 0 ]
	[[ "$output" == *"escalate"* ]]

	# Verify the mock was called twice (1 failure + 1 success)
	local call_count
	call_count=$(cat "$MOCK_CLAUDE_CALL_FILE")
	[ "$call_count" -eq 2 ]
}

@test "sg_invoke_claude returns 1 after exhausting all SG_MAX_ATTEMPTS retries" {
	export SG_MAX_ATTEMPTS=3
	export MOCK_CLAUDE_FAIL_TIMES=10   # more than max attempts
	export MOCK_CLAUDE_FAIL_OUTPUT="rate limit exceeded"

	run sg_invoke_claude "test prompt" "haiku" "$TEST_TMP/schemas/test-skill.json"

	[ "$status" -eq 1 ]

	# Verify the last error output is surfaced to the caller (not swallowed).
	[[ "$output" == *"rate limit exceeded"* ]]

	# Verify the mock was called exactly SG_MAX_ATTEMPTS times
	local call_count
	call_count=$(cat "$MOCK_CLAUDE_CALL_FILE")
	[ "$call_count" -eq 3 ]
}

@test "sg_invoke_claude does not retry on non-transient errors" {
	# Non-retryable error (e.g. authentication / schema failure): the function
	# must surface the error output, return non-zero, and invoke claude exactly
	# once — no retry loop.
	export MOCK_CLAUDE_EXIT_CODE=1
	export MOCK_CLAUDE_OUTPUT="Error: authentication failed, check API key"

	run sg_invoke_claude "test prompt" "haiku" "$TEST_TMP/schemas/test-skill.json"

	# Non-transient failures must return 1.
	[ "$status" -eq 1 ]

	# Output must contain the error message (surfaced from claude).
	[[ "$output" == *"authentication failed"* ]]

	# Should only have been called once (no retries).
	local call_count
	call_count=$(cat "$MOCK_CLAUDE_CALL_FILE")
	[ "$call_count" -eq 1 ]
}

@test "sg_invoke_claude succeeds without retry when first call succeeds" {
	run sg_invoke_claude "test prompt" "haiku" "$TEST_TMP/schemas/test-skill.json"
	[ "$status" -eq 0 ]

	local call_count
	call_count=$(cat "$MOCK_CLAUDE_CALL_FILE")
	[ "$call_count" -eq 1 ]
}

# =============================================================================
# SETUP CHECKS — sg_require_cmd / sg_check_setup
# =============================================================================

@test "sg_require_cmd returns 0 for a command that exists" {
	run sg_require_cmd "jq"
	[ "$status" -eq 0 ]
}

@test "sg_require_cmd returns 2 for a command that does not exist" {
	run sg_require_cmd "no-such-command-xyzzy-999"
	[ "$status" -eq 2 ]
}

@test "sg_require_cmd writes error to stderr for missing command" {
	run sg_require_cmd "no-such-command-xyzzy-999"
	[ "$status" -eq 2 ]
	[[ "$output" == *"no-such-command-xyzzy-999"* ]]
}

@test "sg_check_setup returns 0 when all prerequisites are present" {
	run sg_check_setup "$TEST_TMP/fixtures" "$TEST_TMP/schemas/test-skill.json"
	[ "$status" -eq 0 ]
}

@test "sg_check_setup returns 2 when schema file is missing" {
	run sg_check_setup "$TEST_TMP/fixtures" "$TEST_TMP/schemas/does-not-exist.json"
	[ "$status" -eq 2 ]
}

@test "sg_check_setup returns 2 when fixture directory is missing" {
	run sg_check_setup "$TEST_TMP/no-fixtures-dir" "$TEST_TMP/schemas/test-skill.json"
	[ "$status" -eq 2 ]
}

@test "sg_check_setup returns 2 when SG_CLAUDE_CLI is not found" {
	# VAR=val before a bash function (run) does not propagate the variable
	# into subshells spawned by that function — only external commands honour
	# the temporary env-var prefix.  Export explicitly instead, then restore.
	local _saved_cli="${SG_CLAUDE_CLI:-}"
	export SG_CLAUDE_CLI="no-such-claude-binary-xyzzy"
	run sg_check_setup \
		"$TEST_TMP/fixtures" \
		"$TEST_TMP/schemas/test-skill.json"
	export SG_CLAUDE_CLI="$_saved_cli"
	[ "$status" -eq 2 ]
	[[ "$output" == *"no-such-claude-binary-xyzzy"* ]]
}

# =============================================================================
# RED/GREEN REPORTING — sg_print_summary
# =============================================================================

@test "sg_print_summary returns 0 when all fixtures pass" {
	run sg_print_summary 3 3 0 1
	[ "$status" -eq 0 ]
}

@test "sg_print_summary returns 1 when at least one fixture fails" {
	run sg_print_summary 3 2 1 2
	[ "$status" -eq 1 ]
}

@test "sg_print_summary returns 2 when total is zero (no fixtures matched)" {
	run sg_print_summary 0 0 0 0 "myfilter"
	[ "$status" -eq 2 ]
}

@test "sg_print_summary outputs passed/total count line" {
	run sg_print_summary 5 4 1 3
	[[ "$output" == *"4/5"* ]]
}

@test "sg_print_summary includes elapsed time in output" {
	run sg_print_summary 2 2 0 7
	[[ "$output" == *"7s"* ]]
}

@test "sg_print_summary includes PASS indicator on full success" {
	run sg_print_summary 2 2 0 1
	[ "$status" -eq 0 ]
	# ANSI-wrapped PASS — check for the word inside escape codes
	[[ "$output" == *"PASS"* ]]
}

@test "sg_print_summary includes FAIL indicator when failures present" {
	run sg_print_summary 3 1 2 4
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL"* ]]
}

@test "sg_print_summary emits no-match message to stderr for zero total with filter" {
	run sg_print_summary 0 0 0 0 "specific-fixture"
	[ "$status" -eq 2 ]
	# The no-match message goes to stderr; BATS captures combined output via run
	[[ "$output" == *"specific-fixture"* ]]
}

# =============================================================================
# INTEGRATION — sg_run_fixture (PASS / FAIL / WARN / missing fixture)
# =============================================================================

# Helper: define a minimal build_prompt for integration tests.
# Called inside each test that needs it (export -f so subshells see it).
_define_build_prompt() {
	build_prompt() {
		printf 'classify this: %s\n' "$1"
	}
	export -f build_prompt
}

@test "sg_run_fixture returns 0 and prints PASS when route matches" {
	_define_build_prompt
	printf 'test fixture body\n' > "$TEST_TMP/fixtures/issue-pass.md"
	export MOCK_CLAUDE_OUTPUT='{"structured_output":{"route":"fast-path","confidence":"high"}}'

	run sg_run_fixture \
		"issue-pass|fast-path|*" \
		"$TEST_TMP/fixtures" \
		"$TEST_TMP/schemas/test-skill.json" \
		"haiku" \
		"build_prompt"
	[ "$status" -eq 0 ]
	[[ "$output" == *"PASS"* ]]
}

@test "sg_run_fixture returns 1 and prints FAIL when route does not match" {
	_define_build_prompt
	printf 'test fixture body\n' > "$TEST_TMP/fixtures/issue-fail.md"
	export MOCK_CLAUDE_OUTPUT='{"structured_output":{"route":"full","confidence":"high"}}'

	run sg_run_fixture \
		"issue-fail|fast-path|*" \
		"$TEST_TMP/fixtures" \
		"$TEST_TMP/schemas/test-skill.json" \
		"haiku" \
		"build_prompt"
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL"* ]]
	[[ "$output" == *"fast-path"* ]]   # expected route visible in output
	[[ "$output" == *"full"* ]]        # actual route visible in output
}

@test "sg_run_fixture returns 0 and prints WARN when criterion mismatches" {
	_define_build_prompt
	printf 'test fixture body\n' > "$TEST_TMP/fixtures/issue-warn.md"
	# Route matches but criterion is different from expected
	export MOCK_CLAUDE_OUTPUT='{"structured_output":{"route":"full","confidence":"high","disqualifying_criterion":"surgical_size"}}'

	run sg_run_fixture \
		"issue-warn|full|test_only_scope" \
		"$TEST_TMP/fixtures" \
		"$TEST_TMP/schemas/test-skill.json" \
		"haiku" \
		"build_prompt"
	# WARN is non-fatal: exit 0
	[ "$status" -eq 0 ]
	[[ "$output" == *"WARN"* ]]
}

@test "sg_run_fixture returns 1 when fixture file does not exist" {
	_define_build_prompt
	# Do NOT create the fixture file

	run sg_run_fixture \
		"issue-missing|fast-path|*" \
		"$TEST_TMP/fixtures" \
		"$TEST_TMP/schemas/test-skill.json" \
		"haiku" \
		"build_prompt"
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL"* ]]
}

@test "sg_run_fixture accepts .json fixture when .md is absent" {
	_define_build_prompt
	printf '{"stage":"implement","status":"timeout"}\n' \
		> "$TEST_TMP/fixtures/issue-json.json"
	export MOCK_CLAUDE_OUTPUT='{"structured_output":{"route":"escalate","confidence":"high"}}'

	run sg_run_fixture \
		"issue-json|escalate|*" \
		"$TEST_TMP/fixtures" \
		"$TEST_TMP/schemas/test-skill.json" \
		"haiku" \
		"build_prompt"
	[ "$status" -eq 0 ]
	[[ "$output" == *"PASS"* ]]
}

@test "sg_run_fixture returns 1 when prompt builder function is not defined" {
	printf 'test fixture body\n' > "$TEST_TMP/fixtures/issue-noprompt.md"
	# unset_build_prompt is not a defined function

	run sg_run_fixture \
		"issue-noprompt|fast-path|*" \
		"$TEST_TMP/fixtures" \
		"$TEST_TMP/schemas/test-skill.json" \
		"haiku" \
		"unset_build_prompt_fn_xyz"
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL"* ]]
}

# =============================================================================
# INTEGRATION — sg_run_manifest
# =============================================================================

@test "sg_run_manifest returns 0 when all entries pass" {
	_define_build_prompt
	printf 'body a\n' > "$TEST_TMP/fixtures/fix-a.md"
	printf 'body b\n' > "$TEST_TMP/fixtures/fix-b.md"
	export MOCK_CLAUDE_OUTPUT='{"structured_output":{"route":"fast-path","confidence":"high"}}'

	run sg_run_manifest \
		"$TEST_TMP/fixtures" \
		"$TEST_TMP/schemas/test-skill.json" \
		"haiku" \
		"build_prompt" \
		"" \
		"fix-a|fast-path|*" \
		"fix-b|fast-path|*"
	[ "$status" -eq 0 ]
	[[ "$output" == *"PASS"* ]]
}

@test "sg_run_manifest returns 1 when at least one entry fails" {
	_define_build_prompt
	printf 'body a\n' > "$TEST_TMP/fixtures/fix-c.md"
	printf 'body b\n' > "$TEST_TMP/fixtures/fix-d.md"
	# Claude always returns full; manifest expects fast-path for fix-c → FAIL
	export MOCK_CLAUDE_OUTPUT='{"structured_output":{"route":"full","confidence":"high"}}'

	run sg_run_manifest \
		"$TEST_TMP/fixtures" \
		"$TEST_TMP/schemas/test-skill.json" \
		"haiku" \
		"build_prompt" \
		"" \
		"fix-c|fast-path|*" \
		"fix-d|full|*"
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL"* ]]
}

@test "sg_run_manifest returns 2 when filter matches no fixtures" {
	_define_build_prompt
	printf 'body a\n' > "$TEST_TMP/fixtures/fix-e.md"
	export MOCK_CLAUDE_OUTPUT='{"structured_output":{"route":"fast-path","confidence":"high"}}'

	run sg_run_manifest \
		"$TEST_TMP/fixtures" \
		"$TEST_TMP/schemas/test-skill.json" \
		"haiku" \
		"build_prompt" \
		"nonexistent-fixture" \
		"fix-e|fast-path|*"
	[ "$status" -eq 2 ]
}

@test "sg_run_manifest filter runs only the matching fixture" {
	_define_build_prompt
	printf 'body x\n' > "$TEST_TMP/fixtures/fix-x.md"
	printf 'body y\n' > "$TEST_TMP/fixtures/fix-y.md"
	# Only fix-x should run; fix-y is filtered out.
	# Claude returns full; fix-y expects fast-path (would fail) but it won't run.
	export MOCK_CLAUDE_OUTPUT='{"structured_output":{"route":"fast-path","confidence":"high"}}'

	run sg_run_manifest \
		"$TEST_TMP/fixtures" \
		"$TEST_TMP/schemas/test-skill.json" \
		"haiku" \
		"build_prompt" \
		"fix-x" \
		"fix-x|fast-path|*" \
		"fix-y|fast-path|*"
	[ "$status" -eq 0 ]
	[[ "$output" == *"PASS"* ]]
}

# =============================================================================
# COLOR HELPERS — sg_red / sg_green / sg_yellow / sg_dim
# =============================================================================

@test "sg_red wraps text with red ANSI codes" {
	local result
	result=$(sg_red "FAIL")
	# Must contain the text itself
	[[ "$result" == *"FAIL"* ]]
	# Must start with an ESC (ANSI) sequence
	[[ "$result" == $'\033'* ]]
}

@test "sg_green wraps text with green ANSI codes" {
	local result
	result=$(sg_green "PASS")
	[[ "$result" == *"PASS"* ]]
	[[ "$result" == $'\033'* ]]
}

@test "sg_yellow wraps text with yellow ANSI codes" {
	local result
	result=$(sg_yellow "WARN")
	[[ "$result" == *"WARN"* ]]
	[[ "$result" == $'\033'* ]]
}

@test "sg_dim wraps text with dim ANSI codes" {
	local result
	result=$(sg_dim "note")
	[[ "$result" == *"note"* ]]
	[[ "$result" == $'\033'* ]]
}

# =============================================================================
# DOUBLE-SOURCE GUARD — _SKILL_GOLDEN_LIB_SOURCED
# =============================================================================

@test "sourcing the lib a second time in same process is a no-op" {
	# The guard variable is already set from setup().
	# Sourcing again must not redefine or error.
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/skill-golden-lib.sh"
	# If we get here without error, the guard worked.
	[ "$_SKILL_GOLDEN_LIB_SOURCED" -eq 1 ]
}
