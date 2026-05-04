#!/usr/bin/env bats
#
# test-feedback-record.bats
#
# Tests for .claude/scripts/feedback-record.sh — the bash helper that the
# pipeline-feedback skill invokes to append a structured JSONL record to
# logs/feedback/<kind>.jsonl.
#
# Contract under test (from issue #176):
#   - Accepts --kind, --issue, --observed, --expected, --evidence, --notes
#   - Validates against .claude/scripts/schemas/pipeline-feedback.json via jq
#   - Appends one JSONL line to logs/feedback/<kind>.jsonl (relative to CWD)
#   - Rejects invalid kinds and missing required fields with non-zero exit
#   - Idempotent on identical record within a 60s window
#
# Test cases (per task 4 of issue #176):
#   (a) valid record appends one line
#   (b) invalid kind rejected with non-zero exit
#   (c) missing required field rejected
#   (d) idempotent on duplicate within 60s
#

load 'helpers/test-helper.bash'

# Path to the script under test (resolved against the real repo, not TEST_TMP)
FEEDBACK_SCRIPT=""

setup() {
    setup_test_env

    FEEDBACK_SCRIPT="$SCRIPT_DIR/feedback-record.sh"

    # Ensure schemas dir exists in TEST_TMP and contains the pipeline-feedback
    # schema if the real one is present. The script needs to find this for jq
    # validation; we mirror the real layout under TEST_TMP/.claude/scripts.
    mkdir -p "$TEST_TMP/.claude/scripts/schemas"
    if [[ -f "$SCRIPT_DIR/schemas/pipeline-feedback.json" ]]; then
        cp "$SCRIPT_DIR/schemas/pipeline-feedback.json" \
            "$TEST_TMP/.claude/scripts/schemas/pipeline-feedback.json"
    fi

    # Some scripts in this repo resolve paths via CLAUDE_PROJECT_DIR; export
    # it so the script can locate the schema regardless of CWD.
    export CLAUDE_PROJECT_DIR="$TEST_TMP"

    # Tests run from TEST_TMP so logs/feedback/ lands in the temp dir.
    cd "$TEST_TMP" || return 1
}

teardown() {
    teardown_test_env
}

# =============================================================================
# HELPERS
# =============================================================================

# Run the feedback-record script with the given args. Captures status/output
# via bats `run`, so callers can assert on `$status` and `$output`.
run_feedback() {
    run bash "$FEEDBACK_SCRIPT" "$@"
}

# =============================================================================
# (a) VALID RECORD APPENDS ONE LINE
# =============================================================================

@test "(a) valid record appends one line to logs/feedback/<kind>.jsonl" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    run_feedback \
        --kind triage_misclassification \
        --issue 2840 \
        --observed fast_path \
        --expected full \
        --evidence "logs/triage/issue-2840.json" \
        --notes "Security concern missed"

    [ "$status" -eq 0 ]

    local jsonl="logs/feedback/triage_misclassification.jsonl"
    [ -f "$jsonl" ] || { echo "expected $jsonl to exist"; return 1; }

    local line_count
    line_count=$(wc -l < "$jsonl" | tr -d ' ')
    [ "$line_count" = "1" ]
}

@test "(a) appended record is valid JSON with all expected fields" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    run_feedback \
        --kind prompt_regression \
        --issue 2841 \
        --observed "verbose output" \
        --expected "concise output" \
        --evidence "logs/run/2841.log" \
        --notes "Regression after model bump"

    [ "$status" -eq 0 ]

    local jsonl="logs/feedback/prompt_regression.jsonl"
    [ -f "$jsonl" ]

    # Line must be valid JSON
    jq -e '.' < "$jsonl" >/dev/null

    # Required fields populated
    local kind issue observed expected
    kind=$(jq -r '.kind' < "$jsonl")
    issue=$(jq -r '.issue' < "$jsonl")
    observed=$(jq -r '.observed' < "$jsonl")
    expected=$(jq -r '.expected' < "$jsonl")

    [ "$kind" = "prompt_regression" ]
    [ "$issue" = "2841" ]
    [ "$observed" = "verbose output" ]
    [ "$expected" = "concise output" ]

    # Timestamp must be present and non-empty
    local ts
    ts=$(jq -r '.timestamp' < "$jsonl")
    [ -n "$ts" ]
    [ "$ts" != "null" ]
}

