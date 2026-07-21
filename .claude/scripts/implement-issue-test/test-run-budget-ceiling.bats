#!/usr/bin/env bats
#
# test-run-budget-ceiling.bats
# Tests for the per-run and per-batch token/cost budget ceiling + circuit
# breaker (issue #583).
#
# Covers:
#   - check_run_budget(): disabled by default, hard breach (token & cost),
#     soft-threshold one-shot warning — implement-issue-orchestrator.sh
#   - set_run_budget_exceeded(): writes the terminal budget_exceeded state
#   - set_final_state(): refuses to overwrite a budget_exceeded halt
#   - _apply_stage_action(): a hard breach halts the run with budget_exceeded
#     and OVERRIDES escalate/retry (never escalates or retries)
#   - check_batch_budget(): disabled by default, hard breach, soft warning —
#     batch-orchestrator.sh
#   - batch header/config documents the budget_exceeded state + exit code
#
# The budget check reuses issue #580's per-stage accounting: it sums the
# .stages[].tokens / .stages[].estimated_cost already persisted in status.json
# rather than re-parsing the CLI JSON, so the fixtures below seed those fields.
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env
	WARN_LOG="$TEST_TMP/warn.log"
	: > "$WARN_LOG"
	STATUS_FILE="$TEST_TMP/status.json"

	# Leaf collaborators the extracted functions call. log_warn/log_error
	# append their (space-joined) message as one line so "warned once" is a
	# simple line count.
	log()                { :; }
	log_warn()           { printf '%s\n' "$*" >> "$WARN_LOG"; }
	log_error()          { printf '%s\n' "$*" >> "$WARN_LOG"; }
	emit_event()         { :; }
	sync_status_to_log() { :; }
	set_stage_failed()   { :; }
}

teardown() {
	teardown_test_env
}

# Extract the named orchestrator budget functions (plus their collaborators
# under test) into one file and source them in the current shell.
_source_orch_budget_fns() {
	local out="$TEST_TMP/orch_budget_fns.bash"
	: > "$out"
	local fn
	for fn in check_run_budget set_run_budget_exceeded set_final_state _apply_stage_action; do
		_extract_function_body "$fn" "$ORCHESTRATOR_SCRIPT" >> "$out"
		printf '\n' >> "$out"
	done
	# shellcheck disable=SC1090
	source "$out"
}

_source_batch_budget_fn() {
	local out="$TEST_TMP/batch_budget_fn.bash"
	_extract_function_body check_batch_budget \
		"$BATCH_ORCHESTRATOR_SCRIPT_PATH" > "$out"
	grep -q 'check_batch_budget' "$out" || return 1
	# shellcheck disable=SC1090
	source "$out"
}

# Seed a status.json whose per-stage tokens/estimated_cost sum to the given
# totals. $1 = total tokens (split into input/output), $2 = total cost.
_seed_status() {
	local total_tokens="$1" total_cost="$2"
	local half=$(( total_tokens / 2 ))
	local rest=$(( total_tokens - half ))
	jq -n --argjson inp "$half" --argjson out "$rest" \
		--argjson cost "$total_cost" \
		'{
			state: "running",
			stages: {
				implement: {
					tokens: {
						input_tokens: $inp,
						output_tokens: $out,
						cache_creation_input_tokens: 0,
						cache_read_input_tokens: 0
					},
					estimated_cost: $cost
				}
			}
		}' > "$STATUS_FILE"
}

# =============================================================================
# check_run_budget — DISABLED BY DEFAULT
# =============================================================================

@test "check_run_budget: disabled (ceilings 0) returns 0 regardless of spend" {
	_source_orch_budget_fns
	MAX_RUN_TOKENS=0
	MAX_RUN_COST_USD=0
	_seed_status 999999 999
	run check_run_budget
	[ "$status" -eq 0 ]
}

# =============================================================================
# check_run_budget — HARD BREACH (halt signal)
# =============================================================================

@test "check_run_budget: hard token breach returns 1" {
	_source_orch_budget_fns
	MAX_RUN_TOKENS=1000
	MAX_RUN_COST_USD=0
	_seed_status 1200 0     # 1200 > 1000
	run check_run_budget
	[ "$status" -eq 1 ]
}

