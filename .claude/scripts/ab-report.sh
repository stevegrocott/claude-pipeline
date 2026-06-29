#!/usr/bin/env bash
#
# ab-report.sh
# Compare two A/B arm run logs; emit markdown report + ab-results.json.
#
# Reads per-issue metrics.json (duration/iterations/escalations/state) from
# each arm's implement-issue log directory and greps stage logs for Claude
# CLI JSON result lines (total_cost_usd/num_turns). Computes per-issue and
# aggregate deltas (treatment − control).
#
# Usage:
#   ab-report.sh --control-log-dir <path> \
#                --treatment-log-dir <path> \
#                --output-dir <path>
#
# The batch-orchestrator log dir is the directory that contains
# issue-N-status.json files (e.g. logs/batch-TIMESTAMP/ inside the arm
# worktree, or the preserved-control/logs/batch-TIMESTAMP/ copy).
#
# Outputs:
#   <output-dir>/report.md
#   <output-dir>/ab-results.json
#
# Exit codes:
#   0  Report generated successfully
#   1  Fatal error (missing dependency, write failure)
#   3  Configuration / argument error
#

set -uo pipefail

readonly SCRIPT_NAME="${0##*/}"

# =============================================================================
# ERROR HELPERS
# =============================================================================

die() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 1
}

die_usage() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 3
}

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME [options]

Compare two A/B arm run logs and generate a comparison report.

Options:
    --control-log-dir <path>    Batch-orchestrator log dir (control arm)
    --treatment-log-dir <path>  Batch-orchestrator log dir (treatment arm)
    --output-dir <path>         Write report.md and ab-results.json here
    -h, --help                  Show this help

Exit codes:
    0  Report generated
    1  Fatal error
    3  Configuration / argument error
EOF
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

CONTROL_LOG_DIR=""
TREATMENT_LOG_DIR=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--control-log-dir)
			[[ -n "${2:-}" ]] \
				|| die_usage "--control-log-dir requires a value"
			CONTROL_LOG_DIR="$2"
			shift 2
			;;
		--treatment-log-dir)
			[[ -n "${2:-}" ]] \
				|| die_usage "--treatment-log-dir requires a value"
			TREATMENT_LOG_DIR="$2"
			shift 2
			;;
		--output-dir)
			[[ -n "${2:-}" ]] \
				|| die_usage "--output-dir requires a value"
			OUTPUT_DIR="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			die_usage "unknown option: $1"
			;;
		*)
			die_usage "unexpected argument: $1"
			;;
	esac
done

[[ -n "$CONTROL_LOG_DIR" ]] \
	|| die_usage "--control-log-dir is required"
[[ -n "$TREATMENT_LOG_DIR" ]] \
	|| die_usage "--treatment-log-dir is required"
[[ -n "$OUTPUT_DIR" ]] \
	|| die_usage "--output-dir is required"

[[ -d "$CONTROL_LOG_DIR" ]] \
	|| die "control log dir not found: $CONTROL_LOG_DIR"
[[ -d "$TREATMENT_LOG_DIR" ]] \
	|| die "treatment log dir not found: $TREATMENT_LOG_DIR"

mkdir -p "$OUTPUT_DIR" \
	|| die "cannot create output dir: $OUTPUT_DIR"

# =============================================================================
# FLOAT FORMATTING (awk — avoids bc dependency)
# =============================================================================

# fmt_float <value> <decimals>
# Format a number for display. Prints "n/a" when value is null or empty.
fmt_float() {
	local value="$1"
	local decimals="${2:-2}"

	if [[ -z "$value" || "$value" == "null" ]]; then
		printf 'n/a'
		return 0
	fi

	awk -v v="$value" -v d="$decimals" 'BEGIN { printf "%." d "f", v }'
}

