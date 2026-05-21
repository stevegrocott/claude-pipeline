#!/usr/bin/env bats
#
# test-stage-runner.bats
# Tests for the run_stage function
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    install_mocks

    # Set required variables
    export ISSUE_NUMBER=123
    export BASE_BRANCH=test
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0
    export _CONSECUTIVE_TIMEOUTS=0
    export SCHEMA_DIR="$TEST_TMP/schemas"

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"
    mkdir -p "$SCHEMA_DIR"

    # Create a valid test schema
    cat > "$SCHEMA_DIR/test-schema.json" << 'EOF'
{
    "type": "object",
    "properties": {
        "status": {"type": "string"},
        "result": {"type": "string"}
    }
}
EOF

    # Source the orchestrator functions
    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# =============================================================================
# SCHEMA VALIDATION
# =============================================================================

@test "run_stage fails with missing schema file" {
    run run_stage "test-stage" "test prompt" "nonexistent.json"
    [ "$status" -eq 1 ]
    # New stage_result envelope reports error_kind="schema_not_found"
    # (snake_case; see schemas/stage-result.json enum).
    [[ "$output" == *"schema_not_found"* ]]
}

@test "run_stage uses correct schema file" {
    # Create mock response file
    export MOCK_CLAUDE_RESPONSE="$TEST_TMP/mock-response.json"
    echo '{"result":"ok","structured_output":{"status":"success","result":"done"}}' > "$MOCK_CLAUDE_RESPONSE"

    run run_stage "test-stage" "test prompt" "test-schema.json"

    # Check that the stage log was created
    local stage_log
    stage_log=$(ls "$LOG_BASE/stages/"*.log 2>/dev/null | head -1)
    [ -n "$stage_log" ]
}

# =============================================================================
# STAGE COUNTER AND LOGGING
# =============================================================================

@test "next_stage_log increments counter" {
    # Note: next_stage_log increments STAGE_COUNTER, but when called in a
    # subshell (via command substitution), the increment is lost to the parent.
    # This tests the function's output format, not the counter persistence.
    # Each call in a subshell sees its own incremented value.
    STAGE_COUNTER=0
    local log1
    log1=$(next_stage_log "setup")
    [ "$log1" = "01-setup.log" ]

    # For sequential numbering, we'd need to call without subshell
    # or increment manually. Test direct call instead:
    STAGE_COUNTER=1
    local log2
    log2=$(next_stage_log "implement")
    [ "$log2" = "02-implement.log" ]

    STAGE_COUNTER=2
    local log3
    log3=$(next_stage_log "review")
    [ "$log3" = "03-review.log" ]
}

@test "next_stage_log pads single digits" {
    STAGE_COUNTER=8
    local log
    log=$(next_stage_log "test")
    [ "$log" = "09-test.log" ]
}

@test "next_stage_log handles double digits" {
    STAGE_COUNTER=99
    local log
    log=$(next_stage_log "test")
    [ "$log" = "100-test.log" ]
}

# =============================================================================
# LOG FUNCTIONS
# =============================================================================

@test "log writes to log file" {
    log "Test message"
    grep -q "Test message" "$LOG_FILE"
}

@test "log includes timestamp" {
    log "Test message"
    # ISO 8601 format: YYYY-MM-DDTHH:MM:SS+TZ
    grep -qE '\[[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$LOG_FILE"
}

@test "log_error writes to log file" {
    log_error "Error message" 2>/dev/null
    grep -q "ERROR: Error message" "$LOG_FILE"
}

# =============================================================================
# STRUCTURED OUTPUT EXTRACTION
# =============================================================================

@test "run_stage extracts structured_output" {
    # Create mock response file
    local mock_response="$TEST_TMP/mock-response.json"
    echo '{"result":"verbose text","structured_output":{"status":"success","data":"extracted"}}' > "$mock_response"

    # Override timeout and claude to return mock response directly
    timeout() {
        shift  # skip timeout value
        # Instead of running claude, just output mock response
        cat "$mock_response"
    }
    export -f timeout

    local result
    # run_stage outputs log lines followed by JSON on the last line
    # Extract just the JSON line (starts with '{')
    result=$(run_stage "test" "prompt" "test-schema.json" | grep '^{')
    [ -n "$result" ] || fail "run_stage returned no JSON output"

    # Envelope: .status reflects run-level outcome; .output carries the
    # parsed structured output from the agent (issue #178 PR-A).
    local extracted_status
    extracted_status=$(echo "$result" | jq -r '.output.status')
    [ "$extracted_status" = "success" ]
}

@test "run_stage returns error for missing structured_output" {
    export MOCK_CLAUDE_RESPONSE="$TEST_TMP/mock-response.json"
    echo '{"result":"no structured output"}' > "$MOCK_CLAUDE_RESPONSE"

    run run_stage "test" "prompt" "test-schema.json"
    [ "$status" -eq 1 ]
    # Envelope reports error_kind="no_structured_output" (snake_case enum).
    [[ "$output" == *"no_structured_output"* ]]
}

# =============================================================================
# FIELD-AWARE STRUCTURED OUTPUT RECOVERY
# =============================================================================

@test "run_stage fallback extracts pr_number from result text" {
	# No .structured_output, but .result contains PR number text
	timeout() {
		shift  # skip timeout value
		echo '{"result":"Created PR #42 successfully","is_error":false}'
	}
	export -f timeout

	local result
	result=$(run_stage "pr" "prompt" "test-schema.json" | grep '^{')
	[ -n "$result" ] || fail "run_stage returned no JSON output"

	local pr_number
	pr_number=$(printf '%s' "$result" | jq -r '.output.pr_number // empty')
	[ "$pr_number" = "42" ] || \
		fail "Expected pr_number=42, got: $pr_number (full output: $result)"
}

@test "run_stage fallback does NOT set pr_number from bare issue ref" {
	# A bare '#N' in an issue-reference context (e.g. 'Implemented issue #52')
	# must not be extracted as a PR number — hash_re is intentionally absent.
	timeout() {
		shift  # skip timeout value
		echo '{"result":"Implemented issue #52 on branch feature/issue-52","is_error":false}'
	}
	export -f timeout

	local result
	result=$(run_stage "implement" "prompt" "test-schema.json" | grep '^{')
	[ -n "$result" ] || fail "run_stage returned no JSON output"

	local pr_number
	pr_number=$(printf '%s' "$result" | jq -r '.output.pr_number // empty')
	[ -z "$pr_number" ] || \
		fail "pr_number should be empty for bare issue ref, got: $pr_number"
}

@test "run_stage fallback extracts branch from result text" {
	# No .structured_output, but .result contains branch name
	timeout() {
		shift  # skip timeout value
		echo '{"result":"Working on branch feature/issue-52 completed","is_error":false}'
	}
	export -f timeout

	local result
	result=$(run_stage "implement" "prompt" "test-schema.json" | grep '^{')
	[ -n "$result" ] || fail "run_stage returned no JSON output"

	local branch
	branch=$(printf '%s' "$result" | jq -r '.output.branch // empty')
	[ "$branch" = "feature/issue-52" ] || \
		fail "Expected branch=feature/issue-52, got: $branch (full output: $result)"
}