@test "check_run_budget: hard cost breach returns 1" {
	_source_orch_budget_fns
	MAX_RUN_TOKENS=0
	MAX_RUN_COST_USD=1.00
	_seed_status 0 1.5      # $1.50 > $1.00
	run check_run_budget
	[ "$status" -eq 1 ]
}

@test "check_run_budget: within budget returns 0" {
	_source_orch_budget_fns
	MAX_RUN_TOKENS=1000
	MAX_RUN_COST_USD=0
	_seed_status 100 0      # well under 80% of 1000
	run check_run_budget
	[ "$status" -eq 0 ]
}

# =============================================================================
# check_run_budget — SOFT THRESHOLD (one-shot warning)
# =============================================================================

@test "check_run_budget: soft threshold warns exactly once across calls" {
	_source_orch_budget_fns
	MAX_RUN_TOKENS=1000
	MAX_RUN_COST_USD=0
	RUN_BUDGET_SOFT_PCT=80
	_RUN_BUDGET_SOFT_WARNED=0
	_seed_status 850 0      # 850 >= 800 (soft) and < 1000 (not hard)

	check_run_budget
	[ "$?" -eq 0 ]
	check_run_budget
	[ "$?" -eq 0 ]

	local warns
	warns=$(grep -c 'soft threshold' "$WARN_LOG")
	[ "$warns" -eq 1 ]
}

# =============================================================================
# set_run_budget_exceeded — TERMINAL STATE WRITER
# =============================================================================

@test "set_run_budget_exceeded: writes budget_exceeded state and stage status" {
	_source_orch_budget_fns
	_seed_status 0 0
	set_run_budget_exceeded "implement" "ceiling hit"
	assert_json_field "$STATUS_FILE" '.state' 'budget_exceeded'
	assert_json_field "$STATUS_FILE" '.stages.implement.status' 'budget_exceeded'
	assert_json_field "$STATUS_FILE" '.budget_exceeded_reason' 'ceiling hit'
}

# =============================================================================
# set_final_state — GUARD: never overwrite a budget_exceeded halt
# =============================================================================

@test "set_final_state: refuses to overwrite budget_exceeded with error" {
	_source_orch_budget_fns
	jq -n '{state:"budget_exceeded", current_stage:"implement"}' > "$STATUS_FILE"
	set_final_state "error"
	assert_json_field "$STATUS_FILE" '.state' 'budget_exceeded'
}

@test "set_final_state: still transitions normal (non-budget) states" {
	_source_orch_budget_fns
	jq -n '{state:"running", current_stage:"implement"}' > "$STATUS_FILE"
	set_final_state "completed"
	assert_json_field "$STATUS_FILE" '.state' 'completed'
}

# =============================================================================
# _apply_stage_action — HARD BREACH OVERRIDES ESCALATE/RETRY
# =============================================================================

@test "_apply_stage_action: hard breach halts with budget_exceeded, overrides escalate" {
	_source_orch_budget_fns
	MAX_RUN_TOKENS=1000
	MAX_RUN_COST_USD=0
	_RUN_STAGE_NAME="implement"
	_seed_status 1200 0     # over ceiling

	local sr='{"status":"error","action":"escalate"}'
	run _apply_stage_action "$sr" "escalate"
	# Non-zero return = halt (not the 0 escalate would normally return).
	[ "$status" -eq 1 ]
	# State proves the run was halted, NOT escalated/retried.
	assert_json_field "$STATUS_FILE" '.state' 'budget_exceeded'
}

@test "_apply_stage_action: hard breach also overrides retry_same" {
	_source_orch_budget_fns
	MAX_RUN_TOKENS=1000
	MAX_RUN_COST_USD=0
	_RUN_STAGE_NAME="test"
	_seed_status 5000 0

	run _apply_stage_action '{"status":"error"}' "retry_same"
	[ "$status" -eq 1 ]
	assert_json_field "$STATUS_FILE" '.state' 'budget_exceeded'
}

@test "_apply_stage_action: within budget passes accept through (rc 0)" {
	_source_orch_budget_fns
	MAX_RUN_TOKENS=0        # disabled
	MAX_RUN_COST_USD=0
	_RUN_STAGE_NAME="implement"
	_seed_status 100 0

	run _apply_stage_action '{"status":"success"}' "accept"
	[ "$status" -eq 0 ]
	# State untouched by a passing budget check.
	assert_json_field "$STATUS_FILE" '.state' 'running'
}

