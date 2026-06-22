#!/usr/bin/env bash
#
# skill-golden-lib.sh
#
# Reusable functions for skill-golden tests — real-Claude prompt regression
# harness for decision skills. Extracted from triage-validate.sh so the same
# pattern can pin down every decision skill (triage-classify, escalation-
# policy, retry-policy, model-fallback, pipeline-recovery), not just triage.
#
# This file is a LIBRARY — source it from a thin driver script:
#
#     #!/usr/bin/env bash
#     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     source "$SCRIPT_DIR/skill-golden-lib.sh"
#
#     build_prompt() {
#         local issue_body="$1"
#         cat <<EOF
#     ... your skill's prompt referencing $issue_body ...
#     EOF
#     }
#
#     MANIFEST=(
#         "fixture-a|fast-path|*"
#         "fixture-b|full|some_criterion"
#     )
#
#     sg_check_setup "$FIXTURE_DIR" "$SCHEMA_FILE" || exit 2
#     sg_run_manifest "$FIXTURE_DIR" "$SCHEMA_FILE" "$MODEL" \
#         build_prompt "${1:-}" "${MANIFEST[@]}"
#     exit $?
#
# CONTRACT (manifest format):
#   "fixture_basename|expected_route|expected_criterion_or_*"
#     - fixture_basename — file under FIXTURE_DIR named "<basename>.md"
#     - expected_route   — primary decision the skill returns under .route
#     - expected_criterion_or_* — pinpoint criterion under
#       .disqualifying_criterion (or "*" to accept any). Only checked when
#       the route mismatch would otherwise be the only flip surface; a wrong
#       criterion is a WARN, not a FAIL — the route is the contract.
#
# OUTPUT EXTRACTION:
#   Mirrors run_stage() in implement-issue-orchestrator.sh: prefer
#   .structured_output, fall back to .result (parsed if stringified JSON),
#   then to the top-level object. If these diverge from the orchestrator,
#   the validator stops reflecting prod — keep them in sync.
#
# CUSTOMIZATION (env vars, all optional):
#   SG_CLAUDE_CLI         path to claude CLI (default "claude")
#   SG_MAX_ATTEMPTS       Claude invocation retries on transient errors (3)
#   SG_RETRY_BASE_SLEEP   seconds between retries, multiplied by attempt (5)
#   SG_ROUTE_FIELD        JSON field for primary decision (default "route")
#   SG_CRITERION_FIELD    JSON field for criterion (default
#                         "disqualifying_criterion")
#   SG_CONFIDENCE_FIELD   JSON field for confidence (default "confidence")
#   SG_SUMMARY_FIELD      JSON field for summary (default "summary")
#

# Guard against double-sourcing — multiple drivers may pull this in via the
# same parent process (skill-golden.sh --all dispatches per-skill).
if [[ -n "${_SKILL_GOLDEN_LIB_SOURCED:-}" ]]; then
	return 0 2>/dev/null || true
fi
_SKILL_GOLDEN_LIB_SOURCED=1

# Defaults — set only if unset so drivers can pre-configure.
: "${SG_CLAUDE_CLI:=claude}"
: "${SG_MAX_ATTEMPTS:=3}"
: "${SG_RETRY_BASE_SLEEP:=5}"
: "${SG_ROUTE_FIELD:=route}"
: "${SG_CRITERION_FIELD:=disqualifying_criterion}"
: "${SG_CONFIDENCE_FIELD:=confidence}"
: "${SG_SUMMARY_FIELD:=summary}"

# =============================================================================
# Color helpers — write ANSI escapes to stdout. Callers wrap with printf.
# =============================================================================

sg_red()    { printf '\033[31m%s\033[0m' "$1"; }
sg_green()  { printf '\033[32m%s\033[0m' "$1"; }
sg_yellow() { printf '\033[33m%s\033[0m' "$1"; }
sg_dim()    { printf '\033[2m%s\033[0m' "$1"; }

# =============================================================================
# Setup checks — verify external commands and required paths exist.
# All errors go to stderr; functions return non-zero on failure.
# =============================================================================

sg_require_cmd() {
	local cmd="$1"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		printf 'skill-golden: required command not found: %s\n' \
			"$cmd" >&2
		return 2
	fi
	return 0
}

# sg_check_setup FIXTURE_DIR SCHEMA_FILE
# Verifies jq, the configured claude CLI, the schema file, and the fixture
# directory all exist. Returns 0 on success, 2 on any failure.
sg_check_setup() {
	local fixture_dir="$1"
	local schema_file="$2"
	local rc=0

	sg_require_cmd jq || rc=2
	sg_require_cmd "$SG_CLAUDE_CLI" || rc=2

	if [[ ! -f "$schema_file" ]]; then
		printf 'skill-golden: schema not found: %s\n' \
			"$schema_file" >&2
		rc=2
	fi

	if [[ ! -d "$fixture_dir" ]]; then
		printf 'skill-golden: fixture dir not found: %s\n' \
			"$fixture_dir" >&2
		rc=2
	fi

	return "$rc"
}

