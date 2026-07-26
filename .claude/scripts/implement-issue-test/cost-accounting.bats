#!/usr/bin/env bats
#
# cost-accounting.bats
# Tests for per-stage/run-level token & cost accounting (issue #580).
#
# Covers:
#   - _model_cost() pricing math in model-config.sh
#   - run-level cost_summary seeded by init_status()
#   - per-stage tokens/estimated_cost persisted on the stages[] entries
#   - export_metrics() rolling cost_summary into metrics.json
#   - batch-orchestrator.sh cost_summary rollup across issues
#
# Pricing reference (per-million-token, USD) at time of writing:
#   haiku (claude-haiku-4-5):  $1.00 input  / $5.00 output
#   sonnet (claude-sonnet-5):  $3.00 input  / $15.00 output
#   opus (claude-opus-4-8):    $5.00 input  / $25.00 output
# Cache pricing follows the standard Anthropic multipliers on the model's
# input price: cache read = 0.1x, cache write (ephemeral/5m) = 1.25x.
#
# _model_cost() and the cost_summary/tokens/estimated_cost plumbing do not
# exist yet — this file encodes the target contract from issue #580 so the
# implementation (tracked as separate tasks in the same issue) has an
# executable spec to satisfy.
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env
	MODEL_CONFIG="$SCRIPT_DIR/model-config.sh"
}

teardown() {
	teardown_test_env
}

# Compare two decimal strings for equality within a small tolerance so the
# tests don't depend on the exact string formatting (e.g. "1" vs "1.00" vs
# "1.000000") a future implementation might choose.
assert_cost_equals() {
	local actual="$1" expected="$2" msg="${3:-cost should equal $expected}"
	awk -v a="$actual" -v e="$expected" \
		'BEGIN { diff = a - e; if (diff < 0) diff = -diff; exit !(diff < 0.0005) }' \
		|| fail "$msg (got: $actual, expected: $expected)"
}

run_with_config() {
	run bash -c "source '$MODEL_CONFIG' && $1"
}

# =============================================================================
# _model_cost() — PRICING MATH (model-config.sh)
# =============================================================================

@test "_model_cost is defined after sourcing model-config.sh" {
	run_with_config 'type _model_cost'
	[ "$status" -eq 0 ]
	[[ "$output" == *"function"* ]]
}

@test "_model_cost haiku input-only tokens at \$1.00/MTok" {
	run_with_config '_model_cost haiku 1000000 0'
	[ "$status" -eq 0 ]
	assert_cost_equals "$output" "1.00"
}

@test "_model_cost haiku output-only tokens at \$5.00/MTok" {
	run_with_config '_model_cost haiku 0 1000000'
	[ "$status" -eq 0 ]
	assert_cost_equals "$output" "5.00"
}

@test "_model_cost sonnet input-only tokens at \$3.00/MTok" {
	run_with_config '_model_cost sonnet 1000000 0'
	[ "$status" -eq 0 ]
	assert_cost_equals "$output" "3.00"
}

@test "_model_cost sonnet output-only tokens at \$15.00/MTok" {
	run_with_config '_model_cost sonnet 0 1000000'
	[ "$status" -eq 0 ]
	assert_cost_equals "$output" "15.00"
}

@test "_model_cost opus input-only tokens at \$5.00/MTok" {
	run_with_config '_model_cost opus 1000000 0'
	[ "$status" -eq 0 ]
	assert_cost_equals "$output" "5.00"
}

@test "_model_cost opus output-only tokens at \$25.00/MTok" {
	run_with_config '_model_cost opus 0 1000000'
	[ "$status" -eq 0 ]
	assert_cost_equals "$output" "25.00"
}

@test "_model_cost sums input and output cost for the same call" {
	run_with_config '_model_cost sonnet 1000000 1000000'
	[ "$status" -eq 0 ]
	assert_cost_equals "$output" "18.00"
}

@test "_model_cost returns zero for zero tokens" {
	run_with_config '_model_cost haiku 0 0'
	[ "$status" -eq 0 ]
	assert_cost_equals "$output" "0"
}