@test "run_stage fallback extracts tasks array from result text" {
	# No .structured_output, but .result contains embedded JSON tasks array
	local tasks_json='[{"id":1,"description":"Setup","agent":"dev"},{"id":2,"description":"Implement","agent":"dev"}]'
	local mock_file="$TEST_TMP/tasks-mock.json"
	jq -n --arg t "Tasks: $tasks_json" \
		'{result: $t, is_error: false}' > "$mock_file"
	timeout() {
		shift  # skip timeout value
		cat "$TEST_TMP/tasks-mock.json"
	}
	export -f timeout

	local result
	result=$(run_stage "parse" "prompt" "test-schema.json" | grep '^{')
	[ -n "$result" ] || fail "run_stage returned no JSON output"

	local tasks_count
	tasks_count=$(printf '%s' "$result" | jq -r 'if .output.tasks then (.output.tasks | length) else 0 end')
	[ "$tasks_count" = "2" ] || \
		fail "Expected 2 tasks, got: $tasks_count (full output: $result)"
}

@test "run_stage fallback with no extractable fields still succeeds" {
	# No .structured_output, .result is plain text with no parseable fields
	timeout() {
		shift  # skip timeout value
		echo '{"result":"Task completed successfully","is_error":false}'
	}
	export -f timeout

	local result
	result=$(run_stage "implement" "prompt" "test-schema.json" | grep '^{')
	[ -n "$result" ] || fail "run_stage returned no JSON output"

	# Envelope-level status reflects run-level success even when no fields
	# extracted from .result text — agent's status sits under .output.status.
	local status_val
	status_val=$(printf '%s' "$result" | jq -r '.output.status')
	[ "$status_val" = "success" ] || \
		fail "Expected output.status=success, got: $status_val (full output: $result)"
}

# =============================================================================
# TIMEOUT HANDLING
# =============================================================================

@test "run_stage returns timeout error on exit code 124" {
    # Override timeout to simulate timeout on both initial attempt and retry
    timeout() {
        shift  # skip timeout value
        return 124
    }
    export -f timeout

    run run_stage "test" "prompt" "test-schema.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"timeout"* ]]
}

@test "run_stage retries with 20% longer timeout after initial timeout" {
    # Record which timeout values were used across calls
    local calls_file="$TEST_TMP/timeout-calls.txt"
    timeout() {
        local t="$1"
        printf '%s\n' "$t" >> "$calls_file"
        shift  # skip timeout value
        if [[ "$(wc -l < "$calls_file")" -eq 1 ]]; then
            return 124  # first call: simulate timeout
        fi
        # second call (retry): succeed with structured output
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout
    export calls_file

    run run_stage "test" "prompt" "test-schema.json"
    [ "$status" -eq 0 ]

    # Verify two timeout calls were made
    local call_count
    call_count=$(wc -l < "$calls_file")
    (( call_count == 2 )) || fail "Expected 2 timeout calls, got $call_count"

    # Verify retry timeout is 20% larger than initial timeout
    local first_timeout second_timeout expected_retry
    first_timeout=$(sed -n '1p' "$calls_file")
    second_timeout=$(sed -n '2p' "$calls_file")
    expected_retry=$(( first_timeout + first_timeout / 5 ))
    (( second_timeout == expected_retry )) || \
        fail "Expected retry timeout ${expected_retry}s, got ${second_timeout}s"
}

# =============================================================================
# CASCADE TIMEOUT DETECTION
# =============================================================================

@test "cascade timeout: counter increments after definitive timeout" {
	timeout() {
		shift  # skip timeout value
		return 124  # always timeout (both initial and retry)
	}
	export -f timeout

	_CONSECUTIVE_TIMEOUTS=0
	run_stage "test-stage" "prompt" "test-schema.json" \
		>/dev/null 2>/dev/null || true
	[ "$_CONSECUTIVE_TIMEOUTS" -eq 1 ] || \
		fail "Expected counter=1 after one timeout, got $_CONSECUTIVE_TIMEOUTS"
}

@test "cascade timeout: no warning after single timeout" {
	timeout() {
		shift  # skip timeout value
		return 124  # always timeout
	}
	export -f timeout

	_CONSECUTIVE_TIMEOUTS=0
	run_stage "test-stage" "prompt" "test-schema.json" \
		>/dev/null 2>/dev/null || true

	! grep -q "Cascade timeout detected" "$LOG_FILE" || \
		fail "Should not warn after single timeout. Log: $(cat "$LOG_FILE")"
}

@test "cascade timeout: warning logged after 2 consecutive timeouts" {
	timeout() {
		shift  # skip timeout value
		return 124  # always timeout
	}
	export -f timeout

	_CONSECUTIVE_TIMEOUTS=0
	run_stage "stage-1" "prompt" "test-schema.json" \
		>/dev/null 2>/dev/null || true
	run_stage "stage-2" "prompt" "test-schema.json" \
		>/dev/null 2>/dev/null || true

	grep -q "Cascade timeout detected" "$LOG_FILE" || \
		fail "Expected cascade warning in log. Log: $(cat "$LOG_FILE")"
}

@test "cascade timeout: warning includes actionable suggestion" {
	timeout() {
		shift  # skip timeout value
		return 124  # always timeout
	}
	export -f timeout

	_CONSECUTIVE_TIMEOUTS=0
	run_stage "stage-1" "prompt" "test-schema.json" \
		>/dev/null 2>/dev/null || true
	run_stage "stage-2" "prompt" "test-schema.json" \
		>/dev/null 2>/dev/null || true

	grep -q "increasing timeout\|reducing complexity" "$LOG_FILE" || \
		fail "Expected suggestion in log. Log: $(cat "$LOG_FILE")"
}

@test "cascade timeout: warning includes timed-out stage names" {
	timeout() {
		shift  # skip timeout value
		return 124  # always timeout
	}
	export -f timeout

	_CONSECUTIVE_TIMEOUTS=0
	_TIMED_OUT_STAGE_NAMES=""
	run_stage "stage-1" "prompt" "test-schema.json" \
		>/dev/null 2>/dev/null || true
	run_stage "stage-2" "prompt" "test-schema.json" \
		>/dev/null 2>/dev/null || true

	grep -q "stage-1, stage-2" "$LOG_FILE" || \
		fail "Expected stage names in cascade warning. Log: $(cat "$LOG_FILE")"
}

@test "cascade timeout: counter resets to 0 after successful stage" {
	local calls_file="$TEST_TMP/cascade-calls.txt"
	printf '0' > "$calls_file"
	timeout() {
		local n
		n=$(cat "$calls_file")
		n=$((n + 1))
		printf '%s' "$n" > "$calls_file"
		shift  # skip timeout value
		if (( n <= 2 )); then
			# First two calls: initial attempt + retry for stage-1
			return 124
		fi
		echo '{"result":"ok","structured_output":{"status":"success"}}'
	}
	export -f timeout
	export calls_file

	_CONSECUTIVE_TIMEOUTS=0
	run_stage "stage-1" "prompt" "test-schema.json" \
		>/dev/null 2>/dev/null || true
	# counter = 1 after stage-1 definitively times out
	run_stage "stage-2" "prompt" "test-schema.json" >/dev/null 2>/dev/null
	# counter should be reset to 0 after stage-2 succeeds
	[ "$_CONSECUTIVE_TIMEOUTS" -eq 0 ] || \
		fail "Expected counter=0 after success, got $_CONSECUTIVE_TIMEOUTS"
}

@test "cascade timeout: counter stays 0 when initial timeout recovers" {
	# A timeout that recovers (structured output extracted from first attempt)
	# should NOT increment the counter — it did not definitively time out.
	local calls_file="$TEST_TMP/recover-calls.txt"
	printf '0' > "$calls_file"
	timeout() {
		local n
		n=$(cat "$calls_file")
		n=$((n + 1))
		printf '%s' "$n" > "$calls_file"
		shift  # skip timeout value
		# Return structured output AND exit 124 — simulates early-output timeout
		echo '{"result":"partial","structured_output":{"status":"success"}}'
		return 124
	}
	export -f timeout
	export calls_file

	_CONSECUTIVE_TIMEOUTS=0
	run_stage "stage-1" "prompt" "test-schema.json" \
		>/dev/null 2>/dev/null
	# Only one call made (early-output recovery), counter stays at 0
	[ "$_CONSECUTIVE_TIMEOUTS" -eq 0 ] || \
		fail "Expected counter=0 on recovery, got $_CONSECUTIVE_TIMEOUTS"
}

# =============================================================================
# AGENT SELECTION
# =============================================================================

@test "run_stage passes agent when specified" {
    # Override timeout to intercept and record claude args
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift  # skip timeout value
        shift  # skip 'env'
        shift  # skip '-u'
        shift  # skip 'CLAUDECODE'
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    run_stage "test" "prompt" "test-schema.json" "fastify-backend-developer"

    # Verify agent was passed to claude
    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--agent fastify-backend-developer" "$claude_calls" || \
        fail "Agent 'fastify-backend-developer' was not passed to claude. Calls: $(cat "$claude_calls")"
}

# =============================================================================
# MODEL SELECTION
#
# BATS runs each @test in a forked subprocess. Exported functions survive the
# fork, but bash arrays (including readonly arrays) do not. model-config.sh
# defines _STAGE_PREFIXES as a readonly array, so we must re-source it at the
# top of every @test body that exercises model/tier resolution.
#
# The re-source MUST happen at the @test scope (not inside a helper function)
# because `readonly -a` inside a function creates a function-local variable
# that is invisible to the caller.
# =============================================================================

@test "run_stage passes --model to claude" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift  # timeout value
        shift  # env
        shift  # -u
        shift  # CLAUDECODE
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    run_stage "implement-task-1" "prompt" "test-schema.json" "" ""

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--model" "$claude_calls" || \
        fail "--model was not passed to claude. Calls: $(cat "$claude_calls")"
}