# =============================================================================
# Manifest parser — splits "fixture|expected_route|expected_criterion" into
# three newline-separated fields on stdout. Drivers usually parse inline with
# `IFS='|' read -r f r c <<<"$entry"`; this function exists for tests and
# for any caller that wants a single source of truth for the format.
# =============================================================================

sg_parse_manifest_entry() {
	local entry="$1"
	local fixture expected_route expected_criterion
	IFS='|' read -r fixture expected_route expected_criterion <<<"$entry"
	printf '%s\n%s\n%s\n' \
		"$fixture" "$expected_route" "$expected_criterion"
}

# =============================================================================
# Claude invocation with retry — calls the claude CLI with the prompt and
# schema, retrying on transient errors (rate limit, overload, timeout) with
# linear backoff. Output (stdout from claude on success, stderr from claude
# on failure) is written to this function's stdout. Logs go to stderr.
#
# sg_invoke_claude PROMPT MODEL SCHEMA_FILE
#   PROMPT      — full prompt string passed via -p
#   MODEL       — model alias (haiku, sonnet, etc)
#   SCHEMA_FILE — path to the JSON schema for --json-schema
#
# Returns:
#   0 — claude succeeded; payload on stdout
#   1 — claude failed after all retries; last output on stdout for diagnostics
#   2 — schema file unreadable
# =============================================================================

sg_invoke_claude() {
	local prompt="$1"
	local model="$2"
	local schema_file="$3"
	local schema_compact output rc=0
	local attempt=1 backoff

	if ! schema_compact=$(jq -c . "$schema_file" 2>&1); then
		printf 'skill-golden: failed to compact schema %s: %s\n' \
			"$schema_file" "$schema_compact" >&2
		return 2
	fi

	while ((attempt <= SG_MAX_ATTEMPTS)); do
		# NB: capture rc separately, not via `rc=$?` after `if...fi`.
		# Bash sets $? to 0 after a failed `if` with no `else` branch,
		# so the post-fi capture would always read 0 and silently
		# convert non-retryable failures into "success" returns.
		output=$(env -u CLAUDECODE "$SG_CLAUDE_CLI" -p "$prompt" \
			--model "$model" \
			--dangerously-skip-permissions \
			--output-format json \
			--json-schema "$schema_compact" 2>&1)
		rc=$?
		if ((rc == 0)); then
			printf '%s' "$output"
			return 0
		fi

		# Retry on transient signals only. Anything else is a real
		# error (auth, schema mismatch, missing flag) — surface it.
		if sg_is_retryable "$output"; then
			backoff=$((attempt * SG_RETRY_BASE_SLEEP))
			printf 'skill-golden: transient error (attempt %d/%d), sleeping %ds\n' \
				"$attempt" "$SG_MAX_ATTEMPTS" \
				"$backoff" >&2
			sleep "$backoff"
			attempt=$((attempt + 1))
			continue
		fi

		printf '%s' "$output"
		return "$rc"
	done

	printf '%s' "$output"
	return 1
}

# Pure check — does this output look like a transient/retryable error?
# Kept small and case-insensitive; expand only when a new transient
# signature is observed in the wild. Uses tr (not bash 4 ${var,,}) so the
# library stays compatible with macOS-system bash 3.2.
sg_is_retryable() {
	local output="$1"
	local lower
	lower=$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')
	case "$lower" in
		*"rate limit"*|*"429"*|*"overloaded"* \
			|*"overload_error"*|*"timeout"*|*"timed out"* \
			|*"503 service unavailable"*|*"econnreset"*)
			return 0
			;;
	esac
	return 1
}

# =============================================================================
# JSON output validation — extract the schema-validated payload from the
# claude CLI's wrapped JSON response. Mirrors run_stage() in
# implement-issue-orchestrator.sh; if these diverge, the validator stops
# reflecting prod.
#
# sg_extract_payload OUTPUT
#   Echoes the inner JSON object on stdout. Echoes "{}" (and writes a note to
#   stderr) when the payload cannot be located or is not valid JSON. Always
#   returns 0 — callers detect missing fields by inspecting the payload.
# =============================================================================