@test "_model_cost scales linearly with token count" {
	run_with_config '_model_cost opus 500000 0'
	[ "$status" -eq 0 ]
	assert_cost_equals "$output" "2.50"
}

@test "_model_cost prices cache read tokens at 0.1x the input price" {
	# Signature: _model_cost <model> <input> <output> <cache_creation> <cache_read>
	# sonnet: 1M cache-read tokens (arg5) -> 0.1 * $3.00 = $0.30
	run_with_config '_model_cost sonnet 0 0 0 1000000'
	[ "$status" -eq 0 ]
	assert_cost_equals "$output" "0.30"
}

@test "_model_cost prices cache creation tokens at 1.25x the input price" {
	# Signature: _model_cost <model> <input> <output> <cache_creation> <cache_read>
	# sonnet: 1M cache-write/creation tokens (arg4) -> 1.25 * $3.00 = $3.75
	run_with_config '_model_cost sonnet 0 0 1000000 0'
	[ "$status" -eq 0 ]
	assert_cost_equals "$output" "3.75"
}

@test "_model_cost combines input, output, cache-read and cache-creation tokens" {
	# sonnet, 1M of each: 3.00 (input) + 0 (output) + 0.30 (cache read) + 3.75 (cache write)
	run_with_config '_model_cost sonnet 1000000 0 1000000 1000000'
	[ "$status" -eq 0 ]
	assert_cost_equals "$output" "7.05"
}

@test "_model_cost returns a safe non-negative fallback for an unknown model" {
	run_with_config '_model_cost totally-unknown-model 1000000 1000000'
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "expected a plain non-negative number, got: $output"
}

@test "_model_cost output is a single line with no extra whitespace" {
	run_with_config '_model_cost haiku 1000 1000 | wc -l'
	[ "$status" -eq 0 ]
	[[ "${output// /}" == "1" ]]
}

# =============================================================================
# RUN-LEVEL cost_summary — init_status() SKELETON (implement-issue-orchestrator.sh)
# =============================================================================

_setup_orchestrator_env() {
	export ISSUE_NUMBER=123
	export BASE_BRANCH=test
	export STATUS_FILE="$TEST_TMP/status.json"
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	export STAGE_COUNTER=0
	mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"
	source_orchestrator_functions
}

@test "init_status seeds a top-level cost_summary object" {
	_setup_orchestrator_env
	init_status
	local cost_summary_type
	cost_summary_type=$(jq -r '.cost_summary | type' "$STATUS_FILE")
	[ "$cost_summary_type" = "object" ]
}

@test "init_status seeds cost_summary totals at zero" {
	_setup_orchestrator_env
	init_status
	local total_cost total_input total_output
	total_cost=$(jq -r '.cost_summary.total_cost_usd' "$STATUS_FILE")
	total_input=$(jq -r '.cost_summary.total_input_tokens' "$STATUS_FILE")
	total_output=$(jq -r '.cost_summary.total_output_tokens' "$STATUS_FILE")
	assert_cost_equals "$total_cost" "0"
	[ "$total_input" = "0" ]
	[ "$total_output" = "0" ]
}

# =============================================================================
# PER-STAGE tokens/estimated_cost — set_stage_completed() (implement-issue-orchestrator.sh)
# =============================================================================

@test "set_stage_completed with no token args still marks the stage completed (backward compatible)" {
	_setup_orchestrator_env
	init_status
	set_stage_completed "setup"
	local status
	status=$(jq -r '.stages.setup.status' "$STATUS_FILE")
	[ "$status" = "completed" ]
}

@test "set_stage_completed persists a tokens object on the stage entry" {
	_setup_orchestrator_env
	init_status
	local tokens='{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
	set_stage_completed "implement" "$tokens" "0.00105"

	local input_tokens output_tokens
	input_tokens=$(jq -r '.stages.implement.tokens.input_tokens' "$STATUS_FILE")
	output_tokens=$(jq -r '.stages.implement.tokens.output_tokens' "$STATUS_FILE")
	[ "$input_tokens" = "100" ]
	[ "$output_tokens" = "50" ]
}

