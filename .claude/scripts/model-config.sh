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
# light    — mechanical: parse markdown, run commands, fill templates, simplify
# standard — judgment: reviews, fixes, pattern matching
# advanced — deep reasoning: complex implementation, root cause analysis
#

_stage_to_tier() {
	case "$1" in
		parse-issue)    printf '%s' "light" ;;
		validate-plan)  printf '%s' "light" ;;
		triage)         printf '%s' "light" ;;
		implement)      printf '%s' "standard" ;;
		task-review)    printf '%s' "standard" ;;
		fix)            printf '%s' "standard" ;;
		test-iter)      printf '%s' "standard" ;;
		test)           printf '%s' "light" ;;
		review)         printf '%s' "standard" ;;
		research)       printf '%s' "light" ;;
		simplify)       printf '%s' "light" ;;
		pr)             printf '%s' "standard" ;;
		pr-review)      printf '%s' "standard" ;;
		pr-fix)         printf '%s' "standard" ;;
		spec-review)    printf '%s' "standard" ;;
		code-review)    printf '%s' "standard" ;;
		e2e-verify)     printf '%s' "light" ;;
		fix-e2e)        printf '%s' "standard" ;;
		fix-acceptance-test) printf '%s' "standard" ;;
		fix-deploy-verify) printf '%s' "standard" ;;
		deploy-verify)  printf '%s' "light" ;;
		complete)       printf '%s' "light" ;;
		docs)           printf '%s' "light" ;;
		acceptance-test) printf '%s' "light" ;;
		*)              printf '%s' "" ;;
	esac
}

# =============================================================================
# COMPLEXITY-TO-TIER MAPPING (COMPLEXITY_TIER)
# =============================================================================
#
# Task complexity hints (S/M/L) from issue parsing override stage defaults.
# The quality loop forwards these to implement, review, and fix stages.
#

_complexity_to_tier() {
	case "$1" in
		S) printf '%s' "standard" ;;
		M) printf '%s' "standard" ;;
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
		fix-acceptance-test acceptance-test validate-plan
		fix-deploy-verify deploy-verify spec-review code-review task-review parse-issue e2e-verify
		pr-review implement simplify research complete pr-fix fix-e2e review test-iter test docs fix pr
		triage
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

	# Apply complexity hint — overrides stage default when provided.
	# Light-tier stages (test, parse-issue, validate-plan, complete, docs,
	# simplify, acceptance-test) are mechanical and always use haiku;
	# complexity hints are ignored for them.
	# The quality loop forwards task-level complexity to implement, review,
	# and fix stages so model selection scales with task size.
	if [[ -n "$complexity" && "$tier" != "light" ]]; then
		local complexity_tier
		complexity_tier=$(_complexity_to_tier "$complexity")

		if [[ -n "$complexity_tier" ]]; then
			tier="$complexity_tier"
		fi
	fi

	printf '%s\n' "$(_tier_to_model "$tier")"
}

# =============================================================================
# MODEL ESCALATION (_next_model_up)
# =============================================================================
#
# Given a model name, returns the next model up in the tier hierarchy.
# Used for --fallback-model to provide resilience when the primary model
# is unavailable or rate-limited.
#
# haiku  -> sonnet
# sonnet -> opus
# opus   -> opus (ceiling)
#

_next_model_up() {
	case "$1" in
		haiku)  printf '%s' "sonnet" ;;
		sonnet) printf '%s' "opus" ;;
		opus)   printf '%s' "opus" ;;
		*)      printf '%s' "opus" ;;
	esac
}

# =============================================================================
# USAGE-AWARE MODEL SELECTION (effective_model / effective_fallback)
# =============================================================================
#
# Wraps resolve_model with a check against claude-usage.sh's
# is_model_exhausted. When the picked model is exhausted (per-model bucket
# full and overage isn't absorbing), escalate via _next_model_up until we
# find one that isn't exhausted or hit the opus ceiling.
#
# When claude-usage.sh isn't loaded OR no sessionKey is configured,
# is_model_exhausted returns false for everything and these wrappers
# behave identically to resolve_model / _next_model_up — zero regression
# for users who haven't opted into usage polling.
#

_usage_aware_escalate() {
	local model="$1" original="$1" next
	# is_model_exhausted comes from claude-usage.sh. When it isn't sourced
	# (or polling is unconfigured), treat all models as not exhausted.
	if ! declare -F is_model_exhausted >/dev/null 2>&1; then
		printf '%s\n' "$model"
		return 0
	fi

	# _next_model_up returns the same model at the opus ceiling, which
	# terminates the loop unconditionally — no infinite spin if every
	# tier is exhausted.
	while is_model_exhausted "$model"; do
		next=$(_next_model_up "$model")
		if [[ "$next" == "$model" ]]; then
			break
		fi
		model="$next"
	done

	# Surface the escalation so operators can correlate cost spikes with
	# bucket exhaustion. Logged via the orchestrator's `log` if available,
	# else stderr — see _usage_log in claude-usage.sh.
	if [[ "$model" != "$original" ]] && declare -F model_reset_at >/dev/null 2>&1; then
		local _reset
		_reset=$(model_reset_at "$original")
		_usage_log "Usage gate: $original exhausted (resets ${_reset}) — escalating to $model"
	fi

	printf '%s\n' "$model"
}

# effective_model(stage, complexity) — resolve_model with usage gating.
effective_model() {
	_usage_aware_escalate "$(resolve_model "$@")"
}

# effective_fallback(model) — _next_model_up with usage gating.
# Used to compute the --fallback-model arg for the Claude CLI.
effective_fallback() {
	_usage_aware_escalate "$(_next_model_up "$1")"
}