# fmt_delta <value> <decimals>
# Format a delta with explicit sign (+ or -). Prints "n/a" when null/empty.
fmt_delta() {
	local value="$1"
	local decimals="${2:-0}"

	if [[ -z "$value" || "$value" == "null" ]]; then
		printf 'n/a'
		return 0
	fi

	awk -v v="$value" -v d="$decimals" \
		'BEGIN { printf "%+" "." d "f", v }'
}

# =============================================================================
# DATA COLLECTION
# =============================================================================

# resolve_impl_log_dir <status_file> <arm_log_dir>
#
# Reads log_dir from an implement-issue status file and resolves it to an
# accessible path. Falls back to searching under the sibling implement-issue
# directory (handles preserved copies where the worktree is gone).
#
# Prints the resolved path to stdout; prints nothing on failure.
resolve_impl_log_dir() {
	local status_file="$1"
	local arm_log_dir="$2"

	local log_dir
	log_dir=$(jq -r '.log_dir // empty' "$status_file" 2>/dev/null)
	[[ -n "$log_dir" ]] || return 0

	# Fast path: path exists (live worktree scenario)
	if [[ -d "$log_dir" ]]; then
		printf '%s' "$log_dir"
		return 0
	fi

	# Slow path: worktree was cleaned up; search under sibling dir.
	# arm_log_dir = .../logs/batch-TS/  so dirname = .../logs/
	local issue_num
	issue_num=$(jq -r '.issue // empty' "$status_file" 2>/dev/null)
	[[ -n "$issue_num" ]] || return 0

	local logs_parent impl_search found
	logs_parent="$(dirname "$arm_log_dir")"
	impl_search="$logs_parent/implement-issue"
	[[ -d "$impl_search" ]] || return 0

	found=$(find "$impl_search" -maxdepth 1 -type d \
		-name "issue-${issue_num}-*" 2>/dev/null \
		| sort | tail -1)
	[[ -n "$found" ]] || return 0

	printf '%s' "$found"
}

