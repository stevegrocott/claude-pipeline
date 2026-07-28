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

# =============================================================================
# RECONCILIATION + OUTCOME-INDEPENDENT ROLLUP (issue #617)
# =============================================================================
#
# #580 shipped cost_summary but only set_stage_completed ever wrote
# .stages[].estimated_cost, so FAILED stages and the TRIAGE stage contributed
# nothing.  On run issue-614-20260726-153711 that under-reported the run by
# ~51% ($3.70 recorded vs $7.63 spent).  #580 also left .stages[] split across
# two key conventions — run_stage wrote `model` under implement_task_2 while
# the failure writer wrote `status` under implement-task-2 — so model and
# outcome could never be joined.
#
# The helpers below `exit 1` rather than `return 1`: BATS only honours the
# FINAL command's status, so a `return 1` assertion in the middle of a test
# body is silently dropped (see HARD ASSERTIONS in helpers/test-helper.bash).

_x_fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

_expect_eq() {
	local actual="$1" expected="$2" label="${3:-value}"
	[[ "$actual" == "$expected" ]] \
		|| _x_fail "$label: expected '$expected', got '$actual'"
}

# Assert |actual - expected| / expected <= 5% — the reconciliation tolerance
# #580's own acceptance criteria named and #617 found violated by ~51%.
_expect_within_5pct() {
	local actual="$1" expected="$2" label="${3:-cost reconciliation}"
	awk -v a="$actual" -v e="$expected" '
		BEGIN {
			if (e == 0) { exit !(a == 0) }
			d = a - e
			if (d < 0) { d = -d }
			exit !((d / e) <= 0.05)
		}' \
		|| _x_fail "$label drifted more than 5% (got: $actual, expected: $expected)"
}

# Append one run_stage envelope's spend to a logical stage's accumulator the
# same way _apply_stage_action does from inside the run_stage subshell.
_seed_stage_spend() {
	local logical="$1" call_stage="$2" cost="$3"
	local in_tok="${4:-1000}" out_tok="${5:-500}"
	_STAGE_ACC_CURRENT="$logical"
	_RUN_STAGE_NAME="$call_stage"
	_stage_acc_add "$(jq -nc \
		--argjson i "$in_tok" \
		--argjson o "$out_tok" \
		--argjson c "$cost" \
		'{tokens: {input_tokens: $i, output_tokens: $o,
		           cache_creation_input_tokens: 0,
		           cache_read_input_tokens: 0},
		  cost: {estimated_usd: $c}}')"
}

@test "a failed stage contributes its cost to cost_summary" {
	_setup_orchestrator_env
	init_status

	set_stage_started "test_loop"
	_seed_stage_spend "test_loop" "test_loop" 1.3836
	set_stage_failed "test_loop" "structured_error"

	local stage_cost total_cost stage_status
	stage_cost=$(jq -r '.stages.test_loop.estimated_cost // 0' "$STATUS_FILE")
	total_cost=$(jq -r '.cost_summary.total_cost_usd' "$STATUS_FILE")
	stage_status=$(jq -r '.stages.test_loop.status' "$STATUS_FILE")

	_expect_eq "$stage_status" "error" "failed stage status"
	_expect_within_5pct "$stage_cost" "1.3836" "failed stage estimated_cost"
	_expect_within_5pct "$total_cost" "1.3836" "cost_summary after a failed stage"
}

@test "a failed stage's tokens reach cost_summary token totals" {
	_setup_orchestrator_env
	init_status

	set_stage_started "implement"
	_seed_stage_spend "implement" "implement" 1.50 12000 3400
	set_stage_failed "implement" "structured_error"

	local total_in total_out
	total_in=$(jq -r '.cost_summary.total_input_tokens' "$STATUS_FILE")
	total_out=$(jq -r '.cost_summary.total_output_tokens' "$STATUS_FILE")

	_expect_eq "$total_in" "12000" "cost_summary.total_input_tokens"
	_expect_eq "$total_out" "3400" "cost_summary.total_output_tokens"
}