@test "run_stage resolves opus for implement stage" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    run_stage "implement-task-1" "prompt" "test-schema.json" "" ""

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--model opus" "$claude_calls" || \
        fail "Expected --model opus for implement stage. Calls: $(cat "$claude_calls")"
}

@test "run_stage resolves haiku for test stage" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    run_stage "test-iter-1" "prompt" "test-schema.json" "" ""

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--model haiku" "$claude_calls" || \
        fail "Expected --model haiku for test stage. Calls: $(cat "$claude_calls")"
}

@test "run_stage uses complexity hint to override model" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    # implement defaults to opus, but M complexity overrides to sonnet
    run_stage "implement-task-1" "prompt" "test-schema.json" "" "M"

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--model sonnet" "$claude_calls" || \
        fail "Expected --model sonnet with M complexity. Calls: $(cat "$claude_calls")"
}

@test "run_stage logs model in stage output" {
    source "$TEST_TMP/model-config.sh"
    timeout() {
        shift; shift; shift; shift
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    run_stage "review-task-1-iter-1" "prompt" "test-schema.json" "" ""

    # Verify model was logged
    grep -q "Model: sonnet" "$LOG_FILE" || \
        fail "Model was not logged. Log: $(cat "$LOG_FILE")"
}

@test "run_stage logs complexity hint when provided" {
    source "$TEST_TMP/model-config.sh"
    timeout() {
        shift; shift; shift; shift
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    run_stage "implement-task-1" "prompt" "test-schema.json" "" "L"

    # Verify complexity was logged
    grep -q "Complexity: L" "$LOG_FILE" || \
        fail "Complexity hint was not logged. Log: $(cat "$LOG_FILE")"
}

# =============================================================================
# TIMEOUT ESCALATION — STRUCTURED OUTPUT RECOVERY ON FIRST TIMEOUT
# =============================================================================

@test "run_stage uses structured output from timed-out first call without retrying" {
    # When the first call exits 124 but already emitted structured_output,
    # run_stage must use it and return 0 without making a second call.
    local calls_file="$TEST_TMP/timeout-calls.txt"
    timeout() {
        local t="$1"; shift
        printf 'CALLED\n' >> "$calls_file"
        echo '{"result":"partial","structured_output":{"status":"success","data":"early"}}'
        return 124
    }
    export -f timeout
    export calls_file

    local result
    result=$(run_stage "test" "prompt" "test-schema.json" | grep '^{')
    [ -n "$result" ] || fail "run_stage returned no JSON output"

    # Envelope-level status: run completed (recovered structured output).
    local status_val
    status_val=$(printf '%s' "$result" | jq -r '.status')
    [ "$status_val" = "success" ] || \
        fail "Expected status=success, got: $status_val (result: $result)"

    # Only one timeout call — no retry should have happened
    local call_count
    call_count=$(wc -l < "$calls_file")
    (( call_count == 1 )) || \
        fail "Expected 1 timeout call (no retry), got $call_count"
}

# =============================================================================
# TIMEOUT .RESULT FALLBACK
# =============================================================================

@test "run_stage uses .result fallback when timeout occurs with no structured_output" {
	# When exit 124 occurs but output has .is_error:false and .result (no
	# .structured_output), run_stage must use a fallback payload and return 0.
	local calls_file="$TEST_TMP/result-fallback-calls.txt"
	timeout() {
		local t="$1"; shift
		printf 'CALLED\n' >> "$calls_file"
		echo '{"result":"Summary of work done","is_error":false}'
		return 124
	}
	export -f timeout
	export calls_file

	local result
	result=$(run_stage "test" "prompt" "test-schema.json" | grep '^{')
	[ -n "$result" ] || fail "run_stage returned no JSON output"

	# Envelope-level status: run completed via .result-text fallback.
	local status_val
	status_val=$(printf '%s' "$result" | jq -r '.status')
	[ "$status_val" = "success" ] || \
		fail "Expected status=success, got: $status_val (result: $result)"

	# Agent-reported summary lives under .output.summary in the envelope.
	local summary_val
	summary_val=$(printf '%s' "$result" | jq -r '.output.summary')
	[ "$summary_val" = "Summary of work done" ] || \
		fail "Expected summary='Summary of work done', got: $summary_val"

	# Only one timeout call — no retry should happen
	local call_count
	call_count=$(wc -l < "$calls_file")
	(( call_count == 1 )) || \
		fail "Expected 1 timeout call (no retry on fallback), got $call_count"
}

@test "run_stage logs WARN when using .result fallback on timeout" {
	timeout() {
		shift
		echo '{"result":"Fallback content","is_error":false}'
		return 124
	}
	export -f timeout

	run_stage "test" "prompt" "test-schema.json" >/dev/null 2>/dev/null

	grep -q "produced .result" "$LOG_FILE" || \
		fail "Expected WARN about .result fallback in log. Log: $(cat "$LOG_FILE")"
}

@test "run_stage does not use .result fallback when is_error is true on timeout" {
	# When output has is_error:true the fallback must not trigger;
	# the retry path should be attempted instead.
	local calls_file="$TEST_TMP/no-fallback-calls.txt"
	timeout() {
		local t="$1"; shift
		printf 'CALLED\n' >> "$calls_file"
		echo '{"result":"some content","is_error":true}'
		return 124
	}
	export -f timeout
	export calls_file

	run run_stage "test" "prompt" "test-schema.json"
	[ "$status" -eq 1 ]

	# Both initial attempt and retry must have been called (fallback skipped)
	local call_count
	call_count=$(wc -l < "$calls_file")
	(( call_count == 2 )) || \
		fail "Expected 2 timeout calls (fallback skipped, retry made), got $call_count"
}

# =============================================================================
# DIAGNOSTIC LOGGING
# =============================================================================

@test "run_stage logs diagnostic byte count when structured output extraction fails" {
	# Output has is_error:true — neither .structured_output nor .result fallback
	# will match, so the diagnostic log must fire before the error return.
	timeout() {
		shift
		echo '{"is_error":true,"result":"error occurred"}'
	}
	export -f timeout

	run run_stage "test" "prompt" "test-schema.json"
	[ "$status" -eq 1 ]

	grep -q "Diagnostic fallback failure — Output byte count:" "$LOG_FILE" || \
		fail "Expected diagnostic byte count in log. Log: $(cat "$LOG_FILE")"
}

@test "run_stage logs diagnostic output preview when structured output extraction fails" {
	timeout() {
		shift
		echo '{"is_error":true,"result":"unique diagnostic content xyz"}'
	}
	export -f timeout

	run run_stage "test" "prompt" "test-schema.json"
	[ "$status" -eq 1 ]

	grep -q "Diagnostic fallback failure — First 500 characters:" "$LOG_FILE" || \
		fail "Expected diagnostic preview in log. Log: $(cat "$LOG_FILE")"
}

@test "run_stage diagnostic log captures actual output content" {
	# The preview logged must include the raw output content, making it useful
	# for debugging what the model actually returned.
	timeout() {
		shift
		echo '{"is_error":true,"result":"recognizable-debug-marker-abc123"}'
	}
	export -f timeout

	run run_stage "test" "prompt" "test-schema.json"
	[ "$status" -eq 1 ]

	grep -q "recognizable-debug-marker-abc123" "$LOG_FILE" || \
		fail "Diagnostic log must include actual output content. Log: $(cat "$LOG_FILE")"
}

# =============================================================================
# MODEL ESCALATION — error_max_turns
# =============================================================================

@test "run_stage escalates model when output subtype is error_max_turns" {
    # BATS runs each @test in a forked subprocess — re-source model-config to
    # make readonly arrays available (same pattern as MODEL SELECTION tests).
    source "$TEST_TMP/model-config.sh"
    local counter_file="$TEST_TMP/call-counter.txt"
    printf '0' > "$counter_file"
    timeout() {
        shift  # timeout value
        shift  # env
        shift  # -u
        shift  # CLAUDECODE
        local n
        n=$(cat "$counter_file")
        n=$((n + 1))
        printf '%s' "$n" > "$counter_file"
        echo "$@" > "$TEST_TMP/call-$n-args.txt"
        if (( n == 1 )); then
            echo '{"subtype":"error_max_turns","is_error":false,"result":"Hit max turns"}'
        else
            echo '{"result":"ok","structured_output":{"status":"success"}}'
        fi
    }
    export -f timeout
    export counter_file

    # test-iter-1 resolves to haiku; haiku escalates to sonnet on error_max_turns
    run_stage "test-iter-1" "prompt" "test-schema.json" "" ""

    local final_count
    final_count=$(cat "$counter_file")
    (( final_count == 2 )) || fail "Expected 2 claude calls, got $final_count"

    # Second call must use escalated model (sonnet)
    local second_call_args
    second_call_args=$(cat "$TEST_TMP/call-2-args.txt" 2>/dev/null)
    [[ "$second_call_args" == *"--model sonnet"* ]] || \
        fail "Expected --model sonnet in escalated retry. Args: $second_call_args"
}

@test "run_stage fails with max_turns_exhausted_at_ceiling when opus hits error_max_turns" {
    source "$TEST_TMP/model-config.sh"
    timeout() {
        shift; shift; shift; shift
        # Always return error_max_turns — opus is at ceiling, cannot escalate
        echo '{"subtype":"error_max_turns","is_error":false,"result":"Hit max turns"}'
    }
    export -f timeout

    # implement stage resolves to opus (ceiling model)
    run run_stage "implement-task-1" "prompt" "test-schema.json" "" ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"max_turns_exhausted_at_ceiling"* ]] || \
        fail "Expected ceiling error in output. Got: $output"
}

