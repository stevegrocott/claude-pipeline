#!/usr/bin/env bash
#
# cost-trend-guard.sh — advisory cost/token trend guard for the pipeline.
#
# Computes a rolling MT/issue (megatokens per completed issue) baseline over
# the most recent N batch summaries and warns when the current batch exceeds
# that baseline by a configurable factor. The guard is ADVISORY: it never
# blocks or fails a batch. It emits a JSON verdict on stdout that the batch
# orchestrator attaches to summary.json (as cost_rollup / trend_warning) and
# forwards to the event stream as a `cost_trend_warning` event.
#
# Metric source (in order):
#   1. #580's `cost_summary` token fields in a batch summary/status JSON.
#   2. Fallback: the total_cost_usd/token parse pattern from ab-report.sh's
#      collect_stage_costs(), applied over the run's log_dir stage logs — used
#      when cost_summary carries only total_cost_usd (no token totals).
#
# NO-OP contract: when `cost_summary` is absent (older summaries pre-#580) or
# no token metric can be derived, the verdict is {"status":"noop",...} and no
# warning is produced.
#
# Environment:
#   COST_TREND_WINDOW  Rolling window size (# of recent batches).  Default 5.
#   COST_TREND_FACTOR  Warn when latest > baseline * factor.        Default 1.5.
#
# Usage:
#   cost-trend-guard.sh --current <summary-or-status.json> \
#                       [--history-dir <dir containing batch-*/summary.json>] \
#                       [--window N] [--factor F]
#
# Output (stdout): a single-line JSON verdict. Exit code is always 0 for a
# well-formed invocation so callers can treat the guard as non-blocking.
#
# This file is safe to `source` for unit testing: the CLI entry point only
# runs when the script is executed directly, not when sourced.
#

set -uo pipefail

COST_TREND_WINDOW="${COST_TREND_WINDOW:-5}"
COST_TREND_FACTOR="${COST_TREND_FACTOR:-1.5}"