@test "set_stage_completed persists estimated_cost as a number on the stage entry" {
	_setup_orchestrator_env
	init_status
	local tokens='{"input_tokens":100,"output_tokens":50}'
	set_stage_completed "implement" "$tokens" "0.00105"

	local cost_type estimated_cost
	cost_type=$(jq -r '.stages.implement.estimated_cost | type' "$STATUS_FILE")
	estimated_cost=$(jq -r '.stages.implement.estimated_cost' "$STATUS_FILE")
	[ "$cost_type" = "number" ]
	assert_cost_equals "$estimated_cost" "0.00105"
}

# =============================================================================
# export_metrics() ROLLS cost_summary INTO metrics.json
# =============================================================================

@test "export_metrics carries the run-level cost_summary through to metrics.json" {
	_setup_orchestrator_env
	init_status
	jq '.cost_summary = {
			total_input_tokens: 1000,
			total_output_tokens: 500,
			total_cache_read_tokens: 0,
			total_cache_creation_tokens: 0,
			total_cost_usd: 1.23
		}' "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	export_metrics

	local total_cost
	total_cost=$(jq -r '.cost_summary.total_cost_usd' "$LOG_BASE/metrics.json")
	assert_cost_equals "$total_cost" "1.23"
}

@test "export_metrics carries per-stage tokens/estimated_cost through to metrics.json" {
	_setup_orchestrator_env
	init_status
	jq '.stages.implement.tokens = {input_tokens: 100, output_tokens: 50} |
	    .stages.implement.estimated_cost = 0.00105 |
	    .stages.implement.started_at = "2024-01-01T10:00:00Z" |
	    .stages.implement.completed_at = "2024-01-01T10:00:30Z"' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	export_metrics

	local input_tokens estimated_cost
	input_tokens=$(jq -r '.stages.implement.tokens.input_tokens' "$LOG_BASE/metrics.json")
	estimated_cost=$(jq -r '.stages.implement.estimated_cost' "$LOG_BASE/metrics.json")
	[ "$input_tokens" = "100" ]
	assert_cost_equals "$estimated_cost" "0.00105"
}

@test "export_metrics rolls per-stage tokens/cost up into cost_summary totals" {
	_setup_orchestrator_env
	init_status
	# Two completed stages carrying tokens + estimated_cost, but no run-level
	# cost_summary was ever accumulated (init_status seeds it at zero). The
	# rollup in export_metrics must sum the per-stage figures.
	jq '.stages.implement.tokens = {input_tokens: 100, output_tokens: 50, cache_read_input_tokens: 10, cache_creation_input_tokens: 5} |
	    .stages.implement.estimated_cost = 0.00105 |
	    .stages.review.tokens = {input_tokens: 200, output_tokens: 25, cache_read_input_tokens: 0, cache_creation_input_tokens: 0} |
	    .stages.review.estimated_cost = 0.00042' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	export_metrics

	local total_input total_output total_cache_read total_cache_creation total_cost
	total_input=$(jq -r '.cost_summary.total_input_tokens' "$LOG_BASE/metrics.json")
	total_output=$(jq -r '.cost_summary.total_output_tokens' "$LOG_BASE/metrics.json")
	total_cache_read=$(jq -r '.cost_summary.total_cache_read_tokens' "$LOG_BASE/metrics.json")
	total_cache_creation=$(jq -r '.cost_summary.total_cache_creation_tokens' "$LOG_BASE/metrics.json")
	total_cost=$(jq -r '.cost_summary.total_cost_usd' "$LOG_BASE/metrics.json")
	[ "$total_input" = "300" ]
	[ "$total_output" = "75" ]
	[ "$total_cache_read" = "10" ]
	[ "$total_cache_creation" = "5" ]
	assert_cost_equals "$total_cost" "0.00147"
}