@test "run_stage does not include max-turns cap on error_max_turns escalation retry" {
    source "$TEST_TMP/model-config.sh"
    local counter_file="$TEST_TMP/call-counter.txt"
    printf '0' > "$counter_file"
    timeout() {
        shift  # timeout value
        shift  # env
        shift  # -u
        shift  # CLAUDECODE
        local n
        n=$(cat "$counter_file")
        n=$((n + 1))
        printf '%s' "$n" > "$counter_file"
        echo "$@" > "$TEST_TMP/call-$n-args.txt"
        if (( n == 1 )); then
            echo '{"subtype":"error_max_turns","is_error":false,"result":"Hit max turns"}'
        else
            echo '{"result":"ok","structured_output":{"status":"success"}}'
        fi
    }
    export -f timeout
    export counter_file

    # haiku test stage gets --max-turns on first call; escalated retry must omit it
    run_stage "test-iter-1" "prompt" "test-schema.json" "" ""

    local second_call_args
    second_call_args=$(cat "$TEST_TMP/call-2-args.txt" 2>/dev/null)
    [[ -n "$second_call_args" ]] || fail "No second call was made"
    [[ "$second_call_args" != *"--max-turns"* ]] || \
        fail "Escalated retry should not include --max-turns. Args: $second_call_args"
}