@test "cost_summary reconciles with summed per-stage cost within 5%" {
	_setup_orchestrator_env
	init_status

	# A run that spends in three places: a stage that completes, a stage that
	# FAILS, and the triage stage.  All three are real money.  Ground truth
	# for this run is 2.00 + 1.50 + 0.45 = 3.95.
	set_stage_started "parse_issue"
	_seed_stage_spend "parse_issue" "parse_issue" 2.00
	set_stage_completed "parse_issue"

	set_stage_started "implement"
	_seed_stage_spend "implement" "implement" 1.50
	set_stage_failed "implement" "structured_error"

	set_stage_completed "triage" \
		'{"input_tokens":1000,"output_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}' \
		"0.45"

	export_metrics

	local summary_total stage_total
	summary_total=$(jq -r '.cost_summary.total_cost_usd' "$LOG_BASE/metrics.json")
	stage_total=$(jq -r '[.stages[]?.estimated_cost // 0] | add // 0' \
		"$LOG_BASE/metrics.json")

	# Internal: the run-level rollup must equal the sum of the stage entries.
	_expect_within_5pct "$summary_total" "$stage_total" \
		"cost_summary vs summed per-stage estimated_cost"
	# External: and neither may silently drop a stage's spend.
	_expect_within_5pct "$summary_total" "3.95" \
		"cost_summary vs ground-truth run spend"
}

@test "hyphenated stage names collapse onto the canonical underscore key" {
	_setup_orchestrator_env
	init_status
	# run_stage records the resolved model under the underscore key.
	jq '.stages.implement_task_2 = {model: "sonnet", status: "pending"}' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	set_stage_failed "implement-task-2" "structured_error"

	local has_hyphen stage_status stage_model
	has_hyphen=$(jq -r '.stages | has("implement-task-2")' "$STATUS_FILE")
	stage_status=$(jq -r '.stages.implement_task_2.status // "MISSING"' "$STATUS_FILE")
	stage_model=$(jq -r '.stages.implement_task_2.model // "MISSING"' "$STATUS_FILE")

	_expect_eq "$has_hyphen" "false" "hyphenated stage key must not be written"
	_expect_eq "$stage_status" "error" "status must land on the canonical key"
	_expect_eq "$stage_model" "sonnet" "model must survive on the canonical key"
}

@test "update_stage and set_stage_started also use the canonical stage key" {
	_setup_orchestrator_env
	init_status

	set_stage_started "fix-review-quality-iter-1"
	update_stage "fix-review-quality-iter-1" completed route full

	local has_hyphen stage_status stage_route
	has_hyphen=$(jq -r '.stages | has("fix-review-quality-iter-1")' "$STATUS_FILE")
	stage_status=$(jq -r '.stages.fix_review_quality_iter_1.status // "MISSING"' \
		"$STATUS_FILE")
	stage_route=$(jq -r '.stages.fix_review_quality_iter_1.route // "MISSING"' \
		"$STATUS_FILE")

	_expect_eq "$has_hyphen" "false" "hyphenated stage key must not be written"
	_expect_eq "$stage_status" "completed" "update_stage status"
	_expect_eq "$stage_route" "full" "update_stage extra field"
}

@test "a task-level stage records model, status, tokens and estimated_cost together" {
	_setup_orchestrator_env
	init_status

	_STAGE_ACC_CURRENT="implement"
	_RUN_STAGE_NAME="implement-task-3"
	local stage_result
	stage_result=$(jq -nc '{
		status: "error",
		model: "sonnet",
		error_kind: "structured_error",
		tokens: {input_tokens: 41000, output_tokens: 2600,
		         cache_creation_input_tokens: 0, cache_read_input_tokens: 0},
		cost: {estimated_usd: 2.0973}
	}')
	_apply_stage_action "$stage_result" "bail" "test" >/dev/null || true

	local model status tokens_in cost
	model=$(jq -r '.stages.implement_task_3.model // "MISSING"' "$STATUS_FILE")
	status=$(jq -r '.stages.implement_task_3.status // "MISSING"' "$STATUS_FILE")
	tokens_in=$(jq -r '.stages.implement_task_3.tokens.input_tokens // "MISSING"' \
		"$STATUS_FILE")
	cost=$(jq -r '.stages.implement_task_3.estimated_cost // 0' "$STATUS_FILE")

	_expect_eq "$model" "sonnet" "task-level stage model"
	_expect_eq "$status" "error" "task-level stage status"
	_expect_eq "$tokens_in" "41000" "task-level stage tokens"
	_expect_within_5pct "$cost" "2.0973" "task-level stage estimated_cost"
}