@test "(a) two distinct records append two lines to the same kind file" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    run_feedback \
        --kind agent_misroute \
        --issue 2850 \
        --observed "code-reviewer" \
        --expected "test-engineer" \
        --evidence "logs/dispatch/2850.json" \
        --notes "First observation"
    [ "$status" -eq 0 ]

    run_feedback \
        --kind agent_misroute \
        --issue 2851 \
        --observed "fullstack-engineer" \
        --expected "tdd-expert" \
        --evidence "logs/dispatch/2851.json" \
        --notes "Second observation"
    [ "$status" -eq 0 ]

    local jsonl="logs/feedback/agent_misroute.jsonl"
    local line_count
    line_count=$(wc -l < "$jsonl" | tr -d ' ')
    [ "$line_count" = "2" ]
}

@test "(a) different kinds write to different files" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    run_feedback \
        --kind criterion_drift \
        --issue 2860 \
        --observed "stale criterion" \
        --expected "updated criterion" \
        --evidence "logs/criteria/2860.md" \
        --notes "Drift after rubric update"
    [ "$status" -eq 0 ]

    run_feedback \
        --kind escalation_loop \
        --issue 2861 \
        --observed "5 escalations" \
        --expected "1 escalation" \
        --evidence "logs/escalation/2861.json" \
        --notes "Loop in quality stage"
    [ "$status" -eq 0 ]

    [ -f "logs/feedback/criterion_drift.jsonl" ]
    [ -f "logs/feedback/escalation_loop.jsonl" ]
}

# =============================================================================
# (b) INVALID KIND REJECTED WITH NON-ZERO EXIT
# =============================================================================

@test "(b) invalid kind rejected with non-zero exit" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    run_feedback \
        --kind not_a_real_kind \
        --issue 2870 \
        --observed "x" \
        --expected "y" \
        --evidence "logs/x" \
        --notes "n"

    [ "$status" -ne 0 ]
    # Error must be actionable — mention the bad kind or list valid kinds.
    [[ "$output" == *"kind"* ]] || [[ "$output" == *"not_a_real_kind"* ]]
}

@test "(b) invalid kind does not create a JSONL file" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    run_feedback \
        --kind bogus_kind \
        --issue 2871 \
        --observed "x" \
        --expected "y" \
        --evidence "logs/x" \
        --notes "n"

    [ "$status" -ne 0 ]
    [ ! -f "logs/feedback/bogus_kind.jsonl" ]
}

@test "(b) empty kind rejected with non-zero exit" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    run_feedback \
        --kind "" \
        --issue 2872 \
        --observed "x" \
        --expected "y" \
        --evidence "logs/x" \
        --notes "n"

    [ "$status" -ne 0 ]
}

# =============================================================================
# (c) MISSING REQUIRED FIELD REJECTED
# =============================================================================

@test "(c) missing --kind rejected with non-zero exit" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    run_feedback \
        --issue 2880 \
        --observed "x" \
        --expected "y" \
        --evidence "logs/x" \
        --notes "n"

    [ "$status" -ne 0 ]
    [[ "$output" == *"kind"* ]]
}

@test "(c) missing --issue rejected with non-zero exit" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    run_feedback \
        --kind triage_misclassification \
        --observed "x" \
        --expected "y" \
        --evidence "logs/x" \
        --notes "n"

    [ "$status" -ne 0 ]
    [[ "$output" == *"issue"* ]]
}

@test "(c) missing --observed rejected with non-zero exit" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    run_feedback \
        --kind triage_misclassification \
        --issue 2881 \
        --expected "y" \
        --evidence "logs/x" \
        --notes "n"

    [ "$status" -ne 0 ]
    [[ "$output" == *"observed"* ]]
}

