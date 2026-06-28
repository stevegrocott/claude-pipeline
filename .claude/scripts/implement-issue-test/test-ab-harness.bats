#!/usr/bin/env bats
#
# test-ab-harness.bats
#
# Tests for the A/B experiment harness pair:
#   - .claude/scripts/ab-harness.sh  (worktree fan-out + orchestration)
#   - .claude/scripts/ab-report.sh   (metrics extraction + delta report)
#
# Coverage (issue #538, AC5 / Implementation Task 3):
#   - argument parsing for both scripts (valid + error paths)
#   - worktree mock setup / teardown (branch + worktree create/remove)
#   - metrics & token extraction (collect_stage_costs token breakdown)
#   - delta computation (compute_deltas / compute_agg_delta / aggregate_arm)
#   - report structure (report.md sections + ab-results.json schema)
#
# Unit tests source individual functions via _extract_function_body so the
# pure jq helpers run in isolation; integration tests drive the scripts
# end-to-end against fixture log directories.
#

load 'helpers/test-helper.bash'

AB_HARNESS=""
AB_REPORT=""

setup() {
	setup_test_env
	AB_HARNESS="$SCRIPT_DIR/ab-harness.sh"
	AB_REPORT="$SCRIPT_DIR/ab-report.sh"
}

teardown() {
	teardown_test_env
}

# extract_func_col0 <func_name> <file>
#
# Print a function body by capturing from its `name() {` header to the
# first line that is exactly `}` at column 0 (the project's brace style).
# Unlike the brace-counting _extract_function_body, this tolerates literal
# braces inside strings — e.g. collect_stage_costs' grep '^{...' pattern,
# which otherwise unbalances a naive brace counter.
extract_func_col0() {
	local fn="$1"
	local file="$2"
	awk -v fn="$fn" '
		$0 ~ "^"fn"\\(\\) \\{$" { capture = 1 }
		capture { print }
		capture && /^\}$/ { capture = 0 }
	' "$file"
}

# =============================================================================
# FIXTURE BUILDERS
# =============================================================================

# make_arm_log_dir <arm_root> <issue> <state> <dur> <q> <t> <p> \
#                  <cost> <turns> <input> <output> <cc> <cr>
#
# Builds a complete batch-orchestrator-style log dir for one issue:
#   <arm_root>/issue-<N>-status.json          (points at impl log dir)
#   <arm_root>/implement-issue/issue-<N>-TS/metrics.json
#   <arm_root>/implement-issue/issue-<N>-TS/stages/implement.log
#
# Echoes the arm_root path.
make_arm_log_dir() {
	local arm_root="$1"
	local issue="$2"
	local state="$3"
	local dur="$4"
	local q="$5" t="$6" p="$7"
	local cost="$8" turns="$9"
	local input="${10}" output="${11}" cc="${12}" cr="${13}"

	local impl="$arm_root/implement-issue/issue-${issue}-20260101000000"
	mkdir -p "$impl/stages"

	cat >"$arm_root/issue-${issue}-status.json" <<EOF
{"issue":"${issue}","state":"${state}","log_dir":"${impl}"}
EOF

	cat >"$impl/metrics.json" <<EOF
{
  "state": "${state}",
  "total_duration_seconds": ${dur},
  "iteration_summary": {
    "quality_iterations": ${q},
    "test_iterations": ${t},
    "pr_review_iterations": ${p}
  },
  "escalations": []
}
EOF

	# A real Claude CLI --output-format json result line, plus a
	# non-result JSON line that must be ignored by the grep pre-filter.
	cat >"$impl/stages/implement.log" <<EOF
{"type":"progress","message":"working"}
{"total_cost_usd":${cost},"num_turns":${turns},"usage":{"input_tokens":${input},"output_tokens":${output},"cache_creation_input_tokens":${cc},"cache_read_input_tokens":${cr}}}
EOF

	printf '%s\n' "$arm_root"
}

# init_git_repo <path> — minimal repo with one commit on branch "base"
init_git_repo() {
	local path="$1"
	mkdir -p "$path"
	git -C "$path" init -q
	git -C "$path" config user.email "t@t.test"
	git -C "$path" config user.name "tester"
	git -C "$path" checkout -q -b base
	printf 'seed\n' >"$path/seed.txt"
	git -C "$path" add seed.txt
	git -C "$path" commit -qm "seed"
}

# =============================================================================
# ab-harness.sh — ARGUMENT PARSING
# =============================================================================