@test "no .stages[] entry carries a model without status, tokens and estimated_cost" {
	_setup_orchestrator_env
	init_status

	_STAGE_ACC_CURRENT="implement"
	_RUN_STAGE_NAME="implement-task-1"
	_apply_stage_action \
		'{"status":"success","model":"haiku","error_kind":null,"tokens":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"cost":{"estimated_usd":0.01}}' \
		"accept" >/dev/null || true
	_RUN_STAGE_NAME="implement-task-2"
	_apply_stage_action \
		'{"status":"error","model":"sonnet","error_kind":"structured_error","tokens":{"input_tokens":20,"output_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"cost":{"estimated_usd":0.02}}' \
		"bail" "test" >/dev/null || true

	local with_model incomplete
	with_model=$(jq -r '[.stages[]? | select(.model != null)] | length' \
		"$STATUS_FILE")
	incomplete=$(jq -r '[.stages | to_entries[]
		| select(.value.model != null)
		| select((.value.status == null) or (.value.status == "pending")
		         or (.value.tokens == null) or (.value.estimated_cost == null))
		| .key] | join(",")' "$STATUS_FILE")

	# Guard against a vacuous pass: both dispatched stages must be recorded.
	_expect_eq "$with_model" "2" "stages carrying a model"
	_expect_eq "$incomplete" "" "stages carrying a model but no outcome/spend"
}

@test "task-level and aggregate stages never double-count the same spend" {
	_setup_orchestrator_env
	init_status

	# Two run_stage calls (one accepted, one bailed) under the "implement"
	# logical stage.  Their spend is attributed to implement_task_1 /
	# implement_task_2; set_stage_completed "implement" must NOT also roll the
	# same dollars onto .stages.implement.  Ground truth: 1.00 + 2.00 = 3.00.
	set_stage_started "implement"
	_RUN_STAGE_NAME="implement-task-1"
	_apply_stage_action \
		'{"status":"success","model":"sonnet","error_kind":null,"tokens":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"cost":{"estimated_usd":1.00}}' \
		"accept" >/dev/null || true
	_RUN_STAGE_NAME="implement-task-2"
	_apply_stage_action \
		'{"status":"error","model":"opus","error_kind":"structured_error","tokens":{"input_tokens":200,"output_tokens":80,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"cost":{"estimated_usd":2.00}}' \
		"bail" "test" >/dev/null || true
	set_stage_completed "implement"

	export_metrics

	local total total_in phase_cost phase_flag task1 task2
	total=$(jq -r '.cost_summary.total_cost_usd' "$LOG_BASE/metrics.json")
	total_in=$(jq -r '.cost_summary.total_input_tokens' "$LOG_BASE/metrics.json")
	phase_cost=$(jq -r '.stages.implement.estimated_cost' "$LOG_BASE/metrics.json")
	phase_flag=$(jq -r '.stages.implement.cost_is_aggregate' "$LOG_BASE/metrics.json")
	task1=$(jq -r '.stages.implement_task_1.estimated_cost' "$LOG_BASE/metrics.json")
	task2=$(jq -r '.stages.implement_task_2.estimated_cost' "$LOG_BASE/metrics.json")

	_expect_within_5pct "$total" "3.00" "cost_summary must count each dollar once"
	_expect_eq "$total_in" "300" "cost_summary must count each token once"
	# #580's contract still holds: the phase entry reports the whole phase...
	_expect_within_5pct "$phase_cost" "3.00" "implement phase total"
	# ...and is flagged so the rollup itemises via the per-call entries instead.
	_expect_eq "$phase_flag" "true" "implement must be flagged cost_is_aggregate"
	_expect_within_5pct "$task1" "1.00" "implement_task_1 estimated_cost"
	_expect_within_5pct "$task2" "2.00" "implement_task_2 estimated_cost"
}

@test "the triage stage records its spend in cost_summary" {
	_setup_orchestrator_env
	init_status
	printf 'issue body\n' > "$LOG_BASE/context/issue-body.md"

	build_triage_prompt() { printf 'triage prompt'; }
	_run_triage_composition() {
		printf '%s\n' '{"structured_output":{"route":"full","confidence":"high"},"usage":{"input_tokens":120000,"output_tokens":800,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"total_cost_usd":0.4479}'
	}

	run_triage_stage >/dev/null

	local stage_cost total_cost
	stage_cost=$(jq -r '.stages.triage.estimated_cost // 0' "$STATUS_FILE")
	total_cost=$(jq -r '.cost_summary.total_cost_usd' "$STATUS_FILE")

	_expect_within_5pct "$stage_cost" "0.4479" "triage stage estimated_cost"
	_expect_within_5pct "$total_cost" "0.4479" "cost_summary after triage"
}