# =============================================================================
# MODEL ESCALATION — structured_error
# =============================================================================

@test "run_stage escalates when structured_output.status is error without permission_denials" {
    # BATS runs each @test in a forked subprocess — re-source model-config to
    # make readonly arrays available (same pattern as MODEL SELECTION tests).
    source "$TEST_TMP/model-config.sh"
    # record_escalation needs a minimal status.json to write into.
    cat > "$STATUS_FILE" << 'EOF'
{"escalations": [], "stages": {}}
EOF
    local counter_file="$TEST_TMP/call-counter.txt"
    printf '0' > "$counter_file"
    timeout() {
        shift  # timeout value
        shift  # env
        shift  # -u
        shift  # CLAUDECODE
        local n
        n=$(cat "$counter_file")
        n=$((n + 1))
        printf '%s' "$n" > "$counter_file"
        echo "$@" > "$TEST_TMP/call-$n-args.txt"
        if (( n == 1 )); then
            # Structured error with no permission_denials — must escalate
            echo '{"result":"failed","structured_output":{"status":"error","error":"first attempt failed"}}'
        else
            # Escalated call: succeed
            echo '{"result":"ok","structured_output":{"status":"success","data":"recovered"}}'
        fi
    }
    export -f timeout
    export counter_file

    # test-iter-1 resolves to sonnet; sonnet escalates to opus on structured_error
    local result
    result=$(run_stage "test-iter-1" "prompt" "test-schema.json" "" "" | grep '^{')
    [ -n "$result" ] || fail "run_stage returned no JSON output"

    local final_count
    final_count=$(cat "$counter_file")
    (( final_count == 2 )) || fail "Expected 2 claude calls (original + escalated), got $final_count"

    # Second call must use escalated model (opus — next tier above sonnet)
    local second_call_args
    second_call_args=$(cat "$TEST_TMP/call-2-args.txt" 2>/dev/null)
    [[ "$second_call_args" == *"--model opus"* ]] || \
        fail "Expected --model opus in escalated retry. Args: $second_call_args"

    # Final envelope status must reflect the successful escalated run.
    # Both envelope .status and agent .output.status are "success" here
    # because the escalated agent returned status:"success".
    local status_val
    status_val=$(printf '%s' "$result" | jq -r '.status')
    [ "$status_val" = "success" ] || \
        fail "Expected 'success' after escalation, got: $status_val"

    local agent_status
    agent_status=$(printf '%s' "$result" | jq -r '.output.status')
    [ "$agent_status" = "success" ] || \
        fail "Expected output.status='success' after escalation, got: $agent_status"
}

@test "run_stage skips escalation and logs warning when permission_denials is non-empty" {
    source "$TEST_TMP/model-config.sh"
    cat > "$STATUS_FILE" << 'EOF'
{"escalations": [], "stages": {}}
EOF
    local counter_file="$TEST_TMP/call-counter.txt"
    printf '0' > "$counter_file"
    timeout() {
        shift  # timeout value
        shift  # env
        shift  # -u
        shift  # CLAUDECODE
        local n
        n=$(cat "$counter_file")
        n=$((n + 1))
        printf '%s' "$n" > "$counter_file"
        # status:error with non-empty permission_denials — escalation must be skipped
        echo '{"result":"blocked","structured_output":{"status":"error","error":"permission denied"},"permission_denials":[{"tool_name":"Edit"},{"tool_name":"Write"}]}'
    }
    export -f timeout
    export counter_file

    run_stage "test-iter-1" "prompt" "test-schema.json" "" "" >/dev/null 2>/dev/null

    # Only one claude call should have been made — escalation was skipped
    local final_count
    final_count=$(cat "$counter_file")
    (( final_count == 1 )) || \
        fail "Expected 1 claude call (escalation skipped), got $final_count"

    # Warning log must name the denied tools and reference the permission hook
    grep -q "blocked by permission hook" "$LOG_FILE" || \
        fail "Expected permission-hook warning in log. Log: $(cat "$LOG_FILE")"
    grep -q "Edit" "$LOG_FILE" || \
        fail "Expected denied tool 'Edit' named in warning. Log: $(cat "$LOG_FILE")"
    grep -q "Write" "$LOG_FILE" || \
        fail "Expected denied tool 'Write' named in warning. Log: $(cat "$LOG_FILE")"

    # No escalation should have been recorded
    local escalation_count
    escalation_count=$(jq '.escalations | length' "$STATUS_FILE")
    [ "$escalation_count" = "0" ] || \
        fail "Expected 0 escalations recorded, got: $escalation_count"
}

@test "run_stage records structured_error escalation with reason 'structured_error'" {
    source "$TEST_TMP/model-config.sh"
    cat > "$STATUS_FILE" << 'EOF'
{"escalations": [], "stages": {}}
EOF
    local counter_file="$TEST_TMP/call-counter.txt"
    printf '0' > "$counter_file"
    timeout() {
        shift  # timeout value
        shift  # env
        shift  # -u
        shift  # CLAUDECODE
        local n
        n=$(cat "$counter_file")
        n=$((n + 1))
        printf '%s' "$n" > "$counter_file"
        if (( n == 1 )); then
            echo '{"result":"failed","structured_output":{"status":"error","error":"first attempt failed"}}'
        else
            echo '{"result":"ok","structured_output":{"status":"success"}}'
        fi
    }
    export -f timeout
    export counter_file

    run_stage "test-iter-1" "prompt" "test-schema.json" "" "" >/dev/null 2>/dev/null

    local reason
    reason=$(jq -r '.escalations[0].reason // empty' "$STATUS_FILE")
    [ "$reason" = "structured_error" ] || \
        fail "Expected escalation reason 'structured_error', got: $reason (status.json: $(cat "$STATUS_FILE"))"

    # Escalation metadata should reflect sonnet → opus transition
    local from_model
    from_model=$(jq -r '.escalations[0].from_model // empty' "$STATUS_FILE")
    [[ "$from_model" == *"sonnet"* ]] || \
        fail "Expected from_model to contain 'sonnet', got: $from_model"

    local to_model
    to_model=$(jq -r '.escalations[0].to_model // empty' "$STATUS_FILE")
    [[ "$to_model" == *"opus"* ]] || \
        fail "Expected to_model to contain 'opus', got: $to_model"
}

# =============================================================================
# COMPLEXITY-AWARE MAX-TURNS LOGIC
# =============================================================================