# collect_stage_costs <impl_log_dir>
#
# Greps stage log files for Claude CLI JSON result lines emitted by
# --output-format json. Extracts total_cost_usd and num_turns and sums
# them across all stages for the issue.
#
# Outputs JSON: {"cost_usd": N, "turns": N}
collect_stage_costs() {
	local impl_log_dir="$1"
	local empty='{"cost_usd":0,"turns":0,"input_tokens":0,"output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0}'

	if [[ -z "$impl_log_dir" \
			|| ! -d "$impl_log_dir/stages" ]]; then
		printf '%s' "$empty"
		return 0
	fi

	local stages_dir="$impl_log_dir/stages"
	local result

	# Collect result lines from stage logs.
	# Requiring "total_cost_usd" in the grep pre-filter avoids passing
	# non-result JSON objects (e.g. intermediate progress lines) to jq,
	# guarding against lines that start with '{' but are not CLI results.
	result=$(
		for f in "$stages_dir"/*.log; do
			[[ -f "$f" ]] || continue
			grep '^{.*"total_cost_usd"' "$f" 2>/dev/null || true
		done \
		| jq -cs '
			[.[] | select(.total_cost_usd != null)] |
			{
				cost_usd: (map(.total_cost_usd) | add // 0),
				turns:    (map(.num_turns // 0)  | add // 0),
				input_tokens: (
					map(
						(.usage.input_tokens
						 // .input_tokens // 0)
					) | add // 0
				),
				output_tokens: (
					map(
						(.usage.output_tokens
						 // .output_tokens // 0)
					) | add // 0
				),
				cache_creation_tokens: (
					map(
						(.usage.cache_creation_input_tokens
						 // .usage.cache_creation_tokens
						 // .cache_creation_input_tokens
						 // .cache_creation_tokens // 0)
					) | add // 0
				),
				cache_read_tokens: (
					map(
						(.usage.cache_read_input_tokens
						 // .usage.cache_read_tokens
						 // .cache_read_input_tokens
						 // .cache_read_tokens // 0)
					) | add // 0
				)
			}
		' 2>/dev/null
	)

	if [[ -n "$result" ]]; then
		printf '%s' "$result"
	else
		printf '%s' "$empty"
	fi
}

# collect_arm_data <arm_log_dir>
#
# Discovers all issue-N-status.json files in the batch log dir, resolves
# each issue's implement-issue log dir, reads metrics.json, and collects
# stage costs.
#
# Prints a JSON array of per-issue objects to stdout.
# All diagnostic output goes to stderr (stdout is the return channel).
collect_arm_data() {
	local arm_log_dir="$1"
	local issues_json="[]"

	local status_file
	for status_file in "$arm_log_dir"/issue-*-status.json; do
		[[ -f "$status_file" ]] || continue

		# Extract issue number from: issue-<N>-status.json
		local base="${status_file##*/}"
		local issue_num="${base#issue-}"
		issue_num="${issue_num%-status.json}"
		[[ -n "$issue_num" ]] || continue

		local impl_log_dir
		impl_log_dir=$(resolve_impl_log_dir \
			"$status_file" "$arm_log_dir")

		local state="unknown"
		local duration="null"
		local quality_iters=0
		local test_iters=0
		local pr_iters=0
		local escalation_count=0

		if [[ -n "$impl_log_dir" \
				&& -f "$impl_log_dir/metrics.json" ]]; then
			local mf="$impl_log_dir/metrics.json"

			state=$(jq -r '.state // "unknown"' "$mf" \
				2>/dev/null || printf 'unknown')
			duration=$(jq -r \
				'.total_duration_seconds // "null"' "$mf" \
				2>/dev/null || printf 'null')
			quality_iters=$(jq -r \
				'.iteration_summary.quality_iterations // 0' \
				"$mf" 2>/dev/null || printf '0')
			test_iters=$(jq -r \
				'.iteration_summary.test_iterations // 0' \
				"$mf" 2>/dev/null || printf '0')
			pr_iters=$(jq -r \
				'.iteration_summary.pr_review_iterations // 0' \
				"$mf" 2>/dev/null || printf '0')
			escalation_count=$(jq -r \
				'.escalations | length' "$mf" \
				2>/dev/null || printf '0')
		else
			state=$(jq -r '.state // "unknown"' \
				"$status_file" 2>/dev/null \
				|| printf 'unknown')
			printf 'WARN: no metrics.json for issue %s\n' \
				"$issue_num" >&2
		fi

		local total_iters
		total_iters=$(( quality_iters + test_iters + pr_iters ))

		# Ensure duration is valid JSON (number or null literal)
		local dur_json="null"
		if [[ "$duration" != "null" && -n "$duration" ]]; then
			dur_json="$duration"
		fi

		local costs_json
		costs_json=$(collect_stage_costs "$impl_log_dir")

		local updated
		updated=$(jq \
			--arg issue "$issue_num" \
			--arg state "$state" \
			--argjson duration "$dur_json" \
			--argjson q "$quality_iters" \
			--argjson t "$test_iters" \
			--argjson p "$pr_iters" \
			--argjson tot "$total_iters" \
			--argjson esc "$escalation_count" \
			--argjson costs "$costs_json" \
			'. + [{
				issue:    $issue,
				state:    $state,
				duration_seconds: $duration,
				iterations: {
					quality:   $q,
					test:      $t,
					pr_review: $p,
					total:     $tot
				},
				escalations:           $esc,
				cost_usd:              $costs.cost_usd,
				turns:                 $costs.turns,
				input_tokens:          $costs.input_tokens,
				output_tokens:         $costs.output_tokens,
				cache_creation_tokens: $costs.cache_creation_tokens,
				cache_read_tokens:     $costs.cache_read_tokens
			}]' <<< "$issues_json" 2>/dev/null)

		if [[ -n "$updated" ]]; then
			issues_json="$updated"
		fi
	done

	printf '%s' "$issues_json"
}

# =============================================================================
# AGGREGATION & DELTA COMPUTATION
# =============================================================================

