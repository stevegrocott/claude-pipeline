#!/usr/bin/env bats
#
# test-event-emit.bats
# Tests for event-emit.sh: JSONL append, schema validation, concurrency,
# and events-prune.sh integration.
#

load 'helpers/test-helper.bash'

# Absolute paths resolved once at load time
EVENT_EMIT_SCRIPT="$SCRIPT_DIR/event-emit.sh"
PRUNE_SCRIPT="$(cd "$SCRIPT_DIR/../../tools" 2>/dev/null && pwd)/events-prune.sh"

setup() {
	setup_test_env
	export LOG_DIR="$TEST_TMP/logs"
	mkdir -p "$LOG_DIR"
}

teardown() {
	teardown_test_env
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Minimal valid stage_start event (all required top-level + oneOf fields)
_valid_event() {
	printf '%s' \
		'{"ts":"2026-01-01T00:00:00Z","run_id":"test-run","stage":"test",' \
		'"event":"stage_start","model":"claude-haiku"}'
}

# Minimal valid stage_end event
_valid_stage_end() {
	printf '%s' \
		'{"ts":"2026-01-01T00:00:01Z","run_id":"test-run","stage":"test",' \
		'"event":"stage_end","status":"success"}'
}

# =============================================================================
# (a) VALID EVENT APPENDS EXACTLY ONE LINE
# =============================================================================

@test "(a) valid event appends one JSONL line to events.jsonl" {
	local event
	event=$(_valid_event)

	run bash "$EVENT_EMIT_SCRIPT" "$event"
	[ "$status" -eq 0 ]

	local events_file="$LOG_DIR/events.jsonl"
	[ -f "$events_file" ] || {
		echo "events.jsonl was not created" >&2
		return 1
	}

	local line_count
	line_count=$(wc -l < "$events_file")
	[ "$line_count" -eq 1 ]
}

@test "(a) appended line is valid JSON matching the emitted event" {
	local event
	event=$(_valid_event)

	run bash "$EVENT_EMIT_SCRIPT" "$event"
	[ "$status" -eq 0 ]

	local events_file="$LOG_DIR/events.jsonl"
	local stored_event
	stored_event=$(head -1 "$events_file")

	# Must be parseable JSON
	printf '%s' "$stored_event" | jq -e '.' > /dev/null

	# Key fields must round-trip
	local stored_event_type
	stored_event_type=$(printf '%s' "$stored_event" | jq -r '.event')
	[ "$stored_event_type" = "stage_start" ]

	local stored_run_id
	stored_run_id=$(printf '%s' "$stored_event" | jq -r '.run_id')
	[ "$stored_run_id" = "test-run" ]
}

@test "(a) second valid event appends a second line (no truncation)" {
	local e1 e2
	e1=$(_valid_event)
	e2=$(_valid_stage_end)

	run bash "$EVENT_EMIT_SCRIPT" "$e1"
	[ "$status" -eq 0 ]

	run bash "$EVENT_EMIT_SCRIPT" "$e2"
	[ "$status" -eq 0 ]

	local events_file="$LOG_DIR/events.jsonl"
	local line_count
	line_count=$(wc -l < "$events_file")
	[ "$line_count" -eq 2 ]
}

@test "(a) events.jsonl is created when LOG_DIR does not yet exist" {
	local fresh_dir="$TEST_TMP/fresh_logs"
	local event
	event=$(_valid_event)

	LOG_DIR="$fresh_dir" run bash "$EVENT_EMIT_SCRIPT" "$event"
	[ "$status" -eq 0 ]
	[ -f "$fresh_dir/events.jsonl" ]
}

# =============================================================================
# (b) SCHEMA-INVALID EVENTS ARE REJECTED
# =============================================================================

@test "(b) event missing required field 'ts' is rejected with exit 1" {
	local event='{"run_id":"r","stage":"s","event":"stage_start","model":"m"}'

	run bash "$EVENT_EMIT_SCRIPT" "$event"
	[ "$status" -eq 1 ]
}

@test "(b) rejected event is NOT appended to events.jsonl" {
	local event='{"run_id":"r","stage":"s","event":"stage_start","model":"m"}'

	run bash "$EVENT_EMIT_SCRIPT" "$event"
	[ "$status" -eq 1 ]

	local events_file="$LOG_DIR/events.jsonl"
	# File should not exist, or if it does, it must have 0 lines
	if [ -f "$events_file" ]; then
		local line_count
		line_count=$(wc -l < "$events_file")
		[ "$line_count" -eq 0 ]
	fi
}

@test "(b) event with unknown 'event' enum value is rejected with exit 1" {
	local event
	event='{"ts":"2026-01-01T00:00:00Z","run_id":"r","stage":"s",'
	event+='"event":"not_a_real_event_type"}'

	run bash "$EVENT_EMIT_SCRIPT" "$event"
	[ "$status" -eq 1 ]
}

@test "(b) non-JSON argument is rejected with exit 1" {
	run bash "$EVENT_EMIT_SCRIPT" "this is not json at all"
	[ "$status" -eq 1 ]
}

@test "(b) escalation event missing 'reason' field is rejected" {
	# oneOf for escalation requires: event, reason, from_model, to_model
	local event
	event='{"ts":"2026-01-01T00:00:00Z","run_id":"r","stage":"s",'
	event+='"event":"escalation","from_model":"haiku","to_model":"sonnet"}'

	run bash "$EVENT_EMIT_SCRIPT" "$event"
	[ "$status" -eq 1 ]
}

@test "(b) retry event missing 'attempt' field is rejected" {
	local event
	event='{"ts":"2026-01-01T00:00:00Z","run_id":"r","stage":"s",'
	event+='"event":"retry","reason":"timeout","max_attempts":3}'

	run bash "$EVENT_EMIT_SCRIPT" "$event"
	[ "$status" -eq 1 ]
}

@test "(b) no argument produces usage error with exit 2" {
	run bash "$EVENT_EMIT_SCRIPT"
	[ "$status" -eq 2 ]
}

@test "(b) LOG_DIR unset produces environment error with exit 3" {
	local event
	event=$(_valid_event)

	run env -u LOG_DIR bash "$EVENT_EMIT_SCRIPT" "$event"
	[ "$status" -eq 3 ]
}

# =============================================================================
# (c) CONCURRENT EMITS DO NOT CORRUPT THE FILE
# =============================================================================

@test "(c) 10 concurrent emits each append exactly one line (no corruption)" {
	local events_file="$LOG_DIR/events.jsonl"
	local pids=()
	local i

	for i in {1..10}; do
		local pad
		pad=$(printf '%02d' "$i")
		local ev
		ev='{"ts":"2026-01-01T00:00:'"$pad"'Z","run_id":"r'"$i"'",'
		ev+='"stage":"test","event":"stage_start","model":"m"}'
		LOG_DIR="$LOG_DIR" bash "$EVENT_EMIT_SCRIPT" "$ev" &
		pids+=($!)
	done

	# Wait for all background jobs to complete
	local failed=0
	for pid in "${pids[@]}"; do
		wait "$pid" || (( failed++ )) || true
	done

	[ "$failed" -eq 0 ] || {
		echo "$failed concurrent emitter(s) exited non-zero" >&2
		return 1
	}

	# Every line must be independently valid JSON
	local bad_lines=0
	while IFS= read -r line; do
		if ! printf '%s' "$line" | jq -e '.' > /dev/null 2>&1; then
			(( bad_lines++ )) || true
		fi
	done < "$events_file"

	[ "$bad_lines" -eq 0 ] || {
		echo "$bad_lines corrupted line(s) found in events.jsonl" >&2
		return 1
	}

	# Exactly 10 lines must be present
	local line_count
	line_count=$(wc -l < "$events_file")
	[ "$line_count" -eq 10 ]
}

@test "(c) flock path: concurrent writes with flock available produce valid JSONL" {
	# Explicitly verify the flock code-path is exercised when flock exists
	if ! command -v flock > /dev/null 2>&1; then
		skip "flock not available on this platform"
	fi

	local events_file="$LOG_DIR/events.jsonl"
	local pids=()
	local i

	for i in {1..5}; do
		local pad
		pad=$(printf '%02d' "$i")
		local ev
		ev='{"ts":"2026-01-01T00:01:'"$pad"'Z","run_id":"flock-'"$i"'",'
		ev+='"stage":"test","event":"stage_end","status":"success"}'
		LOG_DIR="$LOG_DIR" bash "$EVENT_EMIT_SCRIPT" "$ev" &
		pids+=($!)
	done

	for pid in "${pids[@]}"; do
		wait "$pid"
	done

	local line_count
	line_count=$(wc -l < "$events_file")
	[ "$line_count" -eq 5 ]

	# Validate each line parses cleanly
	while IFS= read -r line; do
		printf '%s' "$line" | jq -e '.' > /dev/null
	done < "$events_file"
}

@test "(c) sequential emits after concurrent batch preserve all prior lines" {
	local events_file="$LOG_DIR/events.jsonl"
	local pids=()
	local i

	# First: 5 concurrent
	for i in {1..5}; do
		local pad
		pad=$(printf '%02d' "$i")
		local ev
		ev='{"ts":"2026-01-01T00:02:'"$pad"'Z","run_id":"seq-'"$i"'",'
		ev+='"stage":"test","event":"stage_start","model":"m"}'
		LOG_DIR="$LOG_DIR" bash "$EVENT_EMIT_SCRIPT" "$ev" &
		pids+=($!)
	done
	for pid in "${pids[@]}"; do
		wait "$pid"
	done

	# Then: 1 sequential
	local ev_seq
	ev_seq='{"ts":"2026-01-01T00:02:06Z","run_id":"seq-6",'
	ev_seq+='"stage":"test","event":"stage_end","status":"success"}'
	run bash "$EVENT_EMIT_SCRIPT" "$ev_seq"
	[ "$status" -eq 0 ]

	local line_count
	line_count=$(wc -l < "$events_file")
	[ "$line_count" -eq 6 ]
}

# =============================================================================
# (d) events-prune.sh PRUNES >30-DAY-OLD events.jsonl FILES
# =============================================================================

@test "(d) prune script exists and is executable" {
	[ -f "$PRUNE_SCRIPT" ] || {
		echo "tools/events-prune.sh not found at: $PRUNE_SCRIPT" >&2
		return 1
	}
	[ -x "$PRUNE_SCRIPT" ]
}

@test "(d) prune script deletes events.jsonl files older than 30 days" {
	local old_dir="$TEST_TMP/old_run/logs"
	mkdir -p "$old_dir"
	printf '%s\n' \
		'{"ts":"2020-01-01T00:00:00Z","run_id":"old","stage":"s","event":"stage_end","status":"success"}' \
		> "$old_dir/events.jsonl"

	# Back-date the file to 31 days ago (portable: use touch -t)
	local old_date
	old_date=$(date -d "31 days ago" +"%Y%m%d%H%M" 2>/dev/null \
		|| date -v-31d +"%Y%m%d%H%M" 2>/dev/null) \
		|| { skip "cannot back-date file on this platform"; return; }

	touch -t "${old_date}" "$old_dir/events.jsonl"

	run bash "$PRUNE_SCRIPT" "$TEST_TMP"
	[ "$status" -eq 0 ]

	[ ! -f "$old_dir/events.jsonl" ] || {
		echo "Old events.jsonl was not removed" >&2
		return 1
	}
}

@test "(d) prune script keeps events.jsonl files newer than 30 days" {
	local new_dir="$TEST_TMP/new_run/logs"
	mkdir -p "$new_dir"
	printf '%s\n' \
		'{"ts":"2026-01-01T00:00:00Z","run_id":"new","stage":"s","event":"stage_end","status":"success"}' \
		> "$new_dir/events.jsonl"

	run bash "$PRUNE_SCRIPT" "$TEST_TMP"
	[ "$status" -eq 0 ]

	[ -f "$new_dir/events.jsonl" ] || {
		echo "Recent events.jsonl was incorrectly removed" >&2
		return 1
	}
}

@test "(d) prune script --dry-run does not delete files" {
	local old_dir="$TEST_TMP/dry_run_test/logs"
	mkdir -p "$old_dir"
	printf '%s\n' '{}' > "$old_dir/events.jsonl"

	local old_date
	old_date=$(date -d "40 days ago" +"%Y%m%d%H%M" 2>/dev/null \
		|| date -v-40d +"%Y%m%d%H%M" 2>/dev/null) \
		|| { skip "cannot back-date file on this platform"; return; }

	touch -t "${old_date}" "$old_dir/events.jsonl"

	run bash "$PRUNE_SCRIPT" --dry-run "$TEST_TMP"
	[ "$status" -eq 0 ]

	[ -f "$old_dir/events.jsonl" ] || {
		echo "dry-run deleted the file when it should not have" >&2
		return 1
	}
}

@test "(d) prune script --max-age-days custom threshold prunes matching file" {
	local dir="$TEST_TMP/custom_age/logs"
	mkdir -p "$dir"
	printf '%s\n' '{}' > "$dir/events.jsonl"

	# Back-date the file to 2 days ago so --max-age-days 1 matches it
	local old_date
	old_date=$(date -d "2 days ago" +"%Y%m%d%H%M" 2>/dev/null \
		|| date -v-2d +"%Y%m%d%H%M" 2>/dev/null) \
		|| { skip "cannot back-date file on this platform"; return; }

	touch -t "${old_date}" "$dir/events.jsonl"

	run bash "$PRUNE_SCRIPT" --max-age-days 1 "$TEST_TMP"
	[ "$status" -eq 0 ]

	[ ! -f "$dir/events.jsonl" ] || {
		echo "events.jsonl should have been pruned by --max-age-days 1" >&2
		return 1
	}
}

@test "(d) prune script with empty directory exits 0 (nothing to do)" {
	local empty="$TEST_TMP/empty_search"
	mkdir -p "$empty"

	run bash "$PRUNE_SCRIPT" "$empty"
	[ "$status" -eq 0 ]
}

@test "(d) prune script without argument exits 1 with usage hint" {
	run bash "$PRUNE_SCRIPT"
	[ "$status" -eq 1 ]
	[[ "$output" == *"error"* ]]
}

@test "(d) prune script prunes only events.jsonl — not other old log files" {
	local dir="$TEST_TMP/mixed/logs"
	mkdir -p "$dir"
	printf '%s\n' 'data' > "$dir/events.jsonl"
	printf '%s\n' 'log' > "$dir/orchestrator.log"

	local old_date
	old_date=$(date -d "35 days ago" +"%Y%m%d%H%M" 2>/dev/null \
		|| date -v-35d +"%Y%m%d%H%M" 2>/dev/null) \
		|| { skip "cannot back-date file on this platform"; return; }

	touch -t "${old_date}" "$dir/events.jsonl" "$dir/orchestrator.log"

	run bash "$PRUNE_SCRIPT" "$TEST_TMP"
	[ "$status" -eq 0 ]

	[ ! -f "$dir/events.jsonl" ] || {
		echo "events.jsonl should have been pruned" >&2
		return 1
	}
	[ -f "$dir/orchestrator.log" ] || {
		echo "orchestrator.log should NOT have been pruned" >&2
		return 1
	}
}