sg_extract_payload() {
	local output="$1"
	local payload

	payload=$(printf '%s' "$output" | jq -c '
		.structured_output
		// (.result | if type == "string" then fromjson? else . end)
		// .
	' 2>/dev/null || echo '{}')

	if ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
		printf 'skill-golden: payload not valid JSON, treating as {}\n' >&2
		payload='{}'
	fi

	printf '%s' "$payload"
}

# sg_get_field PAYLOAD FIELD [DEFAULT]
#   Returns the string value of .FIELD on the payload, or DEFAULT if the
#   field is absent. Default is "MISSING" only when the third arg is unset;
#   passing an empty string explicitly (sg_get_field x y "") is honored —
#   needed for optional fields like .summary where "" is a valid result.
#   Stderr-silent. Uses --arg to avoid jq filter injection from field names.
sg_get_field() {
	local payload="$1"
	local field="$2"
	local default="${3-MISSING}"
	local value
	if ! value=$(printf '%s' "$payload" \
		| jq -r --arg f "$field" --arg d "$default" \
			'(.[$f] // $d) | tostring' \
		2>/dev/null); then
		value="$default"
	fi
	printf '%s' "$value"
}

# =============================================================================
# Fixture runner — executes one manifest entry end-to-end: load fixture,
# build prompt, call claude, extract payload, compare against expected.
#
# sg_run_fixture ENTRY FIXTURE_DIR SCHEMA_FILE MODEL PROMPT_BUILDER_FN
#   ENTRY              — manifest line "fixture|route|criterion"
#   FIXTURE_DIR        — directory containing "<fixture>.md"
#   SCHEMA_FILE        — JSON schema for the skill's output
#   MODEL              — model alias to invoke
#   PROMPT_BUILDER_FN  — name of a shell function defined by the driver
#                        that takes the fixture body on $1 and prints the
#                        full prompt on stdout
#
# Prints one line per fixture (PASS / FAIL / WARN) to stdout. Returns:
#   0 — PASS or WARN (route matched; criterion may have flipped)
#   1 — FAIL (route mismatched or fixture/CLI failure)
# =============================================================================

sg_run_fixture() {
	local entry="$1"
	local fixture_dir="$2"
	local schema_file="$3"
	local model="$4"
	local prompt_builder="$5"

	local fixture expected_route expected_criterion
	IFS='|' read -r fixture expected_route expected_criterion <<<"$entry"

	# Try .md first (issue-body fixtures), then .json (structured-event
	# fixtures such as escalation-policy stage results).
	local body_file="$fixture_dir/${fixture}.md"
	if [[ ! -f "$body_file" ]]; then
		body_file="$fixture_dir/${fixture}.json"
	fi
	if [[ ! -f "$body_file" ]]; then
		printf '  %s missing fixture: %s.{md,json}\n' \
			"$(sg_red "FAIL")" "$fixture_dir/$fixture"
		return 1
	fi

	if ! declare -F "$prompt_builder" >/dev/null 2>&1; then
		printf '  %s %-28s prompt builder not defined: %s\n' \
			"$(sg_red "FAIL")" "$fixture" "$prompt_builder"
		return 1
	fi

	local body prompt output start end elapsed_ms timing_label
	body=$(cat "$body_file")
	prompt=$("$prompt_builder" "$body")

	start=$(date +%s%N 2>/dev/null || echo 0)
	if ! output=$(sg_invoke_claude "$prompt" "$model" "$schema_file"); then
		printf '  %s %-28s claude invocation failed\n' \
			"$(sg_red "FAIL")" "$fixture"
		printf '%s\n' "$output" | head -5 | sed 's/^/      /'
		return 1
	fi
	end=$(date +%s%N 2>/dev/null || echo 0)
	elapsed_ms=$(( (end - start) / 1000000 ))
	timing_label=$(printf '%6dms' "$elapsed_ms")

	local payload route confidence criterion summary
	payload=$(sg_extract_payload "$output")
	route=$(sg_get_field "$payload" "$SG_ROUTE_FIELD" "MISSING")
	confidence=$(sg_get_field "$payload" "$SG_CONFIDENCE_FIELD" "MISSING")
	criterion=$(sg_get_field "$payload" "$SG_CRITERION_FIELD" "")
	summary=$(sg_get_field "$payload" "$SG_SUMMARY_FIELD" "")

	if [[ "$route" != "$expected_route" ]]; then
		printf '  %s %-28s %s  expected=%s got=%s confidence=%s\n' \
			"$(sg_red "FAIL")" "$fixture" "$timing_label" \
			"$expected_route" "$route" "$confidence"
		[[ -n "$summary" ]] && printf '      %s\n' \
			"$(sg_dim "summary: $summary")"
		return 1
	fi

	# Criterion check is secondary — the route is the contract. Mismatch
	# is a WARN so operators see drift without flipping CI red.
	if [[ -n "$expected_criterion" \
		&& "$expected_criterion" != "*" \
		&& "$criterion" != "$expected_criterion" ]]; then
		printf '  %s %-28s %s  route=%s ok, but %s=%s expected=%s\n' \
			"$(sg_yellow "WARN")" "$fixture" "$timing_label" \
			"$route" "$SG_CRITERION_FIELD" \
			"${criterion:-<empty>}" "$expected_criterion"
		[[ -n "$summary" ]] && printf '      %s\n' \
			"$(sg_dim "summary: $summary")"
		return 0
	fi

	printf '  %s %-28s %s  %s=%s confidence=%s\n' \
		"$(sg_green "PASS")" "$fixture" "$timing_label" \
		"$SG_ROUTE_FIELD" "$route" "$confidence"
	return 0
}

# =============================================================================
# Manifest iteration — runs every entry, applies an optional fixture filter,
# emits per-fixture lines, and prints a summary. Returns:
#   0 — all matched fixtures passed (or warned)
#   1 — at least one fixture flipped
#   2 — filter matched no fixtures
#
# sg_run_manifest FIXTURE_DIR SCHEMA_FILE MODEL PROMPT_BUILDER FILTER ENTRIES...
#   FILTER may be empty (run all). Otherwise only entries whose fixture
#   basename equals FILTER run.
# =============================================================================

sg_run_manifest() {
	local fixture_dir="$1"; shift
	local schema_file="$1"; shift
	local model="$1"; shift
	local prompt_builder="$1"; shift
	local filter="$1"; shift
	# Remaining "$@" are manifest entries.

	local total=0 passed=0 failed=0
	local entry fixture run_start run_end elapsed

	run_start=$(date +%s)

	printf 'skill-golden: %d fixtures, model=%s\n' "$#" "$model"
	printf '\n'

	for entry in "$@"; do
		fixture="${entry%%|*}"
		if [[ -n "$filter" && "$fixture" != "$filter" ]]; then
			continue
		fi
		total=$((total + 1))
		if sg_run_fixture "$entry" "$fixture_dir" "$schema_file" \
			"$model" "$prompt_builder"; then
			passed=$((passed + 1))
		else
			failed=$((failed + 1))
		fi
	done

	run_end=$(date +%s)
	elapsed=$((run_end - run_start))

	sg_print_summary "$total" "$passed" "$failed" "$elapsed" "$filter"
}

# =============================================================================
# Reporter — prints summary line and final PASS/FAIL marker. Returns:
#   0 — all passed
#   1 — at least one failure
#   2 — total == 0 (no fixtures matched)
# =============================================================================

sg_print_summary() {
	local total="$1"
	local passed="$2"
	local failed="$3"
	local elapsed="$4"
	local filter="${5:-}"

	printf '\n'
	printf 'skill-golden: %d/%d passed in %ds\n' \
		"$passed" "$total" "$elapsed"

	if ((total == 0)); then
		printf 'skill-golden: no fixtures matched filter: %s\n' \
			"$filter" >&2
		return 2
	fi

	if ((failed > 0)); then
		printf '%s\n' "$(sg_red "FAIL")"
		return 1
	fi

	printf '%s\n' "$(sg_green "PASS")"
	return 0
}

# =============================================================================
# BODY-GENERATOR GOLDEN TESTS — validate deterministic body-generator output
# (e.g. create-followup-issue.sh) against the structural criteria from
# issue-body-lib.sh.  Does NOT invoke Claude.
#
# Pre-conditions for callers:
#   1. source issue-body-lib.sh before calling sg_validate_body.
#   2. Export ISSUE_BODY_AGENTS_DIR, ISSUE_BODY_REPO_ROOT, and optionally
#      DEPLOY_VERIFY_CMD to configure the validation sandbox.
# =============================================================================

# sg_validate_body BODY [LABEL]
#   Calls assert_issue_valid on BODY and prints one PASS/FAIL line.
#   Errors from assert_issue_valid are captured from stderr and indented
#   under the FAIL line so the caller's stdout is clean to parse.
#   Returns 0 when BODY passes all criteria, 1 otherwise.
sg_validate_body() {
	local body="$1"
	local label="${2:-body}"
	local errors rc=0

	errors=$(assert_issue_valid "$body" 2>&1) || rc=1

	if ((rc == 0)); then
		printf '  %s %s\n' "$(sg_green "PASS")" "$label"
	else
		printf '  %s %s\n' "$(sg_red "FAIL")" "$label"
		printf '%s\n' "$errors" | sed 's/^/      /'
	fi

	return "$rc"
}