@test "run_stage passes --max-turns 40 to sonnet with M-complexity" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    run_stage "implement-task-1" "prompt" "test-schema.json" "" "M"

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 40" "$claude_calls" || \
        fail "Expected --max-turns 40 for sonnet with M-complexity. Calls: $(cat "$claude_calls")"
}

@test "run_stage passes --max-turns 40 to sonnet with L-complexity" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    # implement+L resolves to opus; use model_override to force sonnet + L hint
    run_stage "implement-task-1" "prompt" "test-schema.json" "" "L" "" "sonnet"

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 40" "$claude_calls" || \
        fail "Expected --max-turns 40 for sonnet with L-complexity. Calls: $(cat "$claude_calls")"
}

@test "run_stage passes --max-turns 25 to sonnet with S-complexity" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    # implement+S resolves to haiku; use model_override to force sonnet + S hint
    run_stage "implement-task-1" "prompt" "test-schema.json" "" "S" "" "sonnet"

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 25" "$claude_calls" || \
        fail "Expected --max-turns 25 for sonnet with S-complexity. Calls: $(cat "$claude_calls")"
}

@test "run_stage passes --max-turns 25 to sonnet with empty complexity" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    # review stage is standard tier — resolves naturally to sonnet with no complexity hint
    run_stage "review-task-1-iter-1" "prompt" "test-schema.json" "" ""

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 25" "$claude_calls" || \
        fail "Expected --max-turns 25 for sonnet with empty complexity. Calls: $(cat "$claude_calls")"
}

@test "run_stage passes --max-turns 10 to haiku for light-tier stage" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    # parse is a light-tier stage
    run_stage "parse-issue" "prompt" "test-schema.json" "" ""

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 10" "$claude_calls" || \
        fail "Expected --max-turns 10 for haiku light-tier stage. Calls: $(cat "$claude_calls")"
}

@test "run_stage passes --max-turns 15 to haiku via S-complexity override" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    # implement-task-1 with S-complexity resolves to haiku via override
    run_stage "implement-task-1" "prompt" "test-schema.json" "" "S"

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 15" "$claude_calls" || \
        fail "Expected --max-turns 15 for haiku via complexity override. Calls: $(cat "$claude_calls")"
}

@test "run_stage logs max-turns value for sonnet with M-complexity" {
    source "$TEST_TMP/model-config.sh"
    timeout() {
        shift; shift; shift; shift
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    run_stage "implement-task-1" "prompt" "test-schema.json" "" "M"

    grep -q "Max turns: 40 (sonnet with M/L complexity)" "$LOG_FILE" || \
        fail "Max turns logging not found in log. Log: $(cat "$LOG_FILE")"
}

@test "run_stage logs max-turns value for sonnet with S-complexity" {
    source "$TEST_TMP/model-config.sh"
    timeout() {
        shift; shift; shift; shift
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    # implement+S resolves to haiku; use model_override to force sonnet + S hint
    run_stage "implement-task-1" "prompt" "test-schema.json" "" "S" "" "sonnet"

    grep -q "Max turns: 25 (sonnet with S/empty complexity)" "$LOG_FILE" || \
        fail "Max turns logging not found in log. Log: $(cat "$LOG_FILE")"
}

# -----------------------------------------------------------------------------
# pr / pr-review budgets are intentionally unchanged by the stage-type-aware
# override — verify they still get their original caps (10 / 10) and that the
# new MAX_TURNS_SIMPLIFY / MAX_TURNS_FIX_REVIEW env vars do not affect them.
# -----------------------------------------------------------------------------

@test "run_stage passes --max-turns 10 to pr stage (unchanged)" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    # pr is the exact match — PR creation budget is 10 turns (includes rebase headroom)
    run_stage "pr" "prompt" "test-schema.json" "" ""

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 10" "$claude_calls" || \
        fail "Expected --max-turns 10 for pr stage. Calls: $(cat "$claude_calls")"
}

@test "run_stage logs pr stage max-turns at default value (10)" {
    source "$TEST_TMP/model-config.sh"
    timeout() {
        shift; shift; shift; shift
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    run_stage "pr" "prompt" "test-schema.json" "" ""

    grep -q "Max turns: 10 (PR creation" "$LOG_FILE" || \
        fail "Expected PR creation max-turns log. Log: $(cat "$LOG_FILE")"
}

@test "run_stage honours MAX_TURNS_PR env var for pr stage" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout
    export MAX_TURNS_PR=8

    run_stage "pr" "prompt" "test-schema.json" "" ""

    unset MAX_TURNS_PR
    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 8" "$claude_calls" || \
        fail "Expected --max-turns 8 when MAX_TURNS_PR=8. Calls: $(cat "$claude_calls")"
}

@test "run_stage MAX_TURNS_PR is independent of MAX_TURNS_SIMPLIFY" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout
    export MAX_TURNS_PR=8
    export MAX_TURNS_SIMPLIFY=3

    run_stage "pr" "prompt" "test-schema.json" "" ""

    unset MAX_TURNS_PR MAX_TURNS_SIMPLIFY
    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 8" "$claude_calls" || \
        fail "Expected --max-turns 8 (MAX_TURNS_PR=8 with MAX_TURNS_SIMPLIFY=3). Calls: $(cat "$claude_calls")"
    grep -q -- "--max-turns 3" "$claude_calls" && \
        fail "pr stage must not be affected by MAX_TURNS_SIMPLIFY" || true
}

@test "run_stage passes --max-turns 10 to pr-review stage (unchanged)" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    # pr-review matches the "pr-review" prefix — focused diff analysis = 10 turns
    run_stage "pr-review-iter-1" "prompt" "test-schema.json" "" ""

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 10" "$claude_calls" || \
        fail "Expected --max-turns 10 for pr-review stage. Calls: $(cat "$claude_calls")"
}

@test "run_stage logs pr-review stage max-turns at original value (10)" {
    source "$TEST_TMP/model-config.sh"
    timeout() {
        shift; shift; shift; shift
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    run_stage "pr-review-iter-1" "prompt" "test-schema.json" "" ""

    grep -q "Max turns: 10 (PR review" "$LOG_FILE" || \
        fail "Expected PR review max-turns log. Log: $(cat "$LOG_FILE")"
}

@test "run_stage pr budget ignores MAX_TURNS_SIMPLIFY env var" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout
    export MAX_TURNS_SIMPLIFY=99

    run_stage "pr" "prompt" "test-schema.json" "" ""

    unset MAX_TURNS_SIMPLIFY
    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 10" "$claude_calls" || \
        fail "Expected --max-turns 10 (pr unchanged by MAX_TURNS_SIMPLIFY). Calls: $(cat "$claude_calls")"
    grep -q -- "--max-turns 99" "$claude_calls" && \
        fail "pr should not honour MAX_TURNS_SIMPLIFY" || true
}

