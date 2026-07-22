#!/usr/bin/env bats
#
# test-cost-trend-guard.bats
#
# Tests for the advisory cost/token trend guard (issue #585):
#   - cost-trend-guard.sh: rolling MT/issue baseline, factor threshold,
#     env configurability, and NO-OP when #580's cost_summary is absent.
#   - batch-orchestrator.sh: epic-scope preflight flag routing to split-first.
#
# The guard is ADVISORY — it must never exit non-zero for a well-formed
# invocation and must degrade to a benign noop verdict.
#

load 'helpers/test-helper.bash'

GUARD_SCRIPT="$SCRIPT_DIR/cost-trend-guard.sh"

setup() {
	setup_test_env
}

teardown() {
	teardown_test_env
}

# Build a batch summary/status JSON in the shape batch-orchestrator.sh writes:
# a batch-level cost_summary with the #580 token totals (total_input_tokens /
# total_output_tokens / total_cache_read_tokens / total_cache_creation_tokens)
# plus progress.completed. Cache token totals are 0 here; the input/output
# split is what drives the MT/issue arithmetic in these tests.
# Usage: _mk_summary <file> <input_tokens> <output_tokens> <completed>
_mk_summary() {
	local file="$1" in_tok="$2" out_tok="$3" completed="$4"
	mkdir -p "$(dirname "$file")"
	jq -n \
		--argjson i "$in_tok" \
		--argjson o "$out_tok" \
		--argjson c "$completed" \
		'{cost_summary: {
			total_cost_usd: 0,
			total_input_tokens: $i,
			total_output_tokens: $o,
			total_cache_read_tokens: 0,
			total_cache_creation_tokens: 0
		},
		  progress: {completed: $c}}' > "$file"
}