@test "(c) missing --expected rejected with non-zero exit" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    run_feedback \
        --kind triage_misclassification \
        --issue 2882 \
        --observed "x" \
        --evidence "logs/x" \
        --notes "n"

    [ "$status" -ne 0 ]
    [[ "$output" == *"expected"* ]]
}

@test "(c) missing required field does not create a JSONL file" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    run_feedback \
        --kind triage_misclassification \
        --observed "x" \
        --expected "y" \
        --evidence "logs/x" \
        --notes "n"

    [ "$status" -ne 0 ]
    [ ! -f "logs/feedback/triage_misclassification.jsonl" ]
}

# =============================================================================
# (d) IDEMPOTENT ON DUPLICATE WITHIN 60s
# =============================================================================

@test "(d) duplicate record within 60s does not append a second line" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    # First call: writes one line.
    run_feedback \
        --kind criterion_drift \
        --issue 2890 \
        --observed "obs-A" \
        --expected "exp-A" \
        --evidence "logs/x" \
        --notes "n"
    [ "$status" -eq 0 ]

    # Second call: identical args, should be a no-op (still exit 0).
    run_feedback \
        --kind criterion_drift \
        --issue 2890 \
        --observed "obs-A" \
        --expected "exp-A" \
        --evidence "logs/x" \
        --notes "n"
    [ "$status" -eq 0 ]

    local jsonl="logs/feedback/criterion_drift.jsonl"
    local line_count
    line_count=$(wc -l < "$jsonl" | tr -d ' ')
    [ "$line_count" = "1" ]
}

@test "(d) duplicate older than 60s appends a new line" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    run_feedback \
        --kind escalation_loop \
        --issue 2891 \
        --observed "obs-B" \
        --expected "exp-B" \
        --evidence "logs/x" \
        --notes "n"
    [ "$status" -eq 0 ]

    local jsonl="logs/feedback/escalation_loop.jsonl"
    [ -f "$jsonl" ]

    # Backdate the existing record by rewriting its timestamp to >60s ago.
    # We compute "two minutes ago" in ISO-8601 UTC. Both BSD (macOS) and GNU
    # date are supported; we try BSD first and fall back to GNU.
    local backdated
    backdated=$(date -u -v-2M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || date -u -d '2 minutes ago' +"%Y-%m-%dT%H:%M:%SZ")
    jq -c --arg ts "$backdated" '.timestamp = $ts' "$jsonl" > "$jsonl.tmp"
    mv "$jsonl.tmp" "$jsonl"

    # Re-record the identical record; now outside the 60s window so it appends.
    run_feedback \
        --kind escalation_loop \
        --issue 2891 \
        --observed "obs-B" \
        --expected "exp-B" \
        --evidence "logs/x" \
        --notes "n"
    [ "$status" -eq 0 ]

    local line_count
    line_count=$(wc -l < "$jsonl" | tr -d ' ')
    [ "$line_count" = "2" ]
}

@test "(d) different record content within 60s appends a new line" {
    [[ -x "$FEEDBACK_SCRIPT" ]] || skip "feedback-record.sh not present yet"

    run_feedback \
        --kind agent_misroute \
        --issue 2892 \
        --observed "obs-C" \
        --expected "exp-C" \
        --evidence "logs/x" \
        --notes "n"
    [ "$status" -eq 0 ]

    # Same kind+issue, different observed value → not a duplicate.
    run_feedback \
        --kind agent_misroute \
        --issue 2892 \
        --observed "obs-D" \
        --expected "exp-C" \
        --evidence "logs/x" \
        --notes "n"
    [ "$status" -eq 0 ]

    local jsonl="logs/feedback/agent_misroute.jsonl"
    local line_count
    line_count=$(wc -l < "$jsonl" | tr -d ' ')
    [ "$line_count" = "2" ]
}