# =============================================================================
# RECONCILIATION — summed per-stage cost vs cost_summary.total_cost_usd (±5%)
# =============================================================================
#
# Issue #617: cost_summary under-reported run cost by ~51% because failed and
# triage stages never had estimated_cost recorded on them, so the rollup
# silently excluded exactly the spend #580 existed to make visible. This is
# the regression guard called for by #617's acceptance criteria: sum whatever
# estimated_cost every .stages[] entry carries (regardless of status) and
# fail loudly — naming both figures and the percent drift — if that sum
# diverges from cost_summary.total_cost_usd by more than the tolerance.

# Sums .stages[*].estimated_cost in $1 (a metrics.json/status.json-shaped
# file) and fails loudly if that sum diverges from .cost_summary.total_cost_usd
# by more than $2 percent (default 5).
assert_cost_reconciles() {
	local metrics_file="$1" tolerance_pct="${2:-5}"
	local stage_sum summary_total pct
	stage_sum=$(jq -r '[.stages[]?.estimated_cost // 0] | add // 0' "$metrics_file")
	summary_total=$(jq -r '.cost_summary.total_cost_usd // 0' "$metrics_file")
	pct=$(awk -v a="$stage_sum" -v b="$summary_total" \
		'BEGIN { d = a - b; if (d < 0) d = -d; base = (a == 0) ? 1 : a; printf "%.4f", (d / base) * 100 }')

	awk -v pct="$pct" -v tol="$tolerance_pct" 'BEGIN { exit !(pct <= tol) }' \
		|| fail "cost_summary.total_cost_usd ($summary_total) drifts ${pct}% from the summed per-stage estimated_cost ($stage_sum) — exceeds the ±${tolerance_pct}% reconciliation tolerance"
}

@test "cost_summary reconciles with summed per-stage cost within 5%, including a failed stage and triage" {
	_setup_orchestrator_env
	init_status
	# Mirrors the issue #617 ground-truth shape: a failed task stage and the
	# triage stage each carry their own estimated_cost, not just the
	# successfully completed stages.
	jq '.stages.triage = {status: "completed", estimated_cost: 0.4479} |
	    .stages.implement_task_1 = {status: "completed", estimated_cost: 0.9562} |
	    .stages.implement_task_2 = {status: "error", estimated_cost: 1.3836} |
	    .stages.implement_task_3 = {status: "error", estimated_cost: 2.0973} |
	    .stages.pr = {status: "completed", estimated_cost: 0.4144}' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	export_metrics

	assert_cost_reconciles "$LOG_BASE/metrics.json"
}

@test "reconciliation check fails loudly when cost_summary drifts more than 5% from summed per-stage cost" {
	_setup_orchestrator_env
	init_status
	jq '.stages.triage = {status: "completed", estimated_cost: 0.4479} |
	    .stages.implement_task_1 = {status: "completed", estimated_cost: 0.9562} |
	    .stages.implement_task_2 = {status: "error", estimated_cost: 1.3836} |
	    .stages.implement_task_3 = {status: "error", estimated_cost: 2.0973} |
	    .stages.pr = {status: "completed", estimated_cost: 0.4144}' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	export_metrics

	# Reproduce the #617 defect directly on metrics.json: cost_summary only
	# counted the non-failed stages (0.4479 + 0.9562 + 0.4144 = 1.8185),
	# ~51% below the full per-stage sum (5.2994) computed above — the same
	# under-report ratio the issue measured on the real run.
	jq '.cost_summary.total_cost_usd = 1.8185' \
		"$LOG_BASE/metrics.json" > "$LOG_BASE/metrics.json.tmp" && mv "$LOG_BASE/metrics.json.tmp" "$LOG_BASE/metrics.json"

	run assert_cost_reconciles "$LOG_BASE/metrics.json"
	[ "$status" -ne 0 ]
	[[ "$output" == *"drifts"* ]]
	[[ "$output" == *"reconciliation tolerance"* ]]
}