@test "ab-harness: --help exits 0 and prints usage" {
	run bash "$AB_HARNESS" --help
	assert_exit_code "$status" 0
	assert_contains "$output" "Usage:"
	assert_contains "$output" "--issues"
	assert_contains "$output" "--base-branch"
}

@test "ab-harness: no arguments exits 3 with guidance" {
	run bash "$AB_HARNESS"
	assert_exit_code "$status" 3
	assert_contains "$output" "must provide --issues or --manifest"
}

@test "ab-harness: --issues without a value exits 3" {
	run bash "$AB_HARNESS" --issues
	assert_exit_code "$status" 3
	assert_contains "$output" "--issues requires a value"
}

@test "ab-harness: --base-branch without a value exits 3" {
	run bash "$AB_HARNESS" --issues "1" --base-branch
	assert_exit_code "$status" 3
	assert_contains "$output" "--base-branch requires a value"
}

@test "ab-harness: unknown option exits 3" {
	run bash "$AB_HARNESS" --bogus
	assert_exit_code "$status" 3
	assert_contains "$output" "unknown option: --bogus"
}

@test "ab-harness: unexpected positional argument exits 3" {
	run bash "$AB_HARNESS" stray
	assert_exit_code "$status" 3
	assert_contains "$output" "unexpected argument: stray"
}

@test "ab-harness: --issues without --base-branch exits 3" {
	run bash "$AB_HARNESS" --issues "1,2"
	assert_exit_code "$status" 3
	assert_contains "$output" "must provide --base-branch"
}

@test "ab-harness: --manifest pointing at a missing file exits 3" {
	run bash "$AB_HARNESS" --manifest "$TEST_TMP/nope.json"
	assert_exit_code "$status" 3
	assert_contains "$output" "manifest not found"
}

@test "ab-harness: manifest supplies issues+base then validates base branch" {
	# A copy inside a fake repo so REPO_ROOT/logs land under TEST_TMP.
	local repo="$TEST_TMP/repo"
	init_git_repo "$repo"
	mkdir -p "$repo/.claude/scripts"
	cp "$AB_HARNESS" "$repo/.claude/scripts/ab-harness.sh"

	cat >"$TEST_TMP/manifest.json" <<EOF
{"issues":["1","2"],"base_branch":"does-not-exist"}
EOF

	run bash "$repo/.claude/scripts/ab-harness.sh" \
		--manifest "$TEST_TMP/manifest.json"
	# Parsing the manifest must succeed (no exit-3 config error); the
	# run then fails the base-branch existence check with exit 1.
	assert_exit_code "$status" 1
	assert_contains "$output" "base branch does not exist"
}

# =============================================================================
# ab-harness.sh — WORKTREE SETUP / TEARDOWN
# =============================================================================

@test "ab-harness: setup_arm_branch creates the arm branch from base" {
	local repo="$TEST_TMP/repo"
	init_git_repo "$repo"

	REPO_ROOT="$repo"
	BASE_BRANCH="base"
	LOG_FILE="$TEST_TMP/harness.log"
	: >"$LOG_FILE"
	log() { :; }
	log_error() { :; }
	eval "$(_extract_function_body setup_arm_branch "$AB_HARNESS")"

	run setup_arm_branch "control" "ab-control"
	assert_exit_code "$status" 0
	run git -C "$repo" rev-parse --verify ab-control
	assert_exit_code "$status" 0
}

@test "ab-harness: setup_arm_worktree adds a worktree on the arm branch" {
	local repo="$TEST_TMP/repo"
	init_git_repo "$repo"
	git -C "$repo" branch ab-control base

	REPO_ROOT="$repo"
	LOG_FILE="$TEST_TMP/harness.log"
	: >"$LOG_FILE"
	log() { :; }
	log_error() { :; }
	eval "$(_extract_function_body setup_arm_worktree "$AB_HARNESS")"

	local wt="$TEST_TMP/wt/control"
	run setup_arm_worktree "control" "ab-control" "$wt"
	assert_exit_code "$status" 0
	assert_dir_exists "$wt"
	# Worktree is checked out on the arm branch.
	run git -C "$wt" rev-parse --abbrev-ref HEAD
	assert_equals "$output" "ab-control"
}