@test "run_stage pr-review budget ignores MAX_TURNS_FIX_REVIEW env var" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout
    export MAX_TURNS_FIX_REVIEW=99

    run_stage "pr-review-iter-1" "prompt" "test-schema.json" "" ""

    unset MAX_TURNS_FIX_REVIEW
    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 10" "$claude_calls" || \
        fail "Expected --max-turns 10 (pr-review unchanged by MAX_TURNS_FIX_REVIEW). Calls: $(cat "$claude_calls")"
    grep -q -- "--max-turns 99" "$claude_calls" && \
        fail "pr-review should not honour MAX_TURNS_FIX_REVIEW" || true
}

# =============================================================================
# STAGE-TYPE-AWARE MAX-TURNS OVERRIDES (simplify + fix/fix-review-*)
# =============================================================================

@test "run_stage passes --max-turns 15 to haiku for simplify stage (default)" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    # simplify is a light-tier stage — resolves to haiku
    run_stage "simplify-task-1-iter-1" "prompt" "test-schema.json" "" ""

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 15" "$claude_calls" || \
        fail "Expected --max-turns 15 for simplify haiku. Calls: $(cat "$claude_calls")"
}

@test "run_stage respects MAX_TURNS_SIMPLIFY env var for simplify stage" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout
    export MAX_TURNS_SIMPLIFY=8

    run_stage "simplify-task-1-iter-1" "prompt" "test-schema.json" "" ""

    unset MAX_TURNS_SIMPLIFY
    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 8" "$claude_calls" || \
        fail "Expected --max-turns 8 (MAX_TURNS_SIMPLIFY=8). Calls: $(cat "$claude_calls")"
}

@test "run_stage uses default --max-turns 15 for simplify when MAX_TURNS_SIMPLIFY is unset" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout
    unset MAX_TURNS_SIMPLIFY

    run_stage "simplify-task-1-iter-1" "prompt" "test-schema.json" "" ""

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 15" "$claude_calls" || \
        fail "Expected default --max-turns 15 when MAX_TURNS_SIMPLIFY is unset. Calls: $(cat "$claude_calls")"
}

@test "run_stage logs simplify haiku cap with env var name" {
    source "$TEST_TMP/model-config.sh"
    timeout() {
        shift; shift; shift; shift
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    run_stage "simplify-task-1-iter-1" "prompt" "test-schema.json" "" ""

    grep -q "MAX_TURNS_SIMPLIFY" "$LOG_FILE" || \
        fail "Expected MAX_TURNS_SIMPLIFY in log. Log: $(cat "$LOG_FILE")"
}

@test "run_stage passes --max-turns 30 to sonnet for fix stage (default)" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    # fix is standard tier — resolves to sonnet; model_override ensures sonnet
    run_stage "fix-iter-1" "prompt" "test-schema.json" "" "" "" "sonnet"

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 30" "$claude_calls" || \
        fail "Expected --max-turns 30 for fix sonnet. Calls: $(cat "$claude_calls")"
}

@test "run_stage passes --max-turns 30 to sonnet for fix-review stage (default)" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    # fix-review-* matches the "fix" prefix; model_override ensures sonnet
    run_stage "fix-review-task-1-iter-1" "prompt" "test-schema.json" "" "" "" "sonnet"

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 30" "$claude_calls" || \
        fail "Expected --max-turns 30 for fix-review sonnet. Calls: $(cat "$claude_calls")"
}

@test "run_stage respects MAX_TURNS_FIX_REVIEW env var for fix stage" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout
    export MAX_TURNS_FIX_REVIEW=15

    run_stage "fix-iter-1" "prompt" "test-schema.json" "" "" "" "sonnet"

    unset MAX_TURNS_FIX_REVIEW
    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 15" "$claude_calls" || \
        fail "Expected --max-turns 15 (MAX_TURNS_FIX_REVIEW=15). Calls: $(cat "$claude_calls")"
}

@test "run_stage logs fix sonnet cap with env var name" {
    source "$TEST_TMP/model-config.sh"
    timeout() {
        shift; shift; shift; shift
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    run_stage "fix-iter-1" "prompt" "test-schema.json" "" "" "" "sonnet"

    grep -q "MAX_TURNS_FIX_REVIEW" "$LOG_FILE" || \
        fail "Expected MAX_TURNS_FIX_REVIEW in log. Log: $(cat "$LOG_FILE")"
}

@test "run_stage respects MAX_TURNS_FIX_REVIEW env var for fix-review stage" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout
    export MAX_TURNS_FIX_REVIEW=15

    run_stage "fix-review-task-1-iter-1" "prompt" "test-schema.json" "" "" "" "sonnet"

    unset MAX_TURNS_FIX_REVIEW
    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 15" "$claude_calls" || \
        fail "Expected --max-turns 15 (MAX_TURNS_FIX_REVIEW=15 for fix-review). Calls: $(cat "$claude_calls")"
}

@test "run_stage uses default --max-turns 30 for fix-review when MAX_TURNS_FIX_REVIEW is unset" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout
    unset MAX_TURNS_FIX_REVIEW

    run_stage "fix-review-task-1-iter-1" "prompt" "test-schema.json" "" "" "" "sonnet"

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 30" "$claude_calls" || \
        fail "Expected default --max-turns 30 when MAX_TURNS_FIX_REVIEW is unset. Calls: $(cat "$claude_calls")"
}

@test "run_stage does not apply simplify cap when model is not haiku" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    # simplify with model_override=sonnet must NOT get the 15-turn simplify cap
    run_stage "simplify-task-1-iter-1" "prompt" "test-schema.json" "" "" "" "sonnet"

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 15" "$claude_calls" && \
        fail "Should not apply --max-turns 15 simplify cap when model is sonnet" || true
}