# =============================================================================
# FAILED-STAGE COST — bail path must still persist cost onto the stage
# =============================================================================
#
# Issue #617: the reconciliation tests above hand-craft a status.json with
# estimated_cost already present on the "error" stages, which only proves
# export_metrics'"'"'s rollup is status-agnostic (it always was). It does not
# prove a real failing run ever gets that estimated_cost onto the stage entry
# in the first place. In production a failing run_stage attempt is routed
# through _apply_stage_action's "bail" branch, which calls set_stage_failed
# with only the stage name + error_kind — never the stage_result's
# tokens/cost, unlike the "accept" branch which threads tokens/cost onto the
# stage via _stage_acc_add. This is the actual source of #617's ~51%
# under-report: a bailed stage's own spend never reaches cost_summary. This
# test drives the real bail path end-to-end and must fail until that gap is
# closed.

@test "a stage that bails still persists its cost so cost_summary includes it" {
	_setup_orchestrator_env
	init_status
	set_stage_started "implement_task_2"

	local stage_result
	stage_result=$(jq -n '{
		status: "error",
		error_kind: "error_max_turns",
		tokens: {input_tokens: 500000, output_tokens: 200000,
		         cache_creation_input_tokens: 0, cache_read_input_tokens: 0},
		cost: {reported_usd: 1.3836, computed_usd: 1.3836, estimated_usd: 1.3836}
	}')

	_RUN_STAGE_NAME="implement_task_2"
	run _apply_stage_action "$stage_result" "bail" "max turns exceeded"
	[ "$status" -eq 1 ]

	export_metrics

	local stage_status total_cost
	stage_status=$(jq -r '.stages.implement_task_2.status' "$LOG_BASE/metrics.json")
	total_cost=$(jq -r '.cost_summary.total_cost_usd' "$LOG_BASE/metrics.json")
	[ "$stage_status" = "error" ]
	assert_cost_equals "$total_cost" "1.3836" \
		"a bailed stage's cost must still reach cost_summary.total_cost_usd"
}

# =============================================================================
# BATCH-LEVEL cost_summary ROLLUP (batch-orchestrator.sh)
# =============================================================================
#
# Mirrors the existing static-analysis style used elsewhere in
# test-batch-orchestrator.bats: extract the update_progress() function body
# and assert its jq filter assigns a cost_summary rollup, then verify the
# rollup math independently via a jq simulation of the target filter.

@test "update_progress jq filter assigns a cost_summary field" {
	local body
	body=$(awk '/^update_progress\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT_PATH")
	[[ "$body" == *"cost_summary"* ]] || fail "update_progress() does not populate cost_summary yet"
}

# Simulates the target rollup filter: sum each issue's cost_usd field into a
# batch-level cost_summary.total_cost_usd. This is the oracle the real
# update_progress() jq filter must match once implemented.
_simulate_cost_summary_rollup() {
	local status_file="$1"
	jq '.cost_summary.total_cost_usd = ([.issues[].cost_usd // 0] | add)' "$status_file"
}

@test "cost_summary rollup sums per-issue cost_usd across the batch" {
	local status_file="$TEST_TMP/batch-status.json"
	jq -n '{
		issues: [
			{number: "1", status: "completed", cost_usd: 0.50},
			{number: "2", status: "completed", cost_usd: 1.25},
			{number: "3", status: "in_progress", cost_usd: 0.10}
		]
	}' > "$status_file"

	local total
	total=$(_simulate_cost_summary_rollup "$status_file" | jq -r '.cost_summary.total_cost_usd')
	assert_cost_equals "$total" "1.85"
}

@test "cost_summary rollup treats missing per-issue cost_usd as zero" {
	local status_file="$TEST_TMP/batch-status.json"
	jq -n '{
		issues: [
			{number: "1", status: "pending"},
			{number: "2", status: "completed", cost_usd: 2.00}
		]
	}' > "$status_file"

	local total
	total=$(_simulate_cost_summary_rollup "$status_file" | jq -r '.cost_summary.total_cost_usd')
	assert_cost_equals "$total" "2.00"
}
