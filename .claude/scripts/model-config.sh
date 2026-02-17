#!/usr/bin/env bash
#
# model-config.sh - Tier-to-model mapping for orchestrator pipeline
#
# Provides semantic tier abstraction (light/standard/advanced) decoupled
# from specific model names. Update this single file when models change.
#
# Usage: source this file, then call resolve_model <stage> [complexity]
#

# =============================================================================
# TIER-TO-MODEL MAPPING (TIER_MODEL)
# =============================================================================
#
# Semantic tiers mapped to concrete model names.
# Change models here — propagates to all stages automatically.
#
# Uses case-based lookup for bash 3.2 compatibility (macOS default).
#

_tier_to_model() {
	case "$1" in
		light)    printf '%s' "haiku" ;;
		standard) printf '%s' "sonnet" ;;
		advanced) printf '%s' "opus" ;;
		*)        printf '%s' "opus" ;;
	esac
}

# =============================================================================
# STAGE-TO-TIER DEFAULTS (STAGE_TIER)
# =============================================================================
#
# Each orchestrator stage maps to a tier based on its cognitive demands.
#
# light    — mechanical: parse markdown, run commands, fill templates
# standard — judgment: reviews, simple implementations, pattern matching
# advanced — deep reasoning: complex implementation, root cause analysis
#

_stage_to_tier() {
	case "$1" in
		parse-issue)   printf '%s' "light" ;;
		validate-plan) printf '%s' "light" ;;
		implement)     printf '%s' "advanced" ;;
		task-review)   printf '%s' "standard" ;;
		fix)           printf '%s' "advanced" ;;
		test)          printf '%s' "light" ;;
		review)        printf '%s' "standard" ;;
		simplify)      printf '%s' "standard" ;;
		pr)            printf '%s' "light" ;;
		spec-review)   printf '%s' "standard" ;;
		code-review)   printf '%s' "standard" ;;
		complete)      printf '%s' "light" ;;
		docs)          printf '%s' "light" ;;
		*)             printf '%s' "" ;;
	esac
}

# =============================================================================
# COMPLEXITY-TO-TIER MAPPING (COMPLEXITY_TIER)
# =============================================================================
#
# Task complexity hints (S/M/L) from issue parsing override stage defaults.
# The quality loop forwards these to implement, simplify, review, and fix stages.
#

_complexity_to_tier() {
	case "$1" in
		S) printf '%s' "standard" ;;
		M) printf '%s' "advanced" ;;
		L) printf '%s' "advanced" ;;
		*) printf '%s' "" ;;
	esac
}

# =============================================================================
# STAGE PREFIX MATCHING
# =============================================================================
#
# Orchestrator stage names follow the pattern: <base>-<suffix>
# e.g. "implement-task-1", "review-task-1-iter-2", "fix-tests-iter-1"
#
# We match the longest known prefix for specificity:
# "spec-review-iter-1" matches "spec-review" (11 chars) over "review" (6)
#

# All known stage prefixes, ordered longest-first for greedy matching
if [[ -z "${_STAGE_PREFIXES+set}" ]]; then
	readonly -a _STAGE_PREFIXES=(
		spec-review code-review task-review validate-plan
		parse-issue implement simplify complete review test docs fix pr
	)
fi

_match_stage_prefix() {
	local stage_name="$1"

	for prefix in "${_STAGE_PREFIXES[@]}"; do
		if [[ "$stage_name" == "$prefix" || \
			"$stage_name" == "$prefix-"* ]]; then
			printf '%s' "$prefix"
			return 0
		fi
	done

	return 1
}

# =============================================================================
# resolve_model() - Determine the model for a given stage and complexity
# =============================================================================
#
# Arguments:
#   $1 - stage name (e.g. "implement-task-1", "review-task-1-iter-2")
#   $2 - optional complexity hint (S, M, or L)
#
# Output:
#   Prints the model name to stdout (haiku, sonnet, or opus)
#
# Logic:
#   1. Match stage name against known prefixes (longest match wins)
#   2. Look up default tier for that stage
#   3. If complexity hint provided and valid, override with its tier
#   4. Fall back to advanced (opus) for unknown stages
#

resolve_model() {
	local stage_name="${1:-}"
	local complexity="${2:-}"
	local tier=""
	local matched_prefix=""

	# Match stage name against known prefixes
	if [[ -n "$stage_name" ]]; then
		matched_prefix=$(_match_stage_prefix "$stage_name") || true

		if [[ -n "$matched_prefix" ]]; then
			tier=$(_stage_to_tier "$matched_prefix")
		fi
	fi

	# Fall back to advanced for unknown stages
	if [[ -z "$tier" ]]; then
		tier="advanced"
	fi

	# Apply complexity hint — overrides stage default when provided
	# The quality loop forwards task-level complexity to implement, simplify,
	# review, and fix stages so model selection scales with task size
	if [[ -n "$complexity" ]]; then
		local complexity_tier
		complexity_tier=$(_complexity_to_tier "$complexity")

		if [[ -n "$complexity_tier" ]]; then
			tier="$complexity_tier"
		fi
	fi

	printf '%s\n' "$(_tier_to_model "$tier")"
}
