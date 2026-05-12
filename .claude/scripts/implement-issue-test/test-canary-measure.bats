#!/usr/bin/env bats
#
# test-canary-measure.bats
#
# Tests for .claude/scripts/canary-measure.sh — the measurement tool that
# aggregates wall-clock and token usage per issue, used to gate AC5 of
# issue #179 (tokens-per-issue regression ≤ 10%, wall-clock regression ≤ 25%).
#
# Contract under test:
#   - Reads metrics.json files (one per issue) from --logs-dir
#   - Reads transcript JSONL files from --transcripts-dir
#   - Matches transcripts to issues by `cwd` field (worktree path or log dir)
#   - Outputs per-issue and aggregate stats as JSON or markdown
#
# Test cases:
#   (a) emits one row per metrics.json with wall-clock seconds
#   (b) sums tokens from matching transcripts (input + output + cache_*)
#   (c) markdown output includes summary table
#   (d) --label tags the output for before/after comparison
#   (e) compute-deltas mode reports % change between two reports
#

load 'helpers/test-helper.bash'

CANARY_SCRIPT=""

setup() {
    setup_test_env
    CANARY_SCRIPT="$SCRIPT_DIR/canary-measure.sh"
}

teardown() {
    teardown_test_env
}

# Build a fake metrics.json under TEST_TMP/logs/implement-issue/issue-N-TS/
make_metrics() {
    local issue="$1"
    local started="$2"
    local completed="$3"
    local duration="$4"
    local ts_dir="20260504-${issue}0000"
    local log_dir="$TEST_TMP/logs/implement-issue/issue-${issue}-${ts_dir}"
    mkdir -p "$log_dir"
    cat >"$log_dir/metrics.json" <<EOF
{
  "schema_version": "1",
  "issue": "${issue}",
  "base_branch": "main",
  "branch": "feature/issue-${issue}",
  "state": "completed",
  "started_at": "${started}",
  "completed_at": "${completed}",
  "total_duration_seconds": ${duration},
  "stages": {}
}
EOF
    printf '%s\n' "$log_dir"
}

# Build a fake transcript JSONL under TEST_TMP/transcripts/<mangled>/
make_transcript() {
    local mangled="$1"
    local input="$2"
    local cache_creation="$3"
    local cache_read="$4"
    local output="$5"
    local cwd="$6"
    local ts="$7"
    local dir="$TEST_TMP/transcripts/${mangled}"
    mkdir -p "$dir"
    cat >>"$dir/session.jsonl" <<EOF
{"type":"assistant","timestamp":"${ts}","cwd":"${cwd}","message":{"usage":{"input_tokens":${input},"cache_creation_input_tokens":${cache_creation},"cache_read_input_tokens":${cache_read},"output_tokens":${output}}}}
EOF
}

@test "(a) emits one row per metrics.json with wall-clock seconds" {
    [[ -x "$CANARY_SCRIPT" ]] || skip "canary-measure.sh not present yet"

    make_metrics 100 "2026-05-04T01:00:00Z" "2026-05-04T01:10:00Z" 600
    make_metrics 101 "2026-05-04T02:00:00Z" "2026-05-04T02:30:00Z" 1800

    run bash "$CANARY_SCRIPT" \
        --logs-dir "$TEST_TMP/logs/implement-issue" \
        --transcripts-dir "$TEST_TMP/transcripts" \
        --format json

    [ "$status" -eq 0 ]
    issue_count=$(printf '%s' "$output" | jq '.issues | length')
    [ "$issue_count" -eq 2 ]

    wall_100=$(printf '%s' "$output" | jq '.issues[] | select(.issue=="100") | .wall_clock_seconds')
    [ "$wall_100" -eq 600 ]
    wall_101=$(printf '%s' "$output" | jq '.issues[] | select(.issue=="101") | .wall_clock_seconds')
    [ "$wall_101" -eq 1800 ]
}