# -----------------------------------------------------------------------------
# ctg_tokens_from_logs <log_dir>
#
# Fallback token extractor. Reuses ab-report.sh's canonical parse: grep the
# Claude CLI `--output-format json` result lines (identified by the presence of
# "total_cost_usd") from every *.log under the run directory, then sum the
# input/output/cache token fields. Prints a single integer (0 when nothing is
# found).
# -----------------------------------------------------------------------------
ctg_tokens_from_logs() {
	local log_dir="$1"
	[[ -n "$log_dir" && -d "$log_dir" ]] || { printf '0'; return 0; }

	local lines
	lines=$(find "$log_dir" -type f -name '*.log' \
		-exec grep -h '^{.*"total_cost_usd"' {} + 2>/dev/null) || lines=""
	[[ -n "$lines" ]] || { printf '0'; return 0; }

	printf '%s\n' "$lines" | jq -cs '
		[.[] | select(.total_cost_usd != null)]
		| ( map(.usage.input_tokens // .input_tokens // 0) | add // 0)
		+ ( map(.usage.output_tokens // .output_tokens // 0) | add // 0)
		+ ( map(.usage.cache_creation_input_tokens
			// .usage.cache_creation_tokens
			// .cache_creation_input_tokens
			// .cache_creation_tokens // 0) | add // 0)
		+ ( map(.usage.cache_read_input_tokens
			// .usage.cache_read_tokens
			// .cache_read_input_tokens
			// .cache_read_tokens // 0) | add // 0)
	' 2>/dev/null || printf '0'
}

# -----------------------------------------------------------------------------
# ctg_batch_mt <summary_json_file>
#
# Prints the batch's MT/issue (megatokens per completed issue) as a decimal,
# or prints NOTHING when the metric is unavailable (no cost_summary, zero
# completed issues, or no derivable token total). An empty result is the
# no-op signal.
# -----------------------------------------------------------------------------
ctg_batch_mt() {
	local file="$1"
	[[ -f "$file" ]] || return 0

	# NO-OP gate: cost_summary must be present (issue #580 prerequisite).
	local has_cs
	has_cs=$(jq -r 'if (.cost_summary // null) == null then "no" else "yes" end' \
		"$file" 2>/dev/null) || has_cs="no"
	[[ "$has_cs" == "yes" ]] || return 0

	local completed tokens
	completed=$(jq -r '
		.progress.completed
		// ([.issues[]? | select(.status == "completed"
			or .status == "already_done")] | length)
		// 0' "$file" 2>/dev/null) || completed=0

	tokens=$(jq -r '
		(.cost_summary) as $cs
		| ($cs.total_tokens
			// (($cs.input_tokens // 0)
				+ ($cs.output_tokens // 0)
				+ ($cs.cache_creation_tokens // 0)
				+ ($cs.cache_read_tokens // 0))
			// 0)' "$file" 2>/dev/null) || tokens=0

	# Fallback: cost_summary present but carries no token totals (current
	# #580 records only total_cost_usd). Derive tokens from the run's stage
	# logs using ab-report.sh's parse pattern.
	if [[ -z "$tokens" || "$tokens" == "0" || "$tokens" == "null" ]]; then
		local log_dir
		log_dir=$(jq -r '.log_dir // empty' "$file" 2>/dev/null) || log_dir=""
		if [[ -n "$log_dir" ]]; then
			tokens=$(ctg_tokens_from_logs "$log_dir")
		fi
	fi

	# Not computable → no-op (print nothing).
	[[ -n "$tokens" && "$tokens" != "0" && "$tokens" != "null" ]] || return 0
	[[ -n "$completed" && "$completed" != "0" && "$completed" != "null" ]] \
		|| return 0

	awk -v t="$tokens" -v c="$completed" \
		'BEGIN { printf "%.6f", (t / 1000000) / c }'
}

# -----------------------------------------------------------------------------
# ctg_baseline <window> <summary_file>...
#
# Computes the rolling baseline: the mean MT/issue over up to <window> of the
# most-recent computable summaries. Non-computable summaries (no cost_summary)
# are skipped. Files are consumed in the order given; the caller is expected to
# pass them oldest-first (lexical batch-<ts> sort), so the last <window> are
# the most recent. Prints the mean, or NOTHING when no computable summary
# exists.
# -----------------------------------------------------------------------------
ctg_baseline() {
	local window="$1"; shift
	local -a vals=()
	local f v
	for f in "$@"; do
		v=$(ctg_batch_mt "$f")
		[[ -n "$v" ]] && vals+=("$v")
	done

	local n=${#vals[@]}
	(( n > 0 )) || return 0

	local start=0
	(( n > window )) && start=$(( n - window ))
	local -a recent=("${vals[@]:start}")

	printf '%s\n' "${recent[@]}" \
		| awk '{ sum += $1; c++ } END { if (c > 0) printf "%.6f", sum / c }'
}

# -----------------------------------------------------------------------------
# ctg_evaluate <current_summary> [history_dir]
#
# Produces the advisory verdict JSON on stdout. Honors COST_TREND_WINDOW and
# COST_TREND_FACTOR. Never exits non-zero for a computable/uncomputable metric.
# -----------------------------------------------------------------------------
ctg_evaluate() {
	local current="$1"
	local history_dir="${2:-}"
	local window="${COST_TREND_WINDOW:-5}"
	local factor="${COST_TREND_FACTOR:-1.5}"

	local latest
	latest=$(ctg_batch_mt "$current")

	if [[ -z "$latest" ]]; then
		jq -nc \
			--argjson window "$window" \
			--argjson factor "$factor" \
			'{
				status: "noop",
				warning: false,
				reason: "cost_summary absent or MT/issue not derivable",
				latest_mt_per_issue: null,
				baseline_mt_per_issue: null,
				window: $window,
				factor: $factor
			}'
		return 0
	fi

	local -a hist_files=()
	if [[ -n "$history_dir" && -d "$history_dir" ]]; then
		local f
		while IFS= read -r f; do
			[[ -n "$f" ]] || continue
			[[ "$f" -ef "$current" ]] && continue
			hist_files+=("$f")
		done < <(find "$history_dir" -type f -name 'summary.json' \
			2>/dev/null | sort)
	fi

	local baseline=""
	(( ${#hist_files[@]} > 0 )) \
		&& baseline=$(ctg_baseline "$window" "${hist_files[@]}")

	if [[ -z "$baseline" ]]; then
		jq -nc \
			--argjson latest "$latest" \
			--argjson window "$window" \
			--argjson factor "$factor" \
			'{
				status: "ok",
				warning: false,
				reason: "no baseline history",
				latest_mt_per_issue: $latest,
				baseline_mt_per_issue: null,
				window: $window,
				factor: $factor
			}'
		return 0
	fi

	jq -nc \
		--argjson latest "$latest" \
		--argjson baseline "$baseline" \
		--argjson window "$window" \
		--argjson factor "$factor" \
		'($baseline * $factor) as $threshold
		 | ($latest > $threshold) as $warn
		 | {
			status: "ok",
			warning: $warn,
			latest_mt_per_issue: $latest,
			baseline_mt_per_issue: $baseline,
			threshold_mt_per_issue: $threshold,
			window: $window,
			factor: $factor,
			message: (if $warn
				then "MT/issue \($latest) exceeds baseline "
					+ "\($baseline) × \($factor) = \($threshold)"
				else "MT/issue \($latest) within baseline "
					+ "\($baseline) × \($factor) = \($threshold)"
				end)
		 }'
}

# -----------------------------------------------------------------------------
# CLI entry point
# -----------------------------------------------------------------------------
ctg_usage() {
	cat >&2 <<'EOF'
Usage: cost-trend-guard.sh --current <summary.json> [options]

Options:
  --current <file>       Batch summary/status JSON to evaluate (required)
  --history-dir <dir>    Directory tree containing prior batch-*/summary.json
  --window <N>           Rolling window size (overrides COST_TREND_WINDOW)
  --factor <F>           Warn factor (overrides COST_TREND_FACTOR)
  -h, --help             Show this help

Environment: COST_TREND_WINDOW (default 5), COST_TREND_FACTOR (default 1.5).
Output: a single-line advisory JSON verdict on stdout. Never blocking.
EOF
}

ctg_main() {
	local current="" history_dir=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--current)
				current="${2:-}"; shift 2 ;;
			--history-dir)
				history_dir="${2:-}"; shift 2 ;;
			--window)
				COST_TREND_WINDOW="${2:-}"; shift 2 ;;
			--factor)
				COST_TREND_FACTOR="${2:-}"; shift 2 ;;
			-h|--help)
				ctg_usage; return 0 ;;
			*)
				printf 'cost-trend-guard: unknown argument: %s\n' "$1" >&2
				return 2 ;;
		esac
	done

	if [[ -z "$current" ]]; then
		printf 'cost-trend-guard: --current <summary.json> is required\n' >&2
		return 2
	fi

	ctg_evaluate "$current" "$history_dir"
}

# Only run the CLI when executed directly, not when sourced by tests.
# The `:-` guards keep this safe under `set -u` when sourced by a shell that
# does not populate BASH_SOURCE.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
	ctg_main "$@"
fi
