#!/usr/bin/env bash
#
# model-config.sh - Tier-to-model mapping for orchestrator pipeline
#
# Data-only: tier-to-model table, stage-to-tier tables,
# complexity-to-tier table, model-escalation table, and the ordered
# stage-prefix list.  Decision logic for retry and model-fallback
# lives in the companion skills:
#   .claude/skills/retry-policy/SKILL.md
#   .claude/skills/model-fallback/SKILL.md
#
# Usage: source this file, then call resolve_model <stage> [complexity]
#

# Idempotent sourcing guard — skip re-definition on repeated source.
[[ -z "${_MODEL_CONFIG_LOADED+set}" ]] || return 0
readonly _MODEL_CONFIG_LOADED=1

# =============================================================================
# TIER-TO-MODEL TABLE
# =============================================================================
#
# Semantic tiers mapped to concrete model names.
# Change models here — propagates to all stages automatically.
#
# light    → haiku   (mechanical: parse, template, simplify)
# standard → sonnet  (judgment: review, fix, match)
# advanced → opus    (deep reasoning: complex implementation)
#
# Lookup: _tier_to_model <tier>
# Decision logic: .claude/skills/model-fallback/SKILL.md

readonly _MODEL_light="haiku"
readonly _MODEL_standard="sonnet"
readonly _MODEL_advanced="opus"
readonly _MODEL_default="opus"    # fallback for unknown tiers

# =============================================================================
# COMPLEXITY-TO-TIER TABLE
# =============================================================================
#
# Task complexity hints (S/M/L) from issue parsing override stage defaults.
#
# S, M → standard  (judgment tier)
# L    → advanced  (deep-reasoning tier)
#
# Lookup: _complexity_to_tier <hint>
# Decision logic: .claude/skills/model-fallback/SKILL.md

readonly _COMPLEXITY_S="standard"
readonly _COMPLEXITY_M="standard"
readonly _COMPLEXITY_L="advanced"

# =============================================================================
# MODEL ESCALATION TABLE
# =============================================================================
#
# Next model up in the haiku → sonnet → opus escalation chain.
# opus → opus signals the ceiling (no further escalation).
#
# Lookup: _next_model_up <model>
# Retry decisions:    .claude/skills/retry-policy/SKILL.md
# Fallback decisions: .claude/skills/model-fallback/SKILL.md

readonly _NEXT_MODEL_haiku="sonnet"
readonly _NEXT_MODEL_sonnet="opus"
readonly _NEXT_MODEL_opus="opus"
readonly _NEXT_MODEL_default="opus"   # fallback for unknown models

# =============================================================================
# STAGE-TO-TIER TABLES
# =============================================================================
#
# Each orchestrator stage maps to a tier based on its cognitive demands.
#
# light    — mechanical: parse markdown, run commands, fill templates
# standard — judgment: reviews, fixes, pattern matching
#
# (No stage defaults to advanced; complexity hint upgrades to advanced.)
#
# Lookup: _stage_to_tier <stage>
# Decision logic: .claude/skills/model-fallback/SKILL.md

readonly -a _LIGHT_STAGES=(
	parse-issue validate-plan triage
	test research simplify
	e2e-verify deploy-verify
	complete docs acceptance-test
)

readonly -a _STANDARD_STAGES=(
	implement task-review fix test-iter review
	pr pr-review pr-fix
	spec-review code-review
	fix-e2e fix-acceptance-test fix-deploy-verify
)

# =============================================================================
# STAGE PREFIX MATCHING TABLE
# =============================================================================
#
# Orchestrator stage names follow the pattern: <base>-<suffix>
# e.g. "implement-task-1", "review-task-1-iter-2", "fix-tests-iter-1"
#
# Listed longest-first so _match_stage_prefix finds the most specific
# match: "spec-review-iter-1" matches "spec-review" (11 chars) over
# "review" (6 chars).
#
# Lookup: _match_stage_prefix <stage_name>

readonly -a _STAGE_PREFIXES=(
	fix-acceptance-test acceptance-test validate-plan
	fix-deploy-verify deploy-verify spec-review code-review
	task-review parse-issue e2e-verify
	pr-review implement simplify research complete
	pr-fix fix-e2e review test-iter test docs fix pr
	triage
)

# =============================================================================
# LOOKUP FUNCTIONS
# =============================================================================
#
# Thin wrappers over the data tables above.  All retry / escalation
# decision logic lives in the skills; these functions only look up data.

# _tier_to_model <tier>
# Prints the model name for the given semantic tier.
# Unknown tiers fall back to _MODEL_default (opus).
_tier_to_model() {
	local _var="_MODEL_${1//[^a-zA-Z]/}"
	printf '%s' "${!_var:-$_MODEL_default}"
}