@test "run_stage does not apply fix cap when model is not sonnet" {
    source "$TEST_TMP/model-config.sh"
    local claude_calls="$TEST_TMP/claude-calls.txt"
    timeout() {
        shift; shift; shift; shift
        echo "$@" >> "$claude_calls"
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout

    # fix with model_override=opus must NOT get the 30-turn fix cap
    run_stage "fix-iter-1" "prompt" "test-schema.json" "" "" "" "opus"

    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--max-turns 30" "$claude_calls" && \
        fail "Should not apply --max-turns 30 fix cap when model is opus" || true
}

# =============================================================================
# _APPLY_STAGE_ACTION — STAGE_RESULT ENVELOPE SHAPE
#
# The same 4 escalation behaviors (max_turns, timeout, empty, structured-error)
# expressed via the stage_result + _apply_stage_action interface
# (issue #178 PR-A, task 4). No behavior change — these tests verify the new
# dispatch surface is consistent with the run_stage test assertions above.
#
# Convention: bail exits 1 and emits the envelope; accept/escalate/retry_same
# exit 0 and emit the envelope.  The error_kind field in the envelope
# identifies which escalation path triggered the bail/escalate decision.
# =============================================================================

@test "_apply_stage_action: bail exits 1 and preserves error_kind for max_turns_exhausted_at_ceiling" {
	# max_turns behavior: run_stage calls _apply_stage_action with bail when
	# opus (ceiling) hits error_max_turns. The envelope must survive intact so
	# callers can inspect error_kind without re-running the stage.
	local stage_result
	stage_result=$(jq -nc '{
		status: "error",
		output: null,
		raw: "{\"subtype\":\"error_max_turns\"}",
		denials: [],
		model: "opus",
		error_kind: "max_turns_exhausted_at_ceiling",
		elapsed_ms: 5000
	}')

	run _apply_stage_action "$stage_result" "bail" "max_turns_exhausted_at_ceiling"
	[ "$status" -eq 1 ]

	# Envelope must be emitted on stdout so callers can inspect error_kind.
	local emitted_envelope
	emitted_envelope=$(printf '%s' "$output" | grep '^{' | tail -1)
	[ -n "$emitted_envelope" ] || \
		fail "_apply_stage_action bail must emit stage_result on stdout"

	local error_kind
	error_kind=$(printf '%s' "$emitted_envelope" | jq -r '.error_kind // empty')
	[ "$error_kind" = "max_turns_exhausted_at_ceiling" ] || \
		fail "Expected error_kind=max_turns_exhausted_at_ceiling, got: $error_kind"

	local envelope_status
	envelope_status=$(printf '%s' "$emitted_envelope" | jq -r '.status')
	[ "$envelope_status" = "error" ] || \
		fail "Expected envelope status=error, got: $envelope_status"
}

@test "_apply_stage_action: bail exits 1 and preserves error_kind for timeout" {
	# timeout behavior: run_stage calls _apply_stage_action with bail when
	# both initial attempt and retry time out at the ceiling model.
	local stage_result
	stage_result=$(jq -nc '{
		status: "error",
		output: null,
		raw: "",
		denials: [],
		model: "opus",
		error_kind: "timeout",
		elapsed_ms: 60000
	}')

	run _apply_stage_action "$stage_result" "bail" "timeout"
	[ "$status" -eq 1 ]

	local emitted_envelope
	emitted_envelope=$(printf '%s' "$output" | grep '^{' | tail -1)
	[ -n "$emitted_envelope" ] || \
		fail "_apply_stage_action bail must emit stage_result on stdout"

	local error_kind
	error_kind=$(printf '%s' "$emitted_envelope" | jq -r '.error_kind // empty')
	[ "$error_kind" = "timeout" ] || \
		fail "Expected error_kind=timeout, got: $error_kind"

	local envelope_status
	envelope_status=$(printf '%s' "$emitted_envelope" | jq -r '.status')
	[ "$envelope_status" = "error" ] || \
		fail "Expected envelope status=error, got: $envelope_status"
}

@test "_apply_stage_action: bail exits 1 and preserves error_kind for no_structured_output" {
	# empty behavior: run_stage calls _apply_stage_action with bail when no
	# structured output can be extracted even after escalation attempts.
	local stage_result
	stage_result=$(jq -nc '{
		status: "error",
		output: null,
		raw: "{\"result\":\"some text\",\"is_error\":true}",
		denials: [],
		model: "sonnet",
		error_kind: "no_structured_output",
		elapsed_ms: 10000
	}')

	run _apply_stage_action "$stage_result" "bail" "no_structured_output"
	[ "$status" -eq 1 ]

	local emitted_envelope
	emitted_envelope=$(printf '%s' "$output" | grep '^{' | tail -1)
	[ -n "$emitted_envelope" ] || \
		fail "_apply_stage_action bail must emit stage_result on stdout"

	local error_kind
	error_kind=$(printf '%s' "$emitted_envelope" | jq -r '.error_kind // empty')
	[ "$error_kind" = "no_structured_output" ] || \
		fail "Expected error_kind=no_structured_output, got: $error_kind"

	local envelope_status
	envelope_status=$(printf '%s' "$emitted_envelope" | jq -r '.status')
	[ "$envelope_status" = "error" ] || \
		fail "Expected envelope status=error, got: $envelope_status"
}

@test "_apply_stage_action: escalate exits 0 and emits envelope for structured_error" {
	# structured-error behavior: run_stage calls _apply_stage_action with
	# escalate when the agent returned status:error without permission_denials.
	# The shim emits the envelope and exits 0; the re-run lives in run_stage
	# (PR-A pass-through; PR-B will invoke escalation-policy skill here).
	local stage_result
	stage_result=$(jq -nc '{
		status: "error",
		output: {status: "error", error: "first attempt failed"},
		raw: "{\"structured_output\":{\"status\":\"error\"}}",
		denials: [],
		model: "haiku",
		error_kind: null,
		elapsed_ms: 3000
	}')

	run _apply_stage_action "$stage_result" "escalate" "structured_error"
	[ "$status" -eq 0 ]

	# Envelope must be emitted so callers can inspect output.status.
	local emitted_envelope
	emitted_envelope=$(printf '%s' "$output" | grep '^{' | tail -1)
	[ -n "$emitted_envelope" ] || \
		fail "_apply_stage_action escalate must emit stage_result on stdout"

	# The structured error's .output.status must survive in the emitted envelope
	# so the caller (run_stage / future PR-B skill) can act on the original result.
	local agent_status
	agent_status=$(printf '%s' "$emitted_envelope" | jq -r '.output.status // empty')
	[ "$agent_status" = "error" ] || \
		fail "Expected output.status=error in emitted envelope, got: $agent_status"
}

@test "_apply_stage_action: retry_same exits 0 and emits stage_result envelope unchanged" {
	# retry_same behavior: run_stage calls _apply_stage_action with retry_same
	# for rate-limit scenarios. The shim must emit the envelope and return 0 so
	# the caller can re-issue the stage; the envelope must survive intact.
	local stage_result
	stage_result=$(jq -nc '{
		status: "error",
		output: null,
		raw: "{\"result\":\"rate limited\",\"is_error\":true}",
		denials: [],
		model: "sonnet",
		error_kind: "rate_limit",
		elapsed_ms: 2000
	}')

	run _apply_stage_action "$stage_result" "retry_same" "rate_limit"
	[ "$status" -eq 0 ]

	# Envelope must be emitted on stdout so callers can inspect stage_result.
	local emitted_envelope
	emitted_envelope=$(printf '%s' "$output" | grep '^{' | tail -1)
	[ -n "$emitted_envelope" ] || \
		fail "_apply_stage_action retry_same must emit stage_result on stdout"

	# The error_kind must survive unchanged so the caller knows why retry was
	# requested (PR-B will use this to drive the retry decision).
	local error_kind
	error_kind=$(printf '%s' "$emitted_envelope" | jq -r '.error_kind // empty')
	[ "$error_kind" = "rate_limit" ] || \
		fail "Expected error_kind=rate_limit in emitted envelope, got: $error_kind"
}