@test "ab-harness: a created worktree can be torn down (cleanup contract)" {
	local repo="$TEST_TMP/repo"
	init_git_repo "$repo"
	git -C "$repo" branch ab-control base

	REPO_ROOT="$repo"
	LOG_FILE="$TEST_TMP/harness.log"
	: >"$LOG_FILE"
	log() { :; }
	log_error() { :; }
	eval "$(_extract_function_body setup_arm_worktree "$AB_HARNESS")"

	local wt="$TEST_TMP/wt/control"
	setup_arm_worktree "control" "ab-control" "$wt"
	assert_dir_exists "$wt"

	# Mirror cleanup()'s teardown step.
	git -C "$repo" worktree remove --force "$wt"
	[[ ! -d "$wt" ]] || fail "worktree should be removed after teardown"
}

# =============================================================================
# ab-harness.sh — resolve_log_dir
# =============================================================================

@test "ab-harness: resolve_log_dir reads absolute log_dir at worktree root" {
	log_warn() { :; }
	eval "$(_extract_function_body resolve_log_dir "$AB_HARNESS")"

	local wt="$TEST_TMP/wt"
	mkdir -p "$wt"
	printf '{"log_dir":"/abs/batch-1"}\n' >"$wt/status.json"

	run resolve_log_dir "$wt" "control"
	assert_exit_code "$status" 0
	assert_equals "$output" "/abs/batch-1"
}

@test "ab-harness: resolve_log_dir joins a relative log_dir to the worktree" {
	log_warn() { :; }
	eval "$(_extract_function_body resolve_log_dir "$AB_HARNESS")"

	local wt="$TEST_TMP/wt"
	mkdir -p "$wt"
	printf '{"log_dir":"logs/batch-9"}\n' >"$wt/status.json"

	run resolve_log_dir "$wt" "control"
	assert_exit_code "$status" 0
	assert_equals "$output" "$wt/logs/batch-9"
}

@test "ab-harness: resolve_log_dir falls back to status.json in a subdir" {
	log_warn() { :; }
	eval "$(_extract_function_body resolve_log_dir "$AB_HARNESS")"

	local wt="$TEST_TMP/wt"
	mkdir -p "$wt/run"
	printf '{"log_dir":"/abs/batch-2"}\n' >"$wt/run/status.json"

	run resolve_log_dir "$wt" "treatment"
	assert_exit_code "$status" 0
	assert_equals "$output" "/abs/batch-2"
}

@test "ab-harness: resolve_log_dir prints nothing when status.json absent" {
	log_warn() { :; }
	eval "$(_extract_function_body resolve_log_dir "$AB_HARNESS")"

	local wt="$TEST_TMP/empty"
	mkdir -p "$wt"

	run resolve_log_dir "$wt" "control"
	assert_exit_code "$status" 0
	assert_equals "$output" ""
}

# =============================================================================
# ab-report.sh — ARGUMENT PARSING
# =============================================================================

@test "ab-report: --help exits 0 and prints usage" {
	run bash "$AB_REPORT" --help
	assert_exit_code "$status" 0
	assert_contains "$output" "--control-log-dir"
	assert_contains "$output" "--treatment-log-dir"
}

@test "ab-report: missing --control-log-dir exits 3" {
	run bash "$AB_REPORT" \
		--treatment-log-dir "$TEST_TMP/t" \
		--output-dir "$TEST_TMP/out"
	assert_exit_code "$status" 3
	assert_contains "$output" "--control-log-dir is required"
}

@test "ab-report: nonexistent control log dir exits 1" {
	mkdir -p "$TEST_TMP/t"
	run bash "$AB_REPORT" \
		--control-log-dir "$TEST_TMP/missing" \
		--treatment-log-dir "$TEST_TMP/t" \
		--output-dir "$TEST_TMP/out"
	assert_exit_code "$status" 1
	assert_contains "$output" "control log dir not found"
}

@test "ab-report: unknown option exits 3" {
	run bash "$AB_REPORT" --frobnicate
	assert_exit_code "$status" 3
	assert_contains "$output" "unknown option: --frobnicate"
}

# =============================================================================
# ab-report.sh — METRICS & TOKEN EXTRACTION (collect_stage_costs)
# =============================================================================

@test "ab-report: collect_stage_costs extracts the full token breakdown" {
	eval "$(extract_func_col0 collect_stage_costs "$AB_REPORT")"

	local impl="$TEST_TMP/impl"
	mkdir -p "$impl/stages"
	cat >"$impl/stages/s.log" <<'EOF'
{"type":"progress"}
{"total_cost_usd":0.5,"num_turns":4,"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":200,"cache_read_input_tokens":300}}
EOF

	run collect_stage_costs "$impl"
	assert_exit_code "$status" 0
	assert_equals "$(jq -r '.cost_usd' <<<"$output")" "0.5"
	assert_equals "$(jq -r '.turns' <<<"$output")" "4"
	assert_equals "$(jq -r '.input_tokens' <<<"$output")" "100"
	assert_equals "$(jq -r '.output_tokens' <<<"$output")" "50"
	assert_equals \
		"$(jq -r '.cache_creation_tokens' <<<"$output")" "200"
	assert_equals "$(jq -r '.cache_read_tokens' <<<"$output")" "300"
}