@test "(b) sums tokens from matching transcripts" {
    [[ -x "$CANARY_SCRIPT" ]] || skip "canary-measure.sh not present yet"

    log_dir=$(make_metrics 200 "2026-05-04T01:00:00Z" "2026-05-04T01:10:00Z" 600)

    # Two transcripts whose cwd field matches the issue log dir or its worktrees
    make_transcript "session-a" 100 1000 5000 50 \
        "${log_dir}" "2026-05-04T01:01:00Z"
    make_transcript "session-b" 200 0 0 75 \
        "${log_dir}/worktrees/task-1" "2026-05-04T01:02:00Z"
    # An unrelated transcript that should NOT count (different cwd)
    make_transcript "session-c" 999 999 999 999 \
        "/some/other/path" "2026-05-04T01:03:00Z"

    run bash "$CANARY_SCRIPT" \
        --logs-dir "$TEST_TMP/logs/implement-issue" \
        --transcripts-dir "$TEST_TMP/transcripts" \
        --format json

    [ "$status" -eq 0 ]
    input=$(printf '%s' "$output" | jq '.issues[0].input_tokens')
    output_t=$(printf '%s' "$output" | jq '.issues[0].output_tokens')
    cache_c=$(printf '%s' "$output" | jq '.issues[0].cache_creation_input_tokens')
    cache_r=$(printf '%s' "$output" | jq '.issues[0].cache_read_input_tokens')
    [ "$input" -eq 300 ]      # 100 + 200
    [ "$output_t" -eq 125 ]   # 50 + 75
    [ "$cache_c" -eq 1000 ]
    [ "$cache_r" -eq 5000 ]
}

@test "(c) markdown output includes summary table" {
    [[ -x "$CANARY_SCRIPT" ]] || skip "canary-measure.sh not present yet"

    make_metrics 300 "2026-05-04T01:00:00Z" "2026-05-04T01:10:00Z" 600
    make_metrics 301 "2026-05-04T02:00:00Z" "2026-05-04T02:30:00Z" 1800

    run bash "$CANARY_SCRIPT" \
        --logs-dir "$TEST_TMP/logs/implement-issue" \
        --transcripts-dir "$TEST_TMP/transcripts" \
        --format markdown

    [ "$status" -eq 0 ]
    [[ "$output" == *"| Issue |"* ]]
    [[ "$output" == *"300"* ]]
    [[ "$output" == *"301"* ]]
    [[ "$output" == *"Median wall-clock"* ]]
}

@test "(d) --label tags the output for before/after comparison" {
    [[ -x "$CANARY_SCRIPT" ]] || skip "canary-measure.sh not present yet"

    make_metrics 400 "2026-05-04T01:00:00Z" "2026-05-04T01:10:00Z" 600

    run bash "$CANARY_SCRIPT" \
        --logs-dir "$TEST_TMP/logs/implement-issue" \
        --transcripts-dir "$TEST_TMP/transcripts" \
        --label "subprocess-baseline" \
        --format json

    [ "$status" -eq 0 ]
    label=$(printf '%s' "$output" | jq -r '.label')
    [ "$label" = "subprocess-baseline" ]
}

@test "(e) --compute-deltas reports percentage change between two reports" {
    [[ -x "$CANARY_SCRIPT" ]] || skip "canary-measure.sh not present yet"

    cat >"$TEST_TMP/before.json" <<'EOF'
{
  "label": "before",
  "summary": {
    "wall_clock_total": 1000,
    "wall_clock_median": 500,
    "tokens_total": 100000,
    "tokens_median": 50000
  }
}
EOF
    cat >"$TEST_TMP/after.json" <<'EOF'
{
  "label": "after",
  "summary": {
    "wall_clock_total": 1100,
    "wall_clock_median": 550,
    "tokens_total": 95000,
    "tokens_median": 47500
  }
}
EOF

    run bash "$CANARY_SCRIPT" \
        --compute-deltas \
        --before "$TEST_TMP/before.json" \
        --after "$TEST_TMP/after.json" \
        --format json

    [ "$status" -eq 0 ]
    wall_pct=$(printf '%s' "$output" | jq '.deltas.wall_clock_median_pct')
    tok_pct=$(printf '%s' "$output" | jq '.deltas.tokens_median_pct')
    # 550/500 = +10%, 47500/50000 = -5%
    [ "$wall_pct" = "10" ]
    [ "$tok_pct" = "-5" ]
}