# aggregate_arm <issues_json>
# Computes totals across all issues for one arm.
# Prints a JSON object to stdout.
aggregate_arm() {
	local issues_json="$1"

	jq '{
		issue_count:   length,
		completed_count: (
			[.[] | select(.state == "completed")] | length
		),
		total_duration_seconds: (
			[.[].duration_seconds | select(. != null)]
			| add // null
		),
		total_iterations:         ([.[].iterations.total]     | add // 0),
		total_quality_iterations: ([.[].iterations.quality]   | add // 0),
		total_test_iterations:    ([.[].iterations.test]      | add // 0),
		total_pr_iterations:      ([.[].iterations.pr_review] | add // 0),
		total_escalations:        ([.[].escalations]          | add // 0),
		total_cost_usd:           ([.[].cost_usd]             | add // 0),
		total_turns:              ([.[].turns]                | add // 0),
		total_input_tokens: (
			[.[].input_tokens]          | add // 0
		),
		total_output_tokens: (
			[.[].output_tokens]         | add // 0
		),
		total_cache_creation_tokens: (
			[.[].cache_creation_tokens] | add // 0
		),
		total_cache_read_tokens: (
			[.[].cache_read_tokens]     | add // 0
		)
	}' <<< "$issues_json"
}

# compute_deltas <ctrl_issues_json> <treat_issues_json>
# Joins both arms by issue number and computes treatment − control deltas.
# Prints a JSON array to stdout.
compute_deltas() {
	local ctrl_json="$1"
	local treat_json="$2"

	jq -n \
		--argjson ctrl "$ctrl_json" \
		--argjson treat "$treat_json" \
		'
		($ctrl  | map({(.issue): .}) | add // {}) as $cm |
		($treat | map({(.issue): .}) | add // {}) as $tm |
		([$ctrl[].issue, $treat[].issue] | unique | sort) |
		map(. as $iss |
			$cm[$iss] as $c |
			$tm[$iss] as $t |
			{
				issue:     $iss,
				control:   $c,
				treatment: $t,
				delta: (
					if ($c != null and $t != null) then {
						duration_seconds: (
							if ($t.duration_seconds != null
								and $c.duration_seconds != null)
							then ($t.duration_seconds
								- $c.duration_seconds)
							else null end
						),
						total_iterations: (
							$t.iterations.total
							- $c.iterations.total
						),
						escalations: (
							$t.escalations - $c.escalations
						),
						cost_usd: ($t.cost_usd - $c.cost_usd),
						turns:    ($t.turns    - $c.turns),
						input_tokens: (
							$t.input_tokens
							- $c.input_tokens
						),
						output_tokens: (
							$t.output_tokens
							- $c.output_tokens
						),
						cache_creation_tokens: (
							$t.cache_creation_tokens
							- $c.cache_creation_tokens
						),
						cache_read_tokens: (
							$t.cache_read_tokens
							- $c.cache_read_tokens
						),
						state_changed: ($t.state != $c.state)
					} else null end
				)
			}
		)
		'
}

# compute_agg_delta <ctrl_agg_json> <treat_agg_json>
# Computes treatment − control aggregate deltas.
# Prints a JSON object to stdout.
compute_agg_delta() {
	local c_agg="$1"
	local t_agg="$2"

	jq -n \
		--argjson c "$c_agg" \
		--argjson t "$t_agg" \
		'{
			issue_count: ($t.issue_count - $c.issue_count),
			completed_count: (
				$t.completed_count - $c.completed_count
			),
			total_duration_seconds: (
				if ($t.total_duration_seconds != null
					and $c.total_duration_seconds != null)
				then ($t.total_duration_seconds
					- $c.total_duration_seconds)
				else null end
			),
			total_iterations: (
				$t.total_iterations - $c.total_iterations
			),
			total_escalations: (
				$t.total_escalations - $c.total_escalations
			),
			total_cost_usd: (
				$t.total_cost_usd - $c.total_cost_usd
			),
			total_turns: ($t.total_turns - $c.total_turns),
			total_input_tokens: (
				$t.total_input_tokens
				- $c.total_input_tokens
			),
			total_output_tokens: (
				$t.total_output_tokens
				- $c.total_output_tokens
			),
			total_cache_creation_tokens: (
				$t.total_cache_creation_tokens
				- $c.total_cache_creation_tokens
			),
			total_cache_read_tokens: (
				$t.total_cache_read_tokens
				- $c.total_cache_read_tokens
			)
		}'
}

# =============================================================================
# REPORT GENERATION
# =============================================================================

# write_report <per_issue_json> <ctrl_agg> <treat_agg> <agg_delta>
#              <ctrl_dir> <treat_dir> <report_file>
write_report() {
	local per_issue_json="$1"
	local ctrl_agg="$2"
	local treat_agg="$3"
	local agg_delta="$4"
	local ctrl_dir="$5"
	local treat_dir="$6"
	local report_file="$7"

	{
		printf '# A/B Test Report\n\n'
		printf 'Generated: %s\n\n' "$(date -Iseconds)"

		printf '| Arm | Log Directory |\n'
		printf '|-----|---------------|\n'
		printf '| control   | `%s` |\n' "$ctrl_dir"
		printf '| treatment | `%s` |\n\n' "$treat_dir"

		# ------------------------------------------------------------------
		# Aggregate summary table
		# ------------------------------------------------------------------
		printf '## Aggregate Summary\n\n'
		printf '| Metric | Control | Treatment | Delta |\n'
		printf '|--------|---------|-----------|-------|\n'

		local ca_dur ta_dur da_dur
		local ca_iters ta_iters da_iters
		local ca_esc ta_esc da_esc
		local ca_cost ta_cost da_cost
		local ca_turns ta_turns da_turns
		local ca_comp ta_comp da_comp
		local ca_inp ta_inp da_inp
		local ca_out ta_out da_out
		local ca_cc ta_cc da_cc
		local ca_cr ta_cr da_cr

		ca_dur=$(jq -r '.total_duration_seconds // "null"' \
			<<< "$ctrl_agg")
		ta_dur=$(jq -r '.total_duration_seconds // "null"' \
			<<< "$treat_agg")
		da_dur=$(jq -r '.total_duration_seconds // "null"' \
			<<< "$agg_delta")

		ca_iters=$(jq -r '.total_iterations' <<< "$ctrl_agg")
		ta_iters=$(jq -r '.total_iterations' <<< "$treat_agg")
		da_iters=$(jq -r '.total_iterations' <<< "$agg_delta")

		ca_esc=$(jq -r '.total_escalations' <<< "$ctrl_agg")
		ta_esc=$(jq -r '.total_escalations' <<< "$treat_agg")
		da_esc=$(jq -r '.total_escalations' <<< "$agg_delta")

		ca_cost=$(jq -r '.total_cost_usd' <<< "$ctrl_agg")
		ta_cost=$(jq -r '.total_cost_usd' <<< "$treat_agg")
		da_cost=$(jq -r '.total_cost_usd' <<< "$agg_delta")

		ca_turns=$(jq -r '.total_turns' <<< "$ctrl_agg")
		ta_turns=$(jq -r '.total_turns' <<< "$treat_agg")
		da_turns=$(jq -r '.total_turns' <<< "$agg_delta")

		ca_comp=$(jq -r '.completed_count' <<< "$ctrl_agg")
		ta_comp=$(jq -r '.completed_count' <<< "$treat_agg")
		da_comp=$(jq -r '.completed_count' <<< "$agg_delta")

		ca_inp=$(jq -r '.total_input_tokens' <<< "$ctrl_agg")
		ta_inp=$(jq -r '.total_input_tokens' <<< "$treat_agg")
		da_inp=$(jq -r '.total_input_tokens' <<< "$agg_delta")

		ca_out=$(jq -r '.total_output_tokens' <<< "$ctrl_agg")
		ta_out=$(jq -r '.total_output_tokens' <<< "$treat_agg")
		da_out=$(jq -r '.total_output_tokens' <<< "$agg_delta")

		ca_cc=$(jq -r \
			'.total_cache_creation_tokens' <<< "$ctrl_agg")
		ta_cc=$(jq -r \
			'.total_cache_creation_tokens' <<< "$treat_agg")
		da_cc=$(jq -r \
			'.total_cache_creation_tokens' <<< "$agg_delta")

		ca_cr=$(jq -r \
			'.total_cache_read_tokens' <<< "$ctrl_agg")
		ta_cr=$(jq -r \
			'.total_cache_read_tokens' <<< "$treat_agg")
		da_cr=$(jq -r \
			'.total_cache_read_tokens' <<< "$agg_delta")

		printf '| Duration (s)   | %s | %s | %s |\n' \
			"$(fmt_float "$ca_dur" 1)" \
			"$(fmt_float "$ta_dur" 1)" \
			"$(fmt_delta "$da_dur" 1)"
		printf '| Iterations     | %s | %s | %s |\n' \
			"$ca_iters" "$ta_iters" \
			"$(fmt_delta "$da_iters" 0)"
		printf '| Escalations    | %s | %s | %s |\n' \
			"$ca_esc" "$ta_esc" \
			"$(fmt_delta "$da_esc" 0)"
		printf '| Cost (USD)     | %s | %s | %s |\n' \
			"$(fmt_float "$ca_cost" 4)" \
			"$(fmt_float "$ta_cost" 4)" \
			"$(fmt_delta "$da_cost" 4)"
		printf '| Turns          | %s | %s | %s |\n' \
			"$ca_turns" "$ta_turns" \
			"$(fmt_delta "$da_turns" 0)"
		printf '| Completed      | %s | %s | %s |\n' \
			"$ca_comp" "$ta_comp" \
			"$(fmt_delta "$da_comp" 0)"
		printf '| Input tokens   | %s | %s | %s |\n' \
			"$ca_inp" "$ta_inp" \
			"$(fmt_delta "$da_inp" 0)"
		printf '| Output tokens  | %s | %s | %s |\n' \
			"$ca_out" "$ta_out" \
			"$(fmt_delta "$da_out" 0)"
		printf '| Cache-create   | %s | %s | %s |\n' \
			"$ca_cc" "$ta_cc" \
			"$(fmt_delta "$da_cc" 0)"
		printf '| Cache-read     | %s | %s | %s |\n\n' \
			"$ca_cr" "$ta_cr" \
			"$(fmt_delta "$da_cr" 0)"

		# ------------------------------------------------------------------
		# Per-issue table
		# ------------------------------------------------------------------
		printf '## Per-Issue Comparison\n\n'
		printf '| Issue | Arm | State | Duration (s)'
		printf ' | Iters | Escl | Cost (USD) | Turns'
		printf ' | Inp Tok | Out Tok | CCreate | CRead |\n'
		printf '|-------|-----|-------|-------------'
		printf '|-------|------|-----------|-------'
		printf '|---------|---------|---------|-------|\n'

		local entry iss_num c_entry t_entry d_entry
		local c_state c_dur c_iters c_esc c_cost c_turns
		local c_inp c_out c_cc c_cr
		local t_state t_dur t_iters t_esc t_cost t_turns
		local t_inp t_out t_cc t_cr
		local d_dur d_iters d_esc d_cost d_turns
		local d_inp d_out d_cc d_cr

		while IFS= read -r entry; do
			[[ -n "$entry" ]] || continue

			iss_num=$(jq -r '.issue' <<< "$entry")
			c_entry=$(jq -c '.control // {}' <<< "$entry")
			t_entry=$(jq -c '.treatment // {}' <<< "$entry")
			d_entry=$(jq -c '.delta // "null"' <<< "$entry")

			c_state=$(jq -r '.state // "—"' <<< "$c_entry")
			c_dur=$(jq -r '.duration_seconds // "null"' \
				<<< "$c_entry")
			c_iters=$(jq -r '.iterations.total // "—"' \
				<<< "$c_entry")
			c_esc=$(jq -r '.escalations // "—"' <<< "$c_entry")
			c_cost=$(jq -r '.cost_usd // "null"' <<< "$c_entry")
			c_turns=$(jq -r '.turns // "—"' <<< "$c_entry")
			c_inp=$(jq -r '.input_tokens // "—"' \
				<<< "$c_entry")
			c_out=$(jq -r '.output_tokens // "—"' \
				<<< "$c_entry")
			c_cc=$(jq -r \
				'.cache_creation_tokens // "—"' \
				<<< "$c_entry")
			c_cr=$(jq -r '.cache_read_tokens // "—"' \
				<<< "$c_entry")

			printf \
				'| #%s | control | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
				"$iss_num" "$c_state" \
				"$(fmt_float "$c_dur" 1)" \
				"$c_iters" "$c_esc" \
				"$(fmt_float "$c_cost" 4)" \
				"$c_turns" \
				"$c_inp" "$c_out" "$c_cc" "$c_cr"

			t_state=$(jq -r '.state // "—"' <<< "$t_entry")
			t_dur=$(jq -r '.duration_seconds // "null"' \
				<<< "$t_entry")
			t_iters=$(jq -r '.iterations.total // "—"' \
				<<< "$t_entry")
			t_esc=$(jq -r '.escalations // "—"' <<< "$t_entry")
			t_cost=$(jq -r '.cost_usd // "null"' <<< "$t_entry")
			t_turns=$(jq -r '.turns // "—"' <<< "$t_entry")
			t_inp=$(jq -r '.input_tokens // "—"' \
				<<< "$t_entry")
			t_out=$(jq -r '.output_tokens // "—"' \
				<<< "$t_entry")
			t_cc=$(jq -r \
				'.cache_creation_tokens // "—"' \
				<<< "$t_entry")
			t_cr=$(jq -r '.cache_read_tokens // "—"' \
				<<< "$t_entry")

			printf \
				'| #%s | treatment | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
				"$iss_num" "$t_state" \
				"$(fmt_float "$t_dur" 1)" \
				"$t_iters" "$t_esc" \
				"$(fmt_float "$t_cost" 4)" \
				"$t_turns" \
				"$t_inp" "$t_out" "$t_cc" "$t_cr"

			if [[ "$d_entry" != '"null"' \
					&& "$d_entry" != "null" ]]; then
				d_dur=$(jq -r \
					'.duration_seconds // "null"' \
					<<< "$d_entry")
				d_iters=$(jq -r \
					'.total_iterations // "null"' \
					<<< "$d_entry")
				d_esc=$(jq -r \
					'.escalations // "null"' \
					<<< "$d_entry")
				d_cost=$(jq -r \
					'.cost_usd // "null"' <<< "$d_entry")
				d_turns=$(jq -r \
					'.turns // "null"' <<< "$d_entry")
				d_inp=$(jq -r \
					'.input_tokens // "null"' \
					<<< "$d_entry")
				d_out=$(jq -r \
					'.output_tokens // "null"' \
					<<< "$d_entry")
				d_cc=$(jq -r \
					'.cache_creation_tokens // "null"' \
					<<< "$d_entry")
				d_cr=$(jq -r \
					'.cache_read_tokens // "null"' \
					<<< "$d_entry")

				printf \
					'| | **delta** | | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
					"$(fmt_delta "$d_dur" 1)" \
					"$(fmt_delta "$d_iters" 0)" \
					"$(fmt_delta "$d_esc" 0)" \
					"$(fmt_delta "$d_cost" 4)" \
					"$(fmt_delta "$d_turns" 0)" \
					"$(fmt_delta "$d_inp" 0)" \
					"$(fmt_delta "$d_out" 0)" \
					"$(fmt_delta "$d_cc" 0)" \
					"$(fmt_delta "$d_cr" 0)"
			fi

		done < <(jq -c '.[]' <<< "$per_issue_json")

	} > "$report_file" \
		|| die "failed to write report: $report_file"
}

# write_results_json <per_issue_json> <ctrl_agg> <treat_agg> <agg_delta>
#                    <ctrl_issues> <treat_issues>
#                    <ctrl_dir> <treat_dir> <results_file>
write_results_json() {
	local per_issue_json="$1"
	local ctrl_agg="$2"
	local treat_agg="$3"
	local agg_delta="$4"
	local ctrl_issues="$5"
	local treat_issues="$6"
	local ctrl_dir="$7"
	local treat_dir="$8"
	local results_file="$9"

	jq -n \
		--arg schema_version "1" \
		--arg generated_at "$(date -Iseconds)" \
		--arg ctrl_dir "$ctrl_dir" \
		--arg treat_dir "$treat_dir" \
		--argjson ctrl_issues "$ctrl_issues" \
		--argjson treat_issues "$treat_issues" \
		--argjson ctrl_agg "$ctrl_agg" \
		--argjson treat_agg "$treat_agg" \
		--argjson agg_delta "$agg_delta" \
		--argjson per_issue "$per_issue_json" \
		'{
			schema_version: $schema_version,
			generated_at:   $generated_at,
			arms: {
				control: {
					log_dir:   $ctrl_dir,
					aggregate: $ctrl_agg,
					issues:    $ctrl_issues
				},
				treatment: {
					log_dir:   $treat_dir,
					aggregate: $treat_agg,
					issues:    $treat_issues
				}
			},
			per_issue: $per_issue,
			aggregate: {
				control:   $ctrl_agg,
				treatment: $treat_agg,
				delta:     $agg_delta
			}
		}' > "$results_file" \
		|| die "failed to write results JSON: $results_file"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
	command -v jq >/dev/null 2>&1 \
		|| die "jq is required but not found in PATH"
	command -v awk >/dev/null 2>&1 \
		|| die "awk is required but not found in PATH"

	printf 'Collecting control arm data from: %s\n' \
		"$CONTROL_LOG_DIR" >&2
	local ctrl_issues
	ctrl_issues=$(collect_arm_data "$CONTROL_LOG_DIR")

	printf 'Collecting treatment arm data from: %s\n' \
		"$TREATMENT_LOG_DIR" >&2
	local treat_issues
	treat_issues=$(collect_arm_data "$TREATMENT_LOG_DIR")

	printf 'Computing aggregates and deltas...\n' >&2

	local ctrl_agg treat_agg
	ctrl_agg=$(aggregate_arm "$ctrl_issues")
	treat_agg=$(aggregate_arm "$treat_issues")

	local agg_delta
	agg_delta=$(compute_agg_delta "$ctrl_agg" "$treat_agg")

	local per_issue
	per_issue=$(compute_deltas "$ctrl_issues" "$treat_issues")

	local report_file="$OUTPUT_DIR/report.md"
	local results_file="$OUTPUT_DIR/ab-results.json"

	printf 'Writing report to: %s\n' "$report_file" >&2
	write_report \
		"$per_issue" "$ctrl_agg" "$treat_agg" "$agg_delta" \
		"$CONTROL_LOG_DIR" "$TREATMENT_LOG_DIR" \
		"$report_file"

	printf 'Writing results to: %s\n' "$results_file" >&2
	write_results_json \
		"$per_issue" "$ctrl_agg" "$treat_agg" "$agg_delta" \
		"$ctrl_issues" "$treat_issues" \
		"$CONTROL_LOG_DIR" "$TREATMENT_LOG_DIR" \
		"$results_file"

	printf 'Done.\n' >&2
	printf '  Report:  %s\n' "$report_file" >&2
	printf '  Results: %s\n' "$results_file" >&2
}

main "$@"
