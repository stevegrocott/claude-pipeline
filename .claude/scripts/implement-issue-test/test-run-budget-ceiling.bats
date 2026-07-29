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
	# _stage_key / _stage_acc_* / _persist_stage_call are collaborators of
	# set_run_budget_exceeded and _apply_stage_action (issue #617): the stage
	# key is canonicalised and each dispatched run_stage call persists its own
	# spend.  They must be sourced too or those callers abort on 127.
	# status_json_write / _status_lock_acquire / _status_lock_release are the
	# serialised status.json writer (issue #642): every status_json_write
	# call site above depends on them, so they must be sourced too or those
	# callers abort on 127.
	for fn in _stage_key _stage_acc_dir _stage_acc_file _stage_acc_add \
		_persist_stage_call status_json_write _status_lock_acquire \
		_status_lock_release check_run_budget set_run_budget_exceeded \
		set_final_state _apply_stage_action; do
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

# =============================================================================
# INTEGRATION — the run-level halt is OBSERVABLE and actually stops spending
#
# Blocking bug 1 (issue #583): check_run_budget()/set_run_budget_exceeded() run
# inside the run_stage command-substitution SUBSHELL.  Returning 1 there cannot
# stop the parent — every caller is `x=$(run_stage ...)` and branches on the
# JSON .status, never on $?.  So the halt was swallowed: the pipeline advanced
# to the next stage and kept spending.
#
# These tests drive TWO sequential stages through the REAL run_stage machinery
# (a stubbed `claude` that logs each call and emits a usage block).  A breach at
# stage 1 must halt the run — exit 2, state budget_exceeded — BEFORE stage 2's
# CLI call.  Pre-fix (no _halt_if_budget_exceeded guard) the stub is called
# twice (pipeline continues → RED); post-fix it is called once (GREEN).
# =============================================================================

# Wire the full run_stage harness (mock claude + real decide-action backend) and
# install a call-logging claude stub that emits a usage block on every call.
_setup_run_stage_harness() {
	install_mocks
	install_decide_scripts

	export ISSUE_NUMBER=123
	export BASE_BRANCH=test
	export STATUS_FILE="$TEST_TMP/status.json"
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	export STAGE_COUNTER=0
	export _CONSECUTIVE_TIMEOUTS=0
	export SCHEMA_DIR="$TEST_TMP/schemas"
	mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context" "$SCHEMA_DIR"

	cat > "$SCHEMA_DIR/budget-int.json" << 'EOF'
{ "type": "object", "properties": { "status": { "type": "string" }, "result": { "type": "string" } } }
EOF

	# Per-call ledger — one line appended per CLI invocation, so the count is a
	# direct proof of how many stages actually spent.
	export CLAUDE_CALL_LOG="$TEST_TMP/claude-calls.log"
	: > "$CLAUDE_CALL_LOG"

	# Response emitted on every call: success + a real usage block (issue #583
	# reads .usage.* / .total_cost_usd).  MOCK_STAGE_STATUS lets a test flip the
	# structured status to "error" to exercise the escalate decision path.
	export CLAUDE_RESPONSE_FILE="$TEST_TMP/claude-response.json"
	_write_stub_response "success"

	# Overwrite the default mock with a call-logging stub bound to the ledger and
	# response file above (paths expand now, at write time).
	cat > "$TEST_TMP/bin/claude" << STUB
#!/usr/bin/env bash
printf 'call\n' >> "$CLAUDE_CALL_LOG"
cat "$CLAUDE_RESPONSE_FILE"
STUB
	chmod +x "$TEST_TMP/bin/claude"

	source_orchestrator_functions
}

_write_stub_response() {
	local status="$1"
	jq -n --arg s "$status" '{
		type: "result",
		subtype: "success",
		is_error: false,
		result: "done",
		total_cost_usd: 0.01,
		structured_output: { status: $s, result: "done" },
		usage: {
			input_tokens: 50,
			output_tokens: 50,
			cache_creation_input_tokens: 0,
			cache_read_input_tokens: 0
		}
	}' > "$CLAUDE_RESPONSE_FILE"
}

@test "INTEGRATION: hard breach halts the run so the next stage's CLI never runs" {
	_setup_run_stage_harness
	export MAX_RUN_TOKENS=1000
	export MAX_RUN_COST_USD=0
	# Accumulated prior spend already over the ceiling: the between-stage check
	# at stage 1's completion trips, so stage 2 must never be reached.
	_seed_status 2000 0

	# REAL caller pattern: capture the stage result, then run the guard every
	# caller now runs, then the next stage.  A subshell makes the guard's
	# `exit 2` observable without killing the bats process.
	set +e
	(
		rA=$(run_stage "stageA" "prompt A" "budget-int.json" "default")
		_halt_if_budget_exceeded
		# Reached only if the halt was swallowed (the pre-fix bug): stage 2 spends.
		rB=$(run_stage "stageB" "prompt B" "budget-int.json" "default")
		_halt_if_budget_exceeded
	)
	local rc=$?
	set -e

	# Halted in the parent shell with the issue's budget exit code.
	[ "$rc" -eq 2 ] || fail "expected exit 2 (budget halt), got $rc"
	# Durable terminal state recorded.
	assert_json_field "$STATUS_FILE" '.state' 'budget_exceeded'
	# The decisive proof: exactly ONE claude call (stage A). Stage B never spent.
	local calls
	calls=$(grep -c 'call' "$CLAUDE_CALL_LOG" 2>/dev/null || printf '0')
	[ "$calls" -eq 1 ] || fail "expected exactly 1 CLI call (stage B must not run), got $calls"
}

@test "INTEGRATION: hard breach in the escalate path skips the pricier retry call" {
	_setup_run_stage_harness
	export MAX_RUN_TOKENS=1000
	export MAX_RUN_COST_USD=0
	_seed_status 2000 0
	# A structured error at a NON-ceiling model (haiku, pinned via model_override
	# arg 7) steers the bash decide-action backend to 'escalate' (a model at the
	# opus ceiling would 'bail' instead).  This exercises blocking bug 2: the
	# pre-escalation budget check must fire BEFORE the second (escalated) CLI
	# call, so only the primary call is ever made.
	_write_stub_response "error"

	set +e
	(
		rA=$(run_stage "stageA" "prompt A" "budget-int.json" "default" "" "" "haiku")
		_halt_if_budget_exceeded
	)
	local rc=$?
	set -e

	[ "$rc" -eq 2 ] || fail "expected exit 2 (budget halt), got $rc"
	assert_json_field "$STATUS_FILE" '.state' 'budget_exceeded'
	# Only the primary attempt spent — the escalated call was suppressed.
	local calls
	calls=$(grep -c 'call' "$CLAUDE_CALL_LOG" 2>/dev/null || printf '0')
	[ "$calls" -eq 1 ] || fail "escalation was not suppressed: expected 1 CLI call, got $calls"
}