@test "ab-report: collect_stage_costs ignores non-result JSON lines" {
	eval "$(extract_func_col0 collect_stage_costs "$AB_REPORT")"

	local impl="$TEST_TMP/impl"
	mkdir -p "$impl/stages"
	# Only the second line is a CLI result; the others must not be summed.
	cat >"$impl/stages/s.log" <<'EOF'
{"event":"start"}
{"total_cost_usd":1.0,"num_turns":2,"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
{"note":"this has no total_cost_usd field"}
EOF

	run collect_stage_costs "$impl"
	assert_exit_code "$status" 0
	# Cost reflects exactly one result line, not the noise around it.
	assert_equals "$(jq -r '.cost_usd' <<<"$output")" "1.0"
	assert_equals "$(jq -r '.turns' <<<"$output")" "2"
}

@test "ab-report: collect_stage_costs returns zeros when no stages dir" {
	eval "$(extract_func_col0 collect_stage_costs "$AB_REPORT")"

	run collect_stage_costs "$TEST_TMP/does-not-exist"
	assert_exit_code "$status" 0
	assert_equals "$(jq -r '.cost_usd' <<<"$output")" "0"
	assert_equals "$(jq -r '.input_tokens' <<<"$output")" "0"
	assert_equals "$(jq -r '.cache_read_tokens' <<<"$output")" "0"
}

# =============================================================================
# ab-report.sh — AGGREGATION & DELTA COMPUTATION
# =============================================================================

@test "ab-report: aggregate_arm sums tokens across issues" {
	eval "$(_extract_function_body aggregate_arm "$AB_REPORT")"

	local issues='[
		{"state":"completed","duration_seconds":10,
		 "iterations":{"total":2},"escalations":0,
		 "cost_usd":0.5,"turns":3,
		 "input_tokens":100,"output_tokens":50,
		 "cache_creation_tokens":200,"cache_read_tokens":300},
		{"state":"failed","duration_seconds":20,
		 "iterations":{"total":1},"escalations":1,
		 "cost_usd":0.5,"turns":2,
		 "input_tokens":40,"output_tokens":10,
		 "cache_creation_tokens":60,"cache_read_tokens":90}
	]'

	run aggregate_arm "$issues"
	assert_exit_code "$status" 0
	assert_equals "$(jq -r '.issue_count' <<<"$output")" "2"
	assert_equals "$(jq -r '.completed_count' <<<"$output")" "1"
	assert_equals \
		"$(jq -r '.total_input_tokens' <<<"$output")" "140"
	assert_equals \
		"$(jq -r '.total_cache_read_tokens' <<<"$output")" "390"
}

@test "ab-report: compute_deltas reports treatment minus control per issue" {
	eval "$(_extract_function_body compute_deltas "$AB_REPORT")"

	local ctrl='[
		{"issue":"1","state":"completed","duration_seconds":10,
		 "iterations":{"total":2},"escalations":0,
		 "cost_usd":1.0,"turns":5,
		 "input_tokens":100,"output_tokens":50,
		 "cache_creation_tokens":200,"cache_read_tokens":300}
	]'
	local treat='[
		{"issue":"1","state":"completed","duration_seconds":7,
		 "iterations":{"total":1},"escalations":0,
		 "cost_usd":0.6,"turns":3,
		 "input_tokens":80,"output_tokens":40,
		 "cache_creation_tokens":150,"cache_read_tokens":500}
	]'

	run compute_deltas "$ctrl" "$treat"
	assert_exit_code "$status" 0
	assert_equals \
		"$(jq -r '.[0].delta.turns' <<<"$output")" "-2"
	assert_equals \
		"$(jq -r '.[0].delta.input_tokens' <<<"$output")" "-20"
	# Cache reads went UP under treatment — positive delta.
	assert_equals \
		"$(jq -r '.[0].delta.cache_read_tokens' <<<"$output")" "200"
}