# _stage_to_tier <stage>
# Prints the tier for an exact stage name.
# Returns empty string for unknown stages.
_stage_to_tier() {
	local _s
	for _s in "${_LIGHT_STAGES[@]}"; do
		[[ "$_s" == "${1:-}" ]] || continue
		printf '%s' "light"
		return 0
	done
	for _s in "${_STANDARD_STAGES[@]}"; do
		[[ "$_s" == "${1:-}" ]] || continue
		printf '%s' "standard"
		return 0
	done
	printf '%s' ""
}

# _complexity_to_tier <hint>
# Prints the tier for S/M/L complexity hint.
# Returns empty string for unknown hints.
_complexity_to_tier() {
	local _var="_COMPLEXITY_${1//[^a-zA-Z]/}"
	printf '%s' "${!_var:-}"
}

# _match_stage_prefix <stage_name>
# Prints the longest known prefix that matches the stage name.
# Returns 1 and prints nothing for unknown stage names.
_match_stage_prefix() {
	local _stage_name="$1" _prefix
	for _prefix in "${_STAGE_PREFIXES[@]}"; do
		[[ "$_stage_name" == "$_prefix" || \
			"$_stage_name" == "$_prefix-"* ]] || continue
		printf '%s' "$_prefix"
		return 0
	done
	return 1
}

# _next_model_up <model>
# Prints the next model up in the escalation chain.
# opus stays at opus (ceiling); unknown models fall back to opus.
# Full decision logic: .claude/skills/model-fallback/SKILL.md
_next_model_up() {
	local _var="_NEXT_MODEL_${1//[^a-zA-Z]/}"
	printf '%s' "${!_var:-$_NEXT_MODEL_default}"
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
#   3. If complexity hint provided and tier is not light, override
#   4. Fall back to advanced (opus) for unknown stages
#

resolve_model() {
	local stage_name="${1:-}"
	local complexity="${2:-}"
	local tier="" matched_prefix="" complexity_tier=""

	# Match stage name against known prefixes
	[[ -n "$stage_name" ]] && \
		matched_prefix=$(_match_stage_prefix "$stage_name") || true
	[[ -n "$matched_prefix" ]] && \
		tier=$(_stage_to_tier "$matched_prefix") || true

	# Fall back to advanced for unknown stages
	tier="${tier:-advanced}"

	# Apply complexity hint — light-tier stages are always haiku;
	# complexity hints are ignored for them.  The quality loop forwards
	# task-level complexity to implement, review, and fix stages so
	# model selection scales with task size.
	[[ -n "$complexity" && "$tier" != "light" ]] && \
		complexity_tier=$(_complexity_to_tier "$complexity") || true
	[[ -n "$complexity_tier" ]] && tier="$complexity_tier" || true

	printf '%s\n' "$(_tier_to_model "$tier")"
}

# =============================================================================
# USAGE-AWARE MODEL SELECTION (effective_model / effective_fallback)
# =============================================================================
#
# Wraps resolve_model with a check against claude-usage.sh's
# is_model_exhausted.  When the picked model is exhausted (per-model
# bucket full and overage isn't absorbing), escalates via _next_model_up
# until a non-exhausted model is found or the opus ceiling is reached.
#
# When claude-usage.sh isn't loaded OR no sessionKey is configured,
# is_model_exhausted returns false for everything and these wrappers
# behave identically to resolve_model / _next_model_up — zero regression
# for users who haven't opted into usage polling.
#

_usage_aware_escalate() {
	local model="$1" original="$1" next _reset _msg
	declare -F is_model_exhausted >/dev/null 2>&1 || {
		printf '%s\n' "$model"
		return 0
	}

	# _next_model_up returns the same model at the opus ceiling, which
	# terminates the loop unconditionally — no infinite spin if every
	# tier is exhausted.
	while is_model_exhausted "$model"; do
		next=$(_next_model_up "$model")
		[[ "$next" == "$model" ]] && break
		model="$next"
	done

	# Surface the escalation so operators can correlate cost spikes with
	# bucket exhaustion.  Logged via the orchestrator's log if available,
	# else stderr — see _usage_log in claude-usage.sh.
	[[ "$model" != "$original" ]] && \
		declare -F model_reset_at >/dev/null 2>&1 && {
			_reset=$(model_reset_at "$original")
			_msg="Usage gate: $original exhausted"
			_msg+=" (resets ${_reset}) — escalating to $model"
			_usage_log "$_msg"
		} || true

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