# =============================================================================
# check_batch_budget — BATCH CUMULATIVE TALLY TRIPS THE LOOP BREAKER
# =============================================================================

@test "check_batch_budget: disabled (ceilings 0) returns 0" {
	_source_batch_budget_fn
	MAX_BATCH_TOKENS=0
	MAX_BATCH_COST_USD=0
	_BATCH_TOKENS_USED=999999
	_BATCH_COST_USED=999
	run check_batch_budget
	[ "$status" -eq 0 ]
}

@test "check_batch_budget: hard token breach returns 1 (trips breaker)" {
	_source_batch_budget_fn
	MAX_BATCH_TOKENS=10000
	MAX_BATCH_COST_USD=0
	_BATCH_TOKENS_USED=12000
	_BATCH_COST_USED=0
	run check_batch_budget
	[ "$status" -eq 1 ]
}

@test "check_batch_budget: hard cost breach returns 1" {
	_source_batch_budget_fn
	MAX_BATCH_TOKENS=0
	MAX_BATCH_COST_USD=5.00
	_BATCH_TOKENS_USED=0
	_BATCH_COST_USED=6.50
	run check_batch_budget
	[ "$status" -eq 1 ]
}

@test "check_batch_budget: under budget returns 0" {
	_source_batch_budget_fn
	MAX_BATCH_TOKENS=10000
	MAX_BATCH_COST_USD=0
	_BATCH_TOKENS_USED=500
	_BATCH_COST_USED=0
	run check_batch_budget
	[ "$status" -eq 0 ]
}

@test "check_batch_budget: soft threshold warns exactly once" {
	_source_batch_budget_fn
	MAX_BATCH_TOKENS=10000
	MAX_BATCH_COST_USD=0
	BATCH_BUDGET_SOFT_PCT=80
	_BATCH_BUDGET_SOFT_WARNED=0
	_BATCH_TOKENS_USED=8500   # >= 8000 soft, < 10000 hard
	_BATCH_COST_USED=0

	check_batch_budget
	[ "$?" -eq 0 ]
	check_batch_budget
	[ "$?" -eq 0 ]

	local warns
	warns=$(grep -c 'soft threshold' "$WARN_LOG")
	[ "$warns" -eq 1 ]
}

# =============================================================================
# STATIC: env-configurable ceilings + documented state/exit code
# =============================================================================

@test "orchestrator declares MAX_RUN_TOKENS / MAX_RUN_COST_USD (non-breaking default)" {
	grep -qE '^MAX_RUN_TOKENS="\$\{MAX_RUN_TOKENS:-0\}"' "$ORCHESTRATOR_SCRIPT"
	grep -qE '^MAX_RUN_COST_USD="\$\{MAX_RUN_COST_USD:-0\}"' "$ORCHESTRATOR_SCRIPT"
}

@test "batch declares MAX_BATCH_TOKENS / MAX_BATCH_COST_USD (non-breaking default)" {
	grep -qE '^MAX_BATCH_TOKENS="\$\{MAX_BATCH_TOKENS:-0\}"' "$BATCH_ORCHESTRATOR_SCRIPT_PATH"
	grep -qE '^MAX_BATCH_COST_USD="\$\{MAX_BATCH_COST_USD:-0\}"' "$BATCH_ORCHESTRATOR_SCRIPT_PATH"
}

@test "batch header documents the budget_exceeded state under exit code 2" {
	# Exit-code table mentions budget_exceeded as a shared exit-2 breaker.
	grep -q 'budget_exceeded' "$BATCH_ORCHESTRATOR_SCRIPT_PATH"
	run bash -c "awk '/^# Exit codes:/{f=1} f&&/budget_exceeded/{print; exit}' '$BATCH_ORCHESTRATOR_SCRIPT_PATH'"
	[ -n "$output" ]
}

@test "batch main loop halts on check_batch_budget with budget_exceeded state" {
	# The breaker sets the terminal state and breaks the loop.
	grep -q 'if ! check_batch_budget; then' "$BATCH_ORCHESTRATOR_SCRIPT_PATH"
	grep -q 'set_state "budget_exceeded"' "$BATCH_ORCHESTRATOR_SCRIPT_PATH"
}