@test "ab-report: compute_deltas yields null delta for unmatched issue" {
	eval "$(_extract_function_body compute_deltas "$AB_REPORT")"

	local ctrl='[{"issue":"1","state":"completed","duration_seconds":1,
		"iterations":{"total":1},"escalations":0,"cost_usd":0,"turns":1,
		"input_tokens":0,"output_tokens":0,
		"cache_creation_tokens":0,"cache_read_tokens":0}]'
	local treat='[]'

	run compute_deltas "$ctrl" "$treat"
	assert_exit_code "$status" 0
	assert_equals "$(jq -r '.[0].delta' <<<"$output")" "null"
}

@test "ab-report: compute_agg_delta subtracts aggregate token totals" {
	eval "$(_extract_function_body compute_agg_delta "$AB_REPORT")"

	local c='{"issue_count":2,"completed_count":2,
		"total_duration_seconds":30,"total_iterations":3,
		"total_escalations":1,"total_cost_usd":2.0,"total_turns":8,
		"total_input_tokens":140,"total_output_tokens":60,
		"total_cache_creation_tokens":260,"total_cache_read_tokens":390}'
	local t='{"issue_count":2,"completed_count":1,
		"total_duration_seconds":20,"total_iterations":2,
		"total_escalations":2,"total_cost_usd":1.5,"total_turns":6,
		"total_input_tokens":100,"total_output_tokens":40,
		"total_cache_creation_tokens":200,"total_cache_read_tokens":600}'

	run compute_agg_delta "$c" "$t"
	assert_exit_code "$status" 0
	assert_equals \
		"$(jq -r '.total_input_tokens' <<<"$output")" "-40"
	assert_equals \
		"$(jq -r '.total_cache_read_tokens' <<<"$output")" "210"
	assert_equals \
		"$(jq -r '.completed_count' <<<"$output")" "-1"
}

# =============================================================================
# ab-report.sh — END-TO-END REPORT STRUCTURE
# =============================================================================

@test "ab-report: end-to-end run writes report.md and ab-results.json" {
	local ctrl="$TEST_TMP/ctrl/batch-20260101"
	local treat="$TEST_TMP/treat/batch-20260101"
	mkdir -p "$ctrl" "$treat"
	#                 root  iss st        dur q t p cost turns in  out  cc  cr
	make_arm_log_dir "$ctrl"  1 completed 10  1 1 0 1.0  5     100 50  200 300 >/dev/null
	make_arm_log_dir "$treat" 1 completed  7  1 0 0 0.6  3     80  40  150 500 >/dev/null

	local out="$TEST_TMP/out"
	run bash "$AB_REPORT" \
		--control-log-dir "$ctrl" \
		--treatment-log-dir "$treat" \
		--output-dir "$out"
	assert_exit_code "$status" 0

	assert_file_exists "$out/report.md"
	assert_file_exists "$out/ab-results.json"

	# Report structure: title + the token-breakdown rows AC2 requires.
	assert_file_contains "$out/report.md" "# A/B Test Report"
	assert_file_contains "$out/report.md" "Aggregate Summary"
	assert_file_contains "$out/report.md" "Per-Issue Comparison"
	assert_file_contains "$out/report.md" "Input tokens"
	assert_file_contains "$out/report.md" "Cache-create"
	assert_file_contains "$out/report.md" "Cache-read"
}

@test "ab-report: ab-results.json carries the per-issue token breakdown" {
	local ctrl="$TEST_TMP/ctrl/batch-20260101"
	local treat="$TEST_TMP/treat/batch-20260101"
	mkdir -p "$ctrl" "$treat"
	make_arm_log_dir "$ctrl"  1 completed 10 1 1 0 1.0 5 100 50 200 300 >/dev/null
	make_arm_log_dir "$treat" 1 completed  7 1 0 0 0.6 3 80  40 150 500 >/dev/null

	local out="$TEST_TMP/out"
	bash "$AB_REPORT" \
		--control-log-dir "$ctrl" \
		--treatment-log-dir "$treat" \
		--output-dir "$out"

	local json="$out/ab-results.json"
	assert_json_field "$json" '.schema_version' "1"

	# Per-issue control arm preserves the token breakdown.
	assert_equals \
		"$(jq -r '.per_issue[0].control.input_tokens' "$json")" "100"
	assert_equals \
		"$(jq -r '.per_issue[0].control.cache_read_tokens' "$json")" \
		"300"

	# Aggregate delta is treatment − control for the cache-read signal.
	assert_equals \
		"$(jq -r '.aggregate.delta.total_cache_read_tokens' "$json")" \
		"200"
	# Treatment used fewer turns: delta is negative.
	assert_equals \
		"$(jq -r '.aggregate.delta.total_turns' "$json")" "-2"
}
