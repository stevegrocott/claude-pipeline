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
# S, M → standard → sonnet  (judgment tier)
# L    → advanced → opus    (deep-reasoning tier)
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
# TURN BUDGET OVERRIDES
# =============================================================================
#
# Stage-type-aware turn limits cap the --max-turns flag passed to claude(1).
# Operators can tune these via environment variables without modifying the
# orchestrator source.
#
# Defaults below were calibrated against tools/analyze-turns.sh run on the
# first batch of real pipeline runs (initial calibration, 2026-05-13):
#
#   === Turns-Used Distribution by Stage Type ===
#       (from 24 stage logs across 31 scanned)
#
#     Stage               N    Min    p50    p90   Max
#     --------------------------------------------------
#     implement-task      14      8   16.0   28.0    38
#     simplify             6      4    6.5   10.0    11
#     fix-review           4      9   13.5   17.0    19
#
#   simplify p90=10 → cap at 12 (20% headroom above p90; below the
#   haiku light-tier generic cap of 15 that would otherwise apply).
#
#   fix-review p90=17 → cap at 20 (17% headroom; below the sonnet
#   generic cap of 25 that would otherwise apply).
#
#   Note: num_turns is capped by each run's --max-turns budget, so p90/Max
#   understate true demand for runs that hit the prior cap. Re-run
#   analyze-turns.sh after accumulating ≥50 logs per class before tuning.
#   To regenerate: tools/analyze-turns.sh logs/implement-issue
#
# simplify-* stages (haiku model, light-tier):
#   Default: 12 turns   Env: MAX_TURNS_SIMPLIFY
#   Targeted edits — more scope than parse, less than full implement.
#
# fix-* / fix-review-* stages (sonnet model, standard-tier):
#   Default: 20 turns   Env: MAX_TURNS_FIX_REVIEW
#   Targeted corrections — less scope than implement/review.
#
# pr stage (sonnet model, standard-tier):
#   Default: 10 turns   Env: MAX_TURNS_PR
#   Push + create MR; default is 10 rather than 5 to accommodate a
#   rebase-before-push when the branch has drifted from main.
#
# pr-review budget is intentionally fixed and NOT affected by env vars:
#   pr-review: 10 turns (focused diff analysis)
#
# Decision logic: implement-issue-orchestrator.sh
# (search for MAX_TURNS_SIMPLIFY / MAX_TURNS_FIX_REVIEW / MAX_TURNS_PR)
# =============================================================================

# =============================================================================
# PER-LOOP WALL-CLOCK BUDGETS
# =============================================================================
#
# The PR-review loop has its own wall-clock budget so it cannot be starved by
# earlier stages consuming the global MAX_ORCHESTRATOR_WALL_TIME budget.
# The budget is derived from the diff-size-scaled per-iteration timeout, so
# "at least one full iteration completes" is structurally guaranteed.
#
# PR-review loop budget:
#   Formula:  pr_review_timeout × max(profile_max_iter, 1)
#               + PR_REVIEW_WALL_TIME_SLACK
#   Default:  2520s  (1200 × 2 + 120; covers a 200+ line diff at full
#                     iterations with the default 120s slack)
#   Env vars:
#     PR_REVIEW_WALL_BUDGET      — full override (seconds); when set,
#                                  replaces the formula entirely
#     PR_REVIEW_WALL_TIME_SLACK  — slack added on top of the per-iteration
#                                  budget (default 120s)
#
#   pr_review_timeout and profile_max_iter both come from get_pr_review_config()
#   + apply_profile_to_pr_review_max_iter() — they scale with diff size:
#     <50 lines  → 360s,  max_iter=1 (fixed)           → budget = 360  + slack
#     <200 lines → 600s,  max_iter=MAX_PR_REVIEW_ITERATIONS → budget = 600  × max(iter,1) + slack
#     200+ lines → 1200s, max_iter=MAX_PR_REVIEW_ITERATIONS → budget = 1200 × max(iter,1) + slack
#   For minimal pipeline profile, max_iter is capped at 1 regardless of diff size.
#   The default 2520s covers the worst case (200+ line diff, 2 iterations,
#   120s slack).  On smaller diffs the computed budget is tighter.
#   PR_REVIEW_WALL_BUDGET overrides the computed value entirely when set.
#
#   This budget is checked IN ADDITION TO the global clock — the loop exits
#   when either guard fires.  Within its own budget, the loop is protected
#   from global-clock exhaustion caused by earlier stages.
#
# Test loop budget:
#   Formula:  test_iter_timeout × max(TEST_LOOP_PLANNED_ITERATIONS, 1)
#               + TEST_ITER_WALL_TIME_SLACK
#   Default:  2820s  (900 × 3 + 120; covers 3 full test iterations with
#                     the default 120s slack)
#   Env vars:
#     TEST_LOOP_WALL_BUDGET          — full override (seconds); when set,
#                                      replaces the formula entirely
#     TEST_LOOP_PLANNED_ITERATIONS   — sane planned iteration count used
#                                      in the formula (default 3; intentionally
#                                      smaller than MAX_TEST_ITERATIONS=7)
#     TEST_ITER_WALL_TIME_SLACK      — slack added on top of the per-iteration
#                                      budget (default 120s)
#
#   test_iter_timeout comes from get_stage_timeout("test-iter") = 900s.
#   TEST_LOOP_PLANNED_ITERATIONS defaults to 3 — a sane expected iteration
#   count that is structurally smaller than the hard cap MAX_TEST_ITERATIONS=7.
#   Operators can raise it via env without changing the hard cap.
#
#   This budget is checked IN ADDITION TO the global clock — the loop exits
#   when either guard fires.  Within its own budget, the loop is protected
#   from global-clock exhaustion caused by earlier stages.
#
# Global orchestrator wall-clock budget (MAX_ORCHESTRATOR_WALL_TIME):
#   Default = sum of all per-phase budgets so the global cap never fires
#   while an inner loop is within its own budget.
#   Formula: calc_orchestrator_wall_time()
#     = calc_test_loop_budget()
#       + PR-review worst-case (1200s × max(MAX_PR_REVIEW_ITERATIONS,1)
#                               + PR_REVIEW_WALL_TIME_SLACK)
#       + overhead (validate_plan 1800 + implement 1800 + task-review 900
#                   + test 600 + pr-create 600 = 5700s)
#   Default: 11040s (2820 + 2520 + 5700)
#   Enforced at the complexity-adjustment step (after env vars take effect).
#   Env vars:
#     MAX_ORCHESTRATOR_WALL_TIME — initial base (default 11040s; raised to
#                                  the phase-budget sum if env value is less)
#   After the phase-budget floor, per-L-task bumps (1800s each) are added
#   on top, capped at 4× the phase-budget-floored base value.
#
# Decision logic / enforcement: implement-issue-orchestrator.sh
# (search for PR_REVIEW_WALL_BUDGET / check_pr_review_wall_timeout,
#  TEST_LOOP_WALL_BUDGET / check_test_loop_wall_timeout / calc_test_loop_budget,
#  and calc_orchestrator_wall_time / MAX_ORCHESTRATOR_WALL_TIME)
# =============================================================================

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