# Build a batch status/summary JSON in the EXACT shape batch-orchestrator.sh
# writes: an issues[] array carrying per-issue cost_usd + token fields, and a
# batch-level cost_summary rolled up from those issues exactly as
# update_progress does. Two completed issues total 10.5M tokens
# (8M input + 1.5M output + 0.5M cache_read + 0.5M cache_creation) over 2
# completed issues = 5.25 MT/issue.
_mk_batch_status() {
	local file="$1"
	mkdir -p "$(dirname "$file")"
	jq -n '{
		state: "completed",
		base_branch: "main",
		progress: {total: 2, completed: 2, failed: 0},
		issues: [
			{number:"1", status:"completed", cost_usd:1.0,
			 input_tokens:5000000, output_tokens:1000000,
			 cache_read_tokens:500000, cache_creation_tokens:0},
			{number:"2", status:"completed", cost_usd:0.6,
			 input_tokens:3000000, output_tokens:500000,
			 cache_read_tokens:0, cache_creation_tokens:500000}
		]
	}
	| .cost_summary = {
		total_cost_usd:
			([.issues[] | (.cost_usd // 0)] | add // 0),
		total_input_tokens:
			([.issues[] | (.input_tokens // 0)] | add // 0),
		total_output_tokens:
			([.issues[] | (.output_tokens // 0)] | add // 0),
		total_cache_read_tokens:
			([.issues[] | (.cache_read_tokens // 0)] | add // 0),
		total_cache_creation_tokens:
			([.issues[] | (.cache_creation_tokens // 0)] | add // 0)
	}' > "$file"
}

# =============================================================================
# PRECONDITIONS
# =============================================================================

@test "cost-trend-guard.sh exists and is executable" {
	[[ -f "$GUARD_SCRIPT" ]]
	[[ -x "$GUARD_SCRIPT" ]]
}

@test "cost-trend-guard.sh passes bash -n" {
	run bash -n "$GUARD_SCRIPT"
	[[ "$status" -eq 0 ]]
}

@test "cost-trend-guard.sh is sourceable without running the CLI" {
	# Sourcing must define functions but not execute ctg_main.
	source "$GUARD_SCRIPT"
	run declare -f ctg_batch_mt
	[[ "$status" -eq 0 ]]
	run declare -f ctg_baseline
	[[ "$status" -eq 0 ]]
	run declare -f ctg_evaluate
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# MT/ISSUE EXTRACTION + BASELINE MATH
# =============================================================================

@test "ctg_batch_mt computes megatokens per completed issue" {
	source "$GUARD_SCRIPT"
	# 6M + 4M = 10M tokens over 5 issues = 2.0 MT/issue.
	_mk_summary "$TEST_TMP/s.json" 6000000 4000000 5
	local mt
	mt=$(ctg_batch_mt "$TEST_TMP/s.json")
	[[ "$mt" == "2.000000" ]]
}

@test "ctg_batch_mt sums all four token totals (incl. cache) from cost_summary" {
	source "$GUARD_SCRIPT"
	# 5M in + 1M out + 0.5M cache_read + 0.5M cache_creation = 7M over 2 = 3.5.
	jq -n '{cost_summary: {
			total_input_tokens: 5000000,
			total_output_tokens: 1000000,
			total_cache_read_tokens: 500000,
			total_cache_creation_tokens: 500000
		}, progress: {completed: 2}}' > "$TEST_TMP/s.json"
	local mt
	mt=$(ctg_batch_mt "$TEST_TMP/s.json")
	[[ "$mt" == "3.500000" ]]
}

@test "ctg_baseline averages MT/issue over the window" {
	source "$GUARD_SCRIPT"
	# Three batches: 1.0, 2.0, 3.0 MT/issue. Mean = 2.0.
	_mk_summary "$TEST_TMP/b1.json" 1000000 0 1
	_mk_summary "$TEST_TMP/b2.json" 2000000 0 1
	_mk_summary "$TEST_TMP/b3.json" 3000000 0 1
	local base
	base=$(ctg_baseline 5 "$TEST_TMP/b1.json" "$TEST_TMP/b2.json" "$TEST_TMP/b3.json")
	[[ "$base" == "2.000000" ]]
}

@test "ctg_baseline honors the window size (only most-recent N)" {
	source "$GUARD_SCRIPT"
	# Four batches: 1,2,3,4 MT/issue. Window 2 → mean of last two (3,4) = 3.5.
	_mk_summary "$TEST_TMP/b1.json" 1000000 0 1
	_mk_summary "$TEST_TMP/b2.json" 2000000 0 1
	_mk_summary "$TEST_TMP/b3.json" 3000000 0 1
	_mk_summary "$TEST_TMP/b4.json" 4000000 0 1
	local base
	base=$(ctg_baseline 2 \
		"$TEST_TMP/b1.json" "$TEST_TMP/b2.json" \
		"$TEST_TMP/b3.json" "$TEST_TMP/b4.json")
	[[ "$base" == "3.500000" ]]
}

# =============================================================================
# FACTOR THRESHOLD: WARN / NO-WARN
# =============================================================================

@test "warns when latest MT/issue exceeds baseline * factor" {
	# Baseline 1.0 MT/issue; latest 2.0 > 1.0 * 1.5.
	_mk_summary "$TEST_TMP/hist/batch-1/summary.json" 1000000 0 1
	_mk_summary "$TEST_TMP/hist/batch-2/summary.json" 1000000 0 1
	_mk_summary "$TEST_TMP/cur/status.json" 10000000 0 5

	run env COST_TREND_FACTOR=1.5 COST_TREND_WINDOW=5 \
		"$GUARD_SCRIPT" --current "$TEST_TMP/cur/status.json" \
		--history-dir "$TEST_TMP/hist"
	[[ "$status" -eq 0 ]]
	local warn
	warn=$(printf '%s' "$output" | jq -r '.warning')
	[[ "$warn" == "true" ]]
}

@test "does not warn when latest is within baseline * factor" {
	# Baseline 1.0; latest 2.0 is within 1.0 * 3.0.
	_mk_summary "$TEST_TMP/hist/batch-1/summary.json" 1000000 0 1
	_mk_summary "$TEST_TMP/hist/batch-2/summary.json" 1000000 0 1
	_mk_summary "$TEST_TMP/cur/status.json" 10000000 0 5

	run env COST_TREND_FACTOR=3.0 COST_TREND_WINDOW=5 \
		"$GUARD_SCRIPT" --current "$TEST_TMP/cur/status.json" \
		--history-dir "$TEST_TMP/hist"
	[[ "$status" -eq 0 ]]
	local warn
	warn=$(printf '%s' "$output" | jq -r '.warning')
	[[ "$warn" == "false" ]]
}

@test "COST_TREND_FACTOR env is honored (same data, opposite verdict)" {
	_mk_summary "$TEST_TMP/hist/batch-1/summary.json" 1000000 0 1
	_mk_summary "$TEST_TMP/cur/status.json" 1600000 0 1  # 1.6 MT/issue

	# factor 1.5 → threshold 1.5 → 1.6 warns.
	run env COST_TREND_FACTOR=1.5 "$GUARD_SCRIPT" \
		--current "$TEST_TMP/cur/status.json" --history-dir "$TEST_TMP/hist"
	[[ "$(printf '%s' "$output" | jq -r '.warning')" == "true" ]]

	# factor 2.0 → threshold 2.0 → 1.6 does not warn.
	run env COST_TREND_FACTOR=2.0 "$GUARD_SCRIPT" \
		--current "$TEST_TMP/cur/status.json" --history-dir "$TEST_TMP/hist"
	[[ "$(printf '%s' "$output" | jq -r '.warning')" == "false" ]]
}

@test "--factor / --window flags override the environment" {
	_mk_summary "$TEST_TMP/hist/batch-1/summary.json" 1000000 0 1
	_mk_summary "$TEST_TMP/cur/status.json" 1600000 0 1
	run "$GUARD_SCRIPT" --current "$TEST_TMP/cur/status.json" \
		--history-dir "$TEST_TMP/hist" --factor 1.5 --window 3
	[[ "$status" -eq 0 ]]
	[[ "$(printf '%s' "$output" | jq -r '.warning')" == "true" ]]
	[[ "$(printf '%s' "$output" | jq -r '.factor')" == "1.5" ]]
	[[ "$(printf '%s' "$output" | jq -r '.window')" == "3" ]]
}

# =============================================================================
# NO-OP: cost_summary absent (issue #580 metric missing)
# =============================================================================

@test "no-ops when cost_summary is absent" {
	jq -n '{progress: {completed: 5}}' > "$TEST_TMP/nocs.json"
	run "$GUARD_SCRIPT" --current "$TEST_TMP/nocs.json"
	[[ "$status" -eq 0 ]]
	[[ "$(printf '%s' "$output" | jq -r '.status')" == "noop" ]]
	[[ "$(printf '%s' "$output" | jq -r '.warning')" == "false" ]]
}

@test "ctg_batch_mt prints nothing when cost_summary is absent" {
	source "$GUARD_SCRIPT"
	jq -n '{progress: {completed: 5}}' > "$TEST_TMP/nocs.json"
	local mt
	mt=$(ctg_batch_mt "$TEST_TMP/nocs.json")
	[[ -z "$mt" ]]
}

@test "no-ops when cost_summary carries only total_cost_usd (no token totals)" {
	# Old/absent token rollup: cost_summary has total_cost_usd but none of the
	# total_*_tokens fields → token sum is 0 → not computable → noop. This is
	# the pre-token-rollup graceful-degradation contract.
	jq -n '{cost_summary: {total_cost_usd: 1.23}, progress: {completed: 3}}' \
		> "$TEST_TMP/costonly.json"
	run "$GUARD_SCRIPT" --current "$TEST_TMP/costonly.json"
	[[ "$status" -eq 0 ]]
	[[ "$(printf '%s' "$output" | jq -r '.status')" == "noop" ]]
}

@test "ctg_batch_mt prints nothing for token-less (cost-only) summary" {
	source "$GUARD_SCRIPT"
	jq -n '{cost_summary: {total_cost_usd: 1.23}, progress: {completed: 3}}' \
		> "$TEST_TMP/costonly.json"
	local mt
	mt=$(ctg_batch_mt "$TEST_TMP/costonly.json")
	[[ -z "$mt" ]]
}

@test "advisory: guard exits 0 even with no history and no baseline" {
	_mk_summary "$TEST_TMP/cur/status.json" 5000000 0 5
	run "$GUARD_SCRIPT" --current "$TEST_TMP/cur/status.json"
	[[ "$status" -eq 0 ]]
	# Has a metric but no baseline → ok, warning false, never blocks.
	[[ "$(printf '%s' "$output" | jq -r '.status')" == "ok" ]]
	[[ "$(printf '%s' "$output" | jq -r '.warning')" == "false" ]]
}

# =============================================================================
# REAL SHAPE: exact batch-orchestrator.sh status.json / summary.json end-to-end
#
# These exercise the guard against the EXACT JSON batch-orchestrator.sh now
# writes — an issues[] array plus a batch-level cost_summary rolled up from the
# #580 per-issue token fields. This is the RED→GREEN case: the pre-fix guard
# read total_tokens / input_tokens / output_tokens (field names no producer
# emits) and would derive nothing (noop, empty) from this shape.
# =============================================================================

@test "REAL SHAPE: ctg_batch_mt derives non-zero MT/issue from batch cost_summary" {
	source "$GUARD_SCRIPT"
	_mk_batch_status "$TEST_TMP/status.json"
	local mt
	mt=$(ctg_batch_mt "$TEST_TMP/status.json")
	[[ -n "$mt" ]]                 # must NOT no-op on the real shape
	# 10.5M tokens / 2 completed issues = 5.25 MT/issue.
	[[ "$mt" == "5.250000" ]]
}

@test "REAL SHAPE: ctg_evaluate warns when latest exceeds baseline * factor" {
	# Realistic history: two prior batches at 1.0 MT/issue. Current batch (real
	# full shape) is 5.25 MT/issue > 1.0 * 1.5 → warn.
	_mk_summary "$TEST_TMP/hist/batch-1/summary.json" 1000000 0 1
	_mk_summary "$TEST_TMP/hist/batch-2/summary.json" 1000000 0 1
	_mk_batch_status "$TEST_TMP/cur/status.json"

	run env COST_TREND_FACTOR=1.5 COST_TREND_WINDOW=5 \
		"$GUARD_SCRIPT" --current "$TEST_TMP/cur/status.json" \
		--history-dir "$TEST_TMP/hist"
	[[ "$status" -eq 0 ]]
	[[ "$(printf '%s' "$output" | jq -r '.status')" == "ok" ]]
	[[ "$(printf '%s' "$output" | jq -r '.warning')" == "true" ]]
	[[ "$(printf '%s' "$output" | jq -r '.latest_mt_per_issue')" == "5.250000" ]]
	[[ "$(printf '%s' "$output" | jq -r '.baseline_mt_per_issue')" == "1.000000" ]]
}

# =============================================================================
# WIRING: batch-orchestrator.sh summary + event emission
# =============================================================================

@test "batch-orchestrator invokes cost-trend-guard.sh at batch end" {
	run grep -q 'cost-trend-guard.sh' "$SCRIPT_DIR/batch-orchestrator.sh"
	[[ "$status" -eq 0 ]]
}

@test "batch-orchestrator summary jq adds cost_rollup and trend_warning" {
	local body
	body=$(awk '/Write summary/,/log.*Summary written/' \
		"$SCRIPT_DIR/batch-orchestrator.sh")
	[[ "$body" == *'cost_rollup'* ]]
	[[ "$body" == *'trend_warning'* ]]
}

@test "batch-orchestrator emits cost_trend_warning event on warning" {
	local body
	body=$(awk '/COST\/TOKEN TREND GUARD/,/Write summary/' \
		"$SCRIPT_DIR/batch-orchestrator.sh")
	[[ "$body" == *'emit_event "cost_trend_warning"'* ]]
}

@test "pipeline-event schema includes cost_trend_warning in the enum" {
	run jq -e '.properties.event.enum | index("cost_trend_warning")' \
		"$SCRIPT_DIR/schemas/pipeline-event.json"
	[[ "$status" -eq 0 ]]
}

@test "a cost_trend_warning event validates through event-emit.sh" {
	local emit="$SCRIPT_DIR/event-emit.sh"
	[[ -x "$emit" ]] || skip "event-emit.sh not present"
	local ev='{"ts":"2026-07-21T10:00:00+00:00","run_id":"batch-x","event":"cost_trend_warning","latest_mt_per_issue":2.0,"baseline_mt_per_issue":1.0,"factor":1.5,"window":5}'
	run env LOG_DIR="$TEST_TMP" "$emit" "$ev"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# EPIC-SCOPE PREFLIGHT FLAG (batch-orchestrator.sh)
# =============================================================================

@test "validate_issue_for_processing detects epic-scope (static)" {
	local body
	body=$(_extract_function_body validate_issue_for_processing \
		"$SCRIPT_DIR/batch-orchestrator.sh")
	[[ "$body" == *'_EPIC_SCOPE'* ]]
	[[ "$body" == *'split-first'* ]]
}

@test "batch-orchestrator declares _EPIC_SCOPE and EPIC_SCOPE_MAX_TASKS" {
	run grep -q '^_EPIC_SCOPE=' "$SCRIPT_DIR/batch-orchestrator.sh"
	[[ "$status" -eq 0 ]]
	run grep -q 'EPIC_SCOPE_MAX_TASKS=' "$SCRIPT_DIR/batch-orchestrator.sh"
	[[ "$status" -eq 0 ]]
}

# --- Functional: epic label routes to split-first (skip) ---

# Source validate_issue_for_processing in isolation (mirrors the helper in
# test-batch-orchestrator.bats).
_source_validate() {
	local lib="$SCRIPT_DIR/issue-body-lib.sh"
	[[ -f "$lib" ]] || return 1
	# shellcheck disable=SC1090
	source "$lib"
	local func_file="$TEST_TMP/validate_issue_for_processing.bash"
	_extract_function_body validate_issue_for_processing \
		"$SCRIPT_DIR/batch-orchestrator.sh" > "$func_file"
	grep -q 'validate_issue_for_processing' "$func_file" 2>/dev/null || return 1
	# shellcheck disable=SC1090
	source "$func_file"
}

@test "functional: epic label flags _EPIC_SCOPE and skips" {
	local mock_bin="$TEST_TMP/mock-bin"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' '{"body":"## Implementation Tasks\n- [ ] do a thing","labels":[{"name":"epic"}]}'
GHEOF
	chmod +x "$mock_bin/gh"
	export PATH="$mock_bin:$PATH"

	_source_validate || skip "validate_issue_for_processing not present"
	log()                  { :; }
	log_warn()             { :; }
	dispatch_composition() { return 1; }
	export ENRICH_FOLLOWUPS=false
	EPIC_SCOPE_MAX_TASKS=20

	_SKIP_REASON=""
	_EPIC_SCOPE=""
	local rc=0
	validate_issue_for_processing 42 || rc=$?

	[[ "$rc" -eq 1 ]]
	[[ -n "$_EPIC_SCOPE" ]]
	[[ "$_SKIP_REASON" == *"epic-scope"* ]]
}

@test "functional: oversized body (checkbox count) flags epic-scope" {
	local mock_bin="$TEST_TMP/mock-bin"
	mkdir -p "$mock_bin"
	# Body with 4 checkboxes; threshold lowered to 3 to trigger.
	cat > "$mock_bin/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' '{"body":"## Implementation Tasks\n- [ ] a\n- [ ] b\n- [ ] c\n- [ ] d","labels":[]}'
GHEOF
	chmod +x "$mock_bin/gh"
	export PATH="$mock_bin:$PATH"

	_source_validate || skip "validate_issue_for_processing not present"
	log()                  { :; }
	log_warn()             { :; }
	dispatch_composition() { return 1; }
	export ENRICH_FOLLOWUPS=false
	EPIC_SCOPE_MAX_TASKS=3

	_SKIP_REASON=""
	_EPIC_SCOPE=""
	local rc=0
	validate_issue_for_processing 43 || rc=$?

	[[ "$rc" -eq 1 ]]
	[[ "$_EPIC_SCOPE" == *"oversized body"* ]]
}

@test "functional: normal issue is NOT flagged epic-scope" {
	local mock_bin="$TEST_TMP/mock-bin"
	mkdir -p "$mock_bin"
	# A well-formed non-epic issue with a couple of tasks and ACs.
	cat > "$mock_bin/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' '{"body":"## Implementation Tasks\n- [ ] `[default]` do a thing — file.sh\n\n## Acceptance Criteria\n- [ ] it works","labels":[]}'
GHEOF
	chmod +x "$mock_bin/gh"
	export PATH="$mock_bin:$PATH"

	_source_validate || skip "validate_issue_for_processing not present"
	log()                  { :; }
	log_warn()             { :; }
	dispatch_composition() { return 1; }
	assert_issue_valid()   { return 0; }
	export ENRICH_FOLLOWUPS=false
	EPIC_SCOPE_MAX_TASKS=20

	_SKIP_REASON=""
	_EPIC_SCOPE=""
	local rc=0
	validate_issue_for_processing 44 || rc=$?

	[[ "$rc" -eq 0 ]]
	[[ -z "$_EPIC_SCOPE" ]]
}
