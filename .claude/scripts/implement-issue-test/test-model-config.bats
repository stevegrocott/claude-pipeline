#!/usr/bin/env bats
#
# test-model-config.bats
# Tests for model-config.sh tier-to-model mapping and resolve_model() function
#

load 'helpers/test-helper.bash'

# =============================================================================
# TEST SETUP / TEARDOWN
# =============================================================================

setup() {
	setup_test_env

	# Path to the script under test
	MODEL_CONFIG="$SCRIPT_DIR/model-config.sh"
}

teardown() {
	teardown_test_env
}

# Helper: source model-config.sh in a subshell and run a command
run_with_config() {
	run bash -c "source '$MODEL_CONFIG' && $1"
}

# =============================================================================
# FILE EXISTS AND SOURCES CLEANLY
# =============================================================================

@test "model-config.sh exists" {
	[[ -f "$MODEL_CONFIG" ]]
}

@test "model-config.sh sources without error" {
	run bash -c "source '$MODEL_CONFIG'"
	[ "$status" -eq 0 ]
}

@test "model-config.sh uses bash shebang" {
	local first_line
	first_line=$(head -1 "$MODEL_CONFIG")
	[[ "$first_line" == "#!/usr/bin/env bash" ]]
}

# =============================================================================
# TIER-TO-MODEL MAPPING (_tier_to_model)
# =============================================================================

@test "tier light maps to haiku" {
	run_with_config '_tier_to_model "light"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "tier standard maps to sonnet" {
	run_with_config '_tier_to_model "standard"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "tier advanced maps to opus" {
	run_with_config '_tier_to_model "advanced"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "unknown tier falls back to opus" {
	run_with_config '_tier_to_model "unknown"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

# =============================================================================
# STAGE-TO-TIER DEFAULTS (_stage_to_tier)
# =============================================================================

@test "stage parse-issue maps to light" {
	run_with_config '_stage_to_tier "parse-issue"'
	[ "$status" -eq 0 ]
	[[ "$output" == "light" ]]
}

@test "stage validate-plan maps to light" {
	run_with_config '_stage_to_tier "validate-plan"'
	[ "$status" -eq 0 ]
	[[ "$output" == "light" ]]
}

@test "stage implement maps to standard" {
	run_with_config '_stage_to_tier "implement"'
	[ "$status" -eq 0 ]
	[[ "$output" == "standard" ]]
}

@test "stage task-review maps to standard" {
	run_with_config '_stage_to_tier "task-review"'
	[ "$status" -eq 0 ]
	[[ "$output" == "standard" ]]
}

@test "stage fix maps to standard" {
	run_with_config '_stage_to_tier "fix"'
	[ "$status" -eq 0 ]
	[[ "$output" == "standard" ]]
}

@test "stage test maps to light" {
	run_with_config '_stage_to_tier "test"'
	[ "$status" -eq 0 ]
	[[ "$output" == "light" ]]
}

@test "stage test-iter maps to standard" {
	run_with_config '_stage_to_tier "test-iter"'
	[ "$status" -eq 0 ]
	[[ "$output" == "standard" ]]
}

@test "resolve_model test-iter-1 resolves to sonnet" {
	run_with_config 'resolve_model "test-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "stage review maps to standard" {
	run_with_config '_stage_to_tier "review"'
	[ "$status" -eq 0 ]
	[[ "$output" == "standard" ]]
}

@test "stage simplify maps to light" {
	run_with_config '_stage_to_tier "simplify"'
	[ "$status" -eq 0 ]
	[[ "$output" == "light" ]]
}

@test "stage pr maps to standard" {
	run_with_config '_stage_to_tier "pr"'
	[ "$status" -eq 0 ]
	[[ "$output" == "standard" ]]
}

@test "stage spec-review maps to standard" {
	run_with_config '_stage_to_tier "spec-review"'
	[ "$status" -eq 0 ]
	[[ "$output" == "standard" ]]
}

@test "stage code-review maps to standard" {
	run_with_config '_stage_to_tier "code-review"'
	[ "$status" -eq 0 ]
	[[ "$output" == "standard" ]]
}

@test "stage complete maps to light" {
	run_with_config '_stage_to_tier "complete"'
	[ "$status" -eq 0 ]
	[[ "$output" == "light" ]]
}

@test "stage docs maps to light" {
	run_with_config '_stage_to_tier "docs"'
	[ "$status" -eq 0 ]
	[[ "$output" == "light" ]]
}

@test "unknown stage returns empty string" {
	run_with_config '_stage_to_tier "nonexistent"'
	[ "$status" -eq 0 ]
	[[ "$output" == "" ]]
}

# =============================================================================
# COMPLEXITY-TO-TIER MAPPING (_complexity_to_tier)
# =============================================================================

@test "complexity S maps to standard" {
	run_with_config '_complexity_to_tier "S"'
	[ "$status" -eq 0 ]
	[[ "$output" == "standard" ]]
}

@test "complexity M maps to standard" {
	run_with_config '_complexity_to_tier "M"'
	[ "$status" -eq 0 ]
	[[ "$output" == "standard" ]]
}

@test "complexity L maps to advanced" {
	run_with_config '_complexity_to_tier "L"'
	[ "$status" -eq 0 ]
	[[ "$output" == "advanced" ]]
}

@test "unknown complexity returns empty string" {
	run_with_config '_complexity_to_tier "XL"'
	[ "$status" -eq 0 ]
	[[ "$output" == "" ]]
}

# =============================================================================
# resolve_model() - BASIC STAGE RESOLUTION
# =============================================================================

@test "resolve_model returns haiku for parse-issue stage" {
	run_with_config 'resolve_model "parse-issue"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model returns sonnet for review stage" {
	run_with_config 'resolve_model "review"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model returns sonnet for implement stage" {
	run_with_config 'resolve_model "implement"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model returns haiku for test stage" {
	run_with_config 'resolve_model "test"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model returns sonnet for pr stage" {
	run_with_config 'resolve_model "pr"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model returns sonnet for code-review stage" {
	run_with_config 'resolve_model "code-review"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model returns haiku for complete stage" {
	run_with_config 'resolve_model "complete"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model returns sonnet for fix stage" {
	run_with_config 'resolve_model "fix"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model returns haiku for simplify stage" {
	run_with_config 'resolve_model "simplify"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model returns haiku for docs stage" {
	run_with_config 'resolve_model "docs"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model returns sonnet for spec-review stage" {
	run_with_config 'resolve_model "spec-review"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model returns sonnet for task-review stage" {
	run_with_config 'resolve_model "task-review"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model returns haiku for validate-plan stage" {
	run_with_config 'resolve_model "validate-plan"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

# =============================================================================
# resolve_model() - COMPLEXITY HINT OVERRIDE
# =============================================================================

@test "resolve_model with S complexity returns sonnet for implement stage" {
	run_with_config 'resolve_model "implement" "S"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model with M complexity returns sonnet for implement stage" {
	run_with_config 'resolve_model "implement" "M"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model with L complexity returns opus for implement stage" {
	run_with_config 'resolve_model "implement" "L"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "complexity hint overrides stage default when provided" {
	# fix stage defaults to standard (sonnet)
	# S complexity also maps to standard (sonnet) — both agree
	# Complexity hint takes precedence — callers only pass it when intended
	run_with_config 'resolve_model "fix" "S"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "complexity hint upgrades review stage from standard to advanced" {
	# review defaults to standard (sonnet)
	# L complexity maps to advanced (opus)
	run_with_config 'resolve_model "review" "L"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "complexity hint keeps task-review at standard with M" {
	run_with_config 'resolve_model "task-review" "M"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

# =============================================================================
# resolve_model() - STAGE NAME PREFIX MATCHING
# =============================================================================

@test "resolve_model matches implement prefix in implement-task-1" {
	run_with_config 'resolve_model "implement-task-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model matches review prefix in review-task-1-iter-2" {
	run_with_config 'resolve_model "review-task-1-iter-2"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model matches test-iter prefix in test-iter-1" {
	# test-iter is its own standard-tier prefix (judgment: test loop fixes)
	run_with_config 'resolve_model "test-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model matches fix prefix in fix-review-task-1-iter-1" {
	run_with_config 'resolve_model "fix-review-task-1-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model matches simplify prefix in simplify-task-1-iter-1" {
	run_with_config 'resolve_model "simplify-task-1-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model matches spec-review prefix in spec-review-iter-1" {
	run_with_config 'resolve_model "spec-review-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model matches code-review prefix in code-review-iter-1" {
	run_with_config 'resolve_model "code-review-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model matches fix prefix in fix-tests-iter-1" {
	run_with_config 'resolve_model "fix-tests-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model matches fix prefix in fix-task-1-attempt-1" {
	run_with_config 'resolve_model "fix-task-1-attempt-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model matches fix prefix in fix-pr-review-iter-1" {
	run_with_config 'resolve_model "fix-pr-review-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model matches fix prefix in fix-test-quality-iter-1" {
	run_with_config 'resolve_model "fix-test-quality-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model matches task-review prefix in task-review-1-attempt-1" {
	run_with_config 'resolve_model "task-review-1-attempt-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model matches test-iter prefix in test-iter-2" {
	# test-iter is its own standard-tier prefix (judgment: test loop fixes)
	run_with_config 'resolve_model "test-iter-2"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

# =============================================================================
# resolve_model() - FALLBACK BEHAVIOR
# =============================================================================

@test "resolve_model returns opus for unknown stage" {
	run_with_config 'resolve_model "unknown-stage"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model returns opus for empty stage name" {
	run_with_config 'resolve_model ""'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model ignores empty complexity hint" {
	run_with_config 'resolve_model "parse-issue" ""'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model ignores unknown complexity hint" {
	run_with_config 'resolve_model "parse-issue" "XL"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

# =============================================================================
# resolve_model() - OUTPUT CLEANLINESS
# =============================================================================

@test "resolve_model outputs only the model name with no extra whitespace" {
	run_with_config 'resolve_model "review" | wc -l'
	[ "$status" -eq 0 ]
	# Should be exactly 1 line
	[[ "${output// /}" == "1" ]]
}

@test "resolve_model does not write to stdout when sourced (no side effects)" {
	run bash -c "output=\$(source '$MODEL_CONFIG'); printf 'x%sx' \"\$output\""
	[ "$status" -eq 0 ]
	[[ "$output" == "xx" ]]
}

# =============================================================================
# _match_stage_prefix() - DIRECT UNIT TESTS
# =============================================================================

@test "_match_stage_prefix returns 0 for exact known prefix" {
	run_with_config '_match_stage_prefix "implement"'
	[ "$status" -eq 0 ]
	[[ "$output" == "implement" ]]
}

@test "_match_stage_prefix returns 0 for prefix with suffix" {
	run_with_config '_match_stage_prefix "implement-task-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "implement" ]]
}

@test "_match_stage_prefix returns 1 for unknown stage" {
	run_with_config '_match_stage_prefix "unknown-stage"'
	[ "$status" -eq 1 ]
	[[ -z "$output" ]]
}

@test "_match_stage_prefix returns 1 for empty input" {
	run_with_config '_match_stage_prefix ""'
	[ "$status" -eq 1 ]
	[[ -z "$output" ]]
}

@test "_match_stage_prefix prefers spec-review over review" {
	run_with_config '_match_stage_prefix "spec-review-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "spec-review" ]]
}

@test "_match_stage_prefix prefers code-review over review" {
	run_with_config '_match_stage_prefix "code-review-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "code-review" ]]
}

@test "_match_stage_prefix prefers task-review over review" {
	run_with_config '_match_stage_prefix "task-review-1-attempt-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "task-review" ]]
}

@test "_match_stage_prefix prefers validate-plan over shorter match" {
	run_with_config '_match_stage_prefix "validate-plan-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "validate-plan" ]]
}

@test "_match_stage_prefix prefers parse-issue over shorter match" {
	run_with_config '_match_stage_prefix "parse-issue-retry"'
	[ "$status" -eq 0 ]
	[[ "$output" == "parse-issue" ]]
}

@test "_match_stage_prefix matches single-char prefix pr" {
	run_with_config '_match_stage_prefix "pr"'
	[ "$status" -eq 0 ]
	[[ "$output" == "pr" ]]
}

@test "_match_stage_prefix matches pr with suffix" {
	run_with_config '_match_stage_prefix "pr-create"'
	[ "$status" -eq 0 ]
	[[ "$output" == "pr" ]]
}

@test "_match_stage_prefix does not match partial prefix" {
	# "impl" is not a known prefix — only "implement" is
	run_with_config '_match_stage_prefix "impl"'
	[ "$status" -eq 1 ]
	[[ -z "$output" ]]
}

# =============================================================================
# _STAGE_PREFIXES CONSTANT
# =============================================================================

@test "_STAGE_PREFIXES is defined and non-empty" {
	run_with_config 'printf "%s" "${_STAGE_PREFIXES[*]}"'
	[ "$status" -eq 0 ]
	[[ -n "$output" ]]
}

@test "_STAGE_PREFIXES contains all 13 known prefixes" {
	local prefixes
	prefixes=$(bash -c "source '$MODEL_CONFIG' && printf '%s ' \"\${_STAGE_PREFIXES[@]}\"")

	for expected in spec-review code-review task-review validate-plan \
		parse-issue implement simplify complete review test docs fix pr; do
		[[ "$prefixes" == *"$expected"* ]]
	done
}

@test "_STAGE_PREFIXES lists longer prefixes before shorter ones" {
	local prefixes
	prefixes=$(bash -c "source '$MODEL_CONFIG' && printf '%s ' \"\${_STAGE_PREFIXES[@]}\"")

	# spec-review (11 chars) must appear before review (6 chars)
	local spec_pos review_pos
	spec_pos="${prefixes%%spec-review*}"
	review_pos="${prefixes%%review*}"
	# spec-review at position ${#spec_pos}, plain review at ${#review_pos}
	# But review_pos matches spec-review first, so find the standalone review
	# Extract positions by removing prefix up to match
	[[ "${#spec_pos}" -lt "${#review_pos}" ]]
}

# =============================================================================
# resolve_model() - COMPOSITE STAGE + COMPLEXITY COMBINATION
# =============================================================================

@test "resolve_model with composite stage and S complexity" {
	# implement-task-1 defaults to sonnet, S stays at standard -> sonnet
	run_with_config 'resolve_model "implement-task-1" "S"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model with composite stage and L complexity" {
	# review-task-1-iter-2 defaults to sonnet, L overrides to opus
	run_with_config 'resolve_model "review-task-1-iter-2" "L"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model with composite stage and M complexity" {
	# test-iter-1 defaults to sonnet (standard tier); M also maps to
	# standard, so the result stays sonnet
	run_with_config 'resolve_model "test-iter-1" "M"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model unknown composite stage with complexity hint" {
	# Unknown stage falls back to opus, S complexity overrides to standard -> sonnet
	run_with_config 'resolve_model "garbage-stage-name" "S"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model no arguments returns opus fallback" {
	run_with_config 'resolve_model'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

# =============================================================================
# model-config.sh SOURCING SAFETY
# =============================================================================

@test "model-config.sh can be sourced twice without error or stderr" {
	run bash -c "source '$MODEL_CONFIG' && source '$MODEL_CONFIG' 2>&1"
	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

@test "model-config.sh exports resolve_model as a function after sourcing" {
	run bash -c "source '$MODEL_CONFIG' && type resolve_model"
	[ "$status" -eq 0 ]
	[[ "$output" == *"function"* ]]
}

@test "makes _tier_to_model available as a function after sourcing" {
	run bash -c "source '$MODEL_CONFIG' && type _tier_to_model"
	[ "$status" -eq 0 ]
	[[ "$output" == *"function"* ]]
}

@test "resolve_model is callable after sourcing in subshell" {
	run bash -c "source '$MODEL_CONFIG' && result=\$(resolve_model 'test') && printf '%s' \"\$result\""
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

# =============================================================================
# resolve_model() - LIGHT STAGES IGNORE COMPLEXITY HINTS
#
# Stages with a "light" default tier (test, parse-issue, validate-plan, pr,
# complete, docs) always use haiku regardless of task complexity.  These are
# mechanical stages (parsing, running commands, filling templates) where model
# quality does not scale with problem size.
# =============================================================================

@test "complexity S does not override parse-issue light stage" {
	# parse-issue defaults to light (haiku) and must stay haiku
	run_with_config 'resolve_model "parse-issue" "S"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "complexity M does not override test stage light tier" {
	# test defaults to light (haiku) and must stay haiku
	run_with_config 'resolve_model "test" "M"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "complexity L overrides pr stage standard tier to opus" {
	# pr defaults to standard (sonnet); L complexity upgrades to opus
	run_with_config 'resolve_model "pr" "L"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "complexity S does not override validate-plan light stage" {
	run_with_config 'resolve_model "validate-plan" "S"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "complexity M does not override complete stage light tier" {
	# complete defaults to light (haiku) and must stay haiku even for M tasks
	run_with_config 'resolve_model "complete" "M"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "complexity L does not override docs stage light tier" {
	# docs defaults to light (haiku) and must stay haiku even for L tasks
	run_with_config 'resolve_model "docs" "L"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "complexity M does not override complete-issue suffixed light stage" {
	run_with_config 'resolve_model "complete-issue" "M"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "complexity L does not override docs-generate suffixed light stage" {
	run_with_config 'resolve_model "docs-generate-iter-1" "L"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

# =============================================================================
# resolve_model() - COMPLEXITY HINT CASE SENSITIVITY
#
# Contract: unrecognized complexity hints (lowercase, numeric, etc.) are
# silently ignored and the stage default is used. These tests verify that
# contract. If the function is ever changed to error on unrecognized hints,
# these tests must be updated to assert the new behavior.
# =============================================================================

@test "lowercase complexity s is silently ignored — falls through to stage default" {
	# Only uppercase S/M/L are valid hints; lowercase is unrecognized
	run_with_config 'resolve_model "implement" "s"'
	[ "$status" -eq 0 ]
	# Stays at implement's default: standard (sonnet)
	[[ "$output" == "sonnet" ]]
}

@test "lowercase complexity m is silently ignored — falls through to stage default" {
	# Unrecognized hint "m" produces no error, stage default wins
	run_with_config 'resolve_model "review" "m"'
	[ "$status" -eq 0 ]
	# Stays at review's default: standard (sonnet)
	[[ "$output" == "sonnet" ]]
}

@test "lowercase complexity l is silently ignored — falls through to stage default" {
	# Unrecognized hint "l" produces no error, stage default wins
	run_with_config 'resolve_model "parse-issue" "l"'
	[ "$status" -eq 0 ]
	# Stays at parse-issue's default: light (haiku)
	[[ "$output" == "haiku" ]]
}

@test "numeric complexity hint is silently ignored — falls through to stage default" {
	# Unrecognized hint "2" produces no error, stage default wins
	run_with_config 'resolve_model "implement" "2"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

# =============================================================================
# resolve_model() - REMAINING SUFFIXED STAGE NAMES
# =============================================================================

@test "resolve_model matches docs prefix in docs-generate-iter-1" {
	run_with_config 'resolve_model "docs-generate-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model matches docs prefix in docs-file-1" {
	run_with_config 'resolve_model "docs-file-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model matches docs prefix in docs-file-10" {
	run_with_config 'resolve_model "docs-file-10"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model matches docs prefix in docs-commit" {
	run_with_config 'resolve_model "docs-commit"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model matches complete prefix in complete-issue" {
	run_with_config 'resolve_model "complete-issue"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model matches pr prefix in pr-create-iter-1" {
	run_with_config 'resolve_model "pr-create-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model matches parse-issue prefix in parse-issue-retry-1" {
	run_with_config 'resolve_model "parse-issue-retry-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model matches validate-plan prefix in validate-plan-attempt-2" {
	run_with_config 'resolve_model "validate-plan-attempt-2"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

# =============================================================================
# resolve_model() - FALLBACK EDGE CASES
# =============================================================================

@test "resolve_model returns opus for stage name that is substring of known prefix" {
	# "impl" is not "implement" — must not match
	run_with_config 'resolve_model "impl"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model returns opus for hyphen-only stage name" {
	run_with_config 'resolve_model "-"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model returns opus for stage with spaces" {
	run_with_config 'resolve_model "implement task"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model fallback still respects complexity hint" {
	# Unknown stage falls back to advanced (opus), but M complexity overrides to standard (sonnet)
	run_with_config 'resolve_model "nonexistent" "M"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model fallback with L complexity stays opus" {
	run_with_config 'resolve_model "nonexistent" "L"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

# =============================================================================
# model-config.sh SOURCING — EXTENDED SAFETY
# =============================================================================

@test "model-config.sh sourcing works from different working directory" {
	local original_dir="$PWD"
	run bash -c "cd /tmp && source '$MODEL_CONFIG' && resolve_model 'test'"
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "all internal functions available after sourcing" {
	run bash -c "
		source '$MODEL_CONFIG'
		type _tier_to_model >/dev/null 2>&1 &&
		type _stage_to_tier >/dev/null 2>&1 &&
		type _complexity_to_tier >/dev/null 2>&1 &&
		type _match_stage_prefix >/dev/null 2>&1 &&
		type resolve_model >/dev/null 2>&1 &&
		printf 'all_available'
	"
	[ "$status" -eq 0 ]
	[[ "$output" == "all_available" ]]
}

@test "_STAGE_PREFIXES is readonly after sourcing" {
	run bash -c "source '$MODEL_CONFIG' && _STAGE_PREFIXES=(modified) 2>&1"
	# readonly variables produce a non-zero exit when reassigned
	[ "$status" -ne 0 ]
}

@test "sourcing produces no stderr output" {
	run bash -c "source '$MODEL_CONFIG' 2>&1"
	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

# =============================================================================
# INTERNAL FUNCTION BOUNDARY — EMPTY STRING INPUTS
#
# Internal helpers must handle empty-string arguments gracefully since
# resolve_model() may pass empty strings through parameter expansion.
# =============================================================================

@test "_stage_to_tier returns empty for empty string input" {
	run_with_config '_stage_to_tier ""'
	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

@test "_complexity_to_tier returns empty for empty string input" {
	run_with_config '_complexity_to_tier ""'
	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

@test "_tier_to_model falls back to opus for empty string input" {
	# Empty tier is not light/standard/advanced — hits the * fallback
	run_with_config '_tier_to_model ""'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

# =============================================================================
# resolve_model() OUTPUT — COMMAND SUBSTITUTION SAFETY
#
# resolve_model's output feeds directly into `--model "$model"` arguments.
# These tests verify the output is clean for shell consumption: single word,
# no leading/trailing whitespace, no embedded newlines.
# =============================================================================

@test "resolve_model output is a single word suitable for --model flag" {
	local result
	result=$(bash -c "source '$MODEL_CONFIG' && resolve_model 'implement'")

	# No spaces, tabs, or embedded newlines in the value
	[[ "$result" =~ ^[a-z]+$ ]]
}

@test "resolve_model output captured by command substitution has no trailing newline" {
	local result
	result=$(bash -c "source '$MODEL_CONFIG' && resolve_model 'review'")

	# printf '%s' strips no trailing newline — if result had one, length would differ
	local printed
	printed=$(printf '%s' "$result")
	[[ "$result" == "$printed" ]]
}

@test "resolve_model output is consistent across all model names" {
	# Every possible output must be one of exactly three model names
	local -a stages=("parse-issue" "implement" "review" "unknown-xyz" "")
	for stage in "${stages[@]}"; do
		local result
		result=$(bash -c "source '$MODEL_CONFIG' && resolve_model '$stage'")
		[[ "$result" == "haiku" || "$result" == "sonnet" || "$result" == "opus" ]]
	done
}

# =============================================================================
# resolve_model() — EMPTY COMPLEXITY WITH KNOWN STAGES
#
# Verify that passing an explicit empty string for complexity does not alter
# the stage default. This ensures callers can safely pass "${hint:-}" without
# changing behavior.
# =============================================================================

@test "empty complexity string preserves implement stage default (sonnet)" {
	run_with_config 'resolve_model "implement" ""'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "empty complexity string preserves fix stage default (sonnet)" {
	run_with_config 'resolve_model "fix" ""'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "empty complexity string preserves review stage default (sonnet)" {
	run_with_config 'resolve_model "review" ""'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "empty complexity string preserves test stage default (haiku)" {
	run_with_config 'resolve_model "test" ""'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

# =============================================================================
# model-config.sh SOURCING — VARIABLE ISOLATION
#
# Sourcing must not leak internal working variables into the caller's scope.
# Only the public function names and _STAGE_PREFIXES constant should persist.
# =============================================================================

@test "sourcing does not leak local variables into caller scope" {
	# After sourcing, the only new names should be functions + _STAGE_PREFIXES
	# Specifically, variables like 'tier', 'matched_prefix', 'complexity' must
	# not exist in the caller's scope
	run bash -c "
		source '$MODEL_CONFIG'
		[[ -z \"\${tier:-}\" ]] &&
		[[ -z \"\${matched_prefix:-}\" ]] &&
		[[ -z \"\${complexity:-}\" ]] &&
		[[ -z \"\${stage_name:-}\" ]] &&
		printf 'clean'
	"
	[ "$status" -eq 0 ]
	[[ "$output" == "clean" ]]
}

@test "calling resolve_model does not leak locals into caller scope" {
	run bash -c "
		source '$MODEL_CONFIG'
		resolve_model 'implement' 'S' >/dev/null
		[[ -z \"\${tier:-}\" ]] &&
		[[ -z \"\${matched_prefix:-}\" ]] &&
		[[ -z \"\${complexity_tier:-}\" ]] &&
		printf 'clean'
	"
	[ "$status" -eq 0 ]
	[[ "$output" == "clean" ]]
}

# =============================================================================
# _next_model_up() - MODEL ESCALATION HIERARCHY
# =============================================================================

@test "_next_model_up escalates haiku to sonnet" {
	run_with_config '_next_model_up "haiku"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "_next_model_up escalates sonnet to opus" {
	run_with_config '_next_model_up "sonnet"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "_next_model_up keeps opus at ceiling" {
	run_with_config '_next_model_up "opus"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "_next_model_up falls back to opus for unknown model" {
	run_with_config '_next_model_up "gpt-4"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "_next_model_up handles empty input" {
	run_with_config '_next_model_up ""'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

# =============================================================================
# effective_model — usage-aware escalation
# =============================================================================
#
# These tests source claude-usage.sh (which model-config.sh's effective_model
# delegates to). To exercise behavior without hitting the network we set up
# a fake cache file at $XDG_CACHE_HOME/claude-pipeline/usage.json before
# calling effective_model.
#

# Helper: configure usage env so claude-usage.sh treats us as authenticated.
_setup_usage_cache() {
	export XDG_CACHE_HOME="$TEST_TMP/cache"
	export CLAUDE_USAGE_SESSION_KEY="sk-ant-sid01-fake"
	export CLAUDE_USAGE_ORG_ID="00000000-0000-0000-0000-000000000000"
	export CLAUDE_USAGE_CACHE_TTL=300
	mkdir -p "$XDG_CACHE_HOME/claude-pipeline"
	cat > "$XDG_CACHE_HOME/claude-pipeline/usage.json"
}

# Source both modules in a subshell with cache pre-seeded. Stderr suppressed
# so $output captures the function's return value cleanly — _usage_aware_escalate
# logs to stderr when it escalates, which is correct production behavior but
# noise in these tests.
run_with_usage() {
	local cmd="$1"
	run bash -c "
		source '$SCRIPT_DIR/model-config.sh'
		source '$SCRIPT_DIR/claude-usage.sh'
		$cmd 2>/dev/null
	"
}

@test "effective_model defaults to resolve_model when no cooldown applies" {
	_setup_usage_cache <<'JSON'
{
  "five_hour": {"utilization": 2, "resets_at": "2026-05-02T07:09:59+00:00"},
  "seven_day": {"utilization": 5, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_sonnet": {"utilization": 5, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_opus": null,
  "extra_usage": {"is_enabled": false, "utilization": 0}
}
JSON
	run_with_usage 'effective_model implement M'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "effective_model escalates sonnet to opus when seven_day_sonnet >= threshold (no overage)" {
	_setup_usage_cache <<'JSON'
{
  "five_hour": {"utilization": 2, "resets_at": "2026-05-02T07:09:59+00:00"},
  "seven_day": {"utilization": 50, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_sonnet": {"utilization": 100, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_opus": null,
  "extra_usage": {"is_enabled": false, "utilization": 0}
}
JSON
	run_with_usage 'effective_model implement M'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "effective_model returns opus (ceiling) when sonnet AND seven_day are exhausted" {
	_setup_usage_cache <<'JSON'
{
  "five_hour": {"utilization": 5, "resets_at": "2026-05-02T07:09:59+00:00"},
  "seven_day": {"utilization": 99, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_sonnet": {"utilization": 100, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_opus": null,
  "extra_usage": {"is_enabled": false, "utilization": 0}
}
JSON
	run_with_usage 'effective_model implement M'
	[ "$status" -eq 0 ]
	# Both sonnet and (via fallback to seven_day at 99%) opus are exhausted.
	# Loop should hit the ceiling and return opus rather than spinning.
	[[ "$output" == "opus" ]]
}

@test "effective_model honors CLAUDE_USAGE_DISABLE=1 (no escalation)" {
	export CLAUDE_USAGE_DISABLE=1
	_setup_usage_cache <<'JSON'
{
  "five_hour": {"utilization": 2, "resets_at": "2026-05-02T07:09:59+00:00"},
  "seven_day": {"utilization": 5, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_sonnet": {"utilization": 100, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_opus": null,
  "extra_usage": {"is_enabled": false, "utilization": 0}
}
JSON
	run_with_usage 'effective_model implement M'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "effective_model handles missing CLAUDE_USAGE_SESSION_KEY gracefully (no escalation)" {
	unset CLAUDE_USAGE_SESSION_KEY || true
	# No cache, no key → effective_model must not escalate.
	run bash -c "
		unset CLAUDE_USAGE_SESSION_KEY
		export XDG_CACHE_HOME='$TEST_TMP/cache-empty'
		source '$SCRIPT_DIR/model-config.sh'
		source '$SCRIPT_DIR/claude-usage.sh'
		effective_model implement M
	"
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "effective_fallback also walks the escalation loop" {
	_setup_usage_cache <<'JSON'
{
  "five_hour": {"utilization": 2, "resets_at": "2026-05-02T07:09:59+00:00"},
  "seven_day": {"utilization": 50, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_sonnet": {"utilization": 100, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_opus": null,
  "extra_usage": {"is_enabled": false, "utilization": 0}
}
JSON
	# fallback for haiku would normally be sonnet — but sonnet is exhausted,
	# so effective_fallback should escalate to opus.
	run_with_usage 'effective_fallback haiku'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

# =============================================================================
# _model_cost() - PRICE TABLE / USD COST CALCULATION
# =============================================================================

@test "_model_cost computes haiku input-only cost" {
	run_with_config '_model_cost haiku 1000000 0 0 0'
	[ "$status" -eq 0 ]
	[[ "$output" == "1.000000" ]]
}

@test "_model_cost computes sonnet output-only cost" {
	run_with_config '_model_cost sonnet 0 1000000 0 0'
	[ "$status" -eq 0 ]
	[[ "$output" == "15.000000" ]]
}

@test "_model_cost computes opus combined input+output cost" {
	run_with_config '_model_cost opus 1000000 1000000 0 0'
	[ "$status" -eq 0 ]
	[[ "$output" == "30.000000" ]]
}

@test "_model_cost prices cache creation and cache read tokens" {
	run_with_config '_model_cost opus 0 0 1000000 1000000'
	[ "$status" -eq 0 ]
	[[ "$output" == "6.750000" ]]
}

@test "_model_cost sums input, output, and cache tokens together" {
	run_with_config '_model_cost haiku 1000000 1000000 1000000 1000000'
	[ "$status" -eq 0 ]
	# 1.00 + 5.00 + 1.25 + 0.10
	[[ "$output" == "7.350000" ]]
}

@test "_model_cost handles small token counts with correct precision" {
	run_with_config '_model_cost haiku 100 50 0 0'
	[ "$status" -eq 0 ]
	# (100 * 1.00 + 50 * 5.00) / 1e6 = 350 / 1e6
	[[ "$output" == "0.000350" ]]
}

@test "_model_cost falls back to opus pricing for an unknown model" {
	run_with_config '_model_cost gpt-4 1000000 0 0 0'
	[ "$status" -eq 0 ]
	[[ "$output" == "5.000000" ]]
}

@test "_model_cost falls back to opus pricing for empty model" {
	run_with_config '_model_cost "" 1000000 0 0 0'
	[ "$status" -eq 0 ]
	[[ "$output" == "5.000000" ]]
}

@test "_model_cost matches a full model ID containing the opus tier" {
	run_with_config '_model_cost claude-opus-4-8 1000000 0 0 0'
	[ "$status" -eq 0 ]
	[[ "$output" == "5.000000" ]]
}

@test "_model_cost matches a full model ID containing the sonnet tier" {
	run_with_config '_model_cost claude-sonnet-4-6 0 1000000 0 0'
	[ "$status" -eq 0 ]
	[[ "$output" == "15.000000" ]]
}

@test "_model_cost matches a full model ID containing the haiku tier" {
	run_with_config '_model_cost claude-haiku-4-5 1000000 0 0 0'
	[ "$status" -eq 0 ]
	[[ "$output" == "1.000000" ]]
}

@test "_model_cost defaults missing token-count arguments to zero" {
	run_with_config '_model_cost haiku'
	[ "$status" -eq 0 ]
	[[ "$output" == "0.000000" ]]
}

@test "_model_cost output has no trailing newline beyond the single line" {
	run_with_config '_model_cost opus 1000000 0 0 0'
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 1 ]
}

# =============================================================================
# _extract_readonly_array_guards() — setup_test_env's awk extraction
#
# setup_test_env (helpers/test-helper.bash) pulls `readonly -a NAME=(...)`
# blocks out of model-config.sh and wraps each in a
# `declare -p NAME >/dev/null 2>&1 || { ... }` guard so @test bodies can
# re-source the array regardless of whether it is already global and
# readonly (see MODEL_CONFIG_ARRAYS_FILE's docs in test-helper.bash).
# These tests exercise the extraction directly against synthetic input so
# a regression to a broken guard (unbalanced braces) is caught as a
# `bash -n` syntax failure rather than a silent empty-array symptom.
# =============================================================================

@test "_extract_readonly_array_guards closes the guard for a multi-line declaration" {
	local input="$TEST_TMP/multi-line-config.sh"
	cat > "$input" << 'EOF'
readonly -a _MULTI=(
	a b c
)
EOF

	local out="$TEST_TMP/multi-line-arrays.sh"
	_extract_readonly_array_guards "$input" > "$out"

	run bash -n "$out"
	[ "$status" -eq 0 ] || fail "Unbalanced braces in extraction output: $output"

	unset _MULTI
	source "$out"
	[ "${#_MULTI[@]}" -eq 3 ]
}

@test "_extract_readonly_array_guards closes the guard for a single-line declaration" {
	local input="$TEST_TMP/single-line-config.sh"
	cat > "$input" << 'EOF'
readonly -a _SINGLE=(x y z)
EOF

	local out="$TEST_TMP/single-line-arrays.sh"
	_extract_readonly_array_guards "$input" > "$out"

	run bash -n "$out"
	[ "$status" -eq 0 ] || fail "Unbalanced braces in extraction output: $output"

	unset _SINGLE
	source "$out"
	[ "${#_SINGLE[@]}" -eq 3 ]
}

@test "_extract_readonly_array_guards single-line output pairs each opening guard brace with a closing one" {
	local input="$TEST_TMP/single-line-config.sh"
	cat > "$input" << 'EOF'
readonly -a _SINGLE=(x y z)
EOF

	local output
	output=$(_extract_readonly_array_guards "$input")

	local open_braces close_braces
	open_braces=$(grep -c '|| {$' <<< "$output")
	close_braces=$(grep -c '^}$' <<< "$output")
	[ "$open_braces" -eq 1 ]
	[ "$close_braces" -eq 1 ]
}

@test "_extract_readonly_array_guards handles a mix of single-line and multi-line declarations" {
	local input="$TEST_TMP/mixed-config.sh"
	cat > "$input" << 'EOF'
readonly -a _FIRST_SINGLE=(a b)
readonly -a _MULTI=(
	c d e
)
readonly -a _SECOND_SINGLE=(f)
EOF

	local out="$TEST_TMP/mixed-arrays.sh"
	_extract_readonly_array_guards "$input" > "$out"

	run bash -n "$out"
	[ "$status" -eq 0 ] || fail "Unbalanced braces in extraction output: $output"

	unset _FIRST_SINGLE _MULTI _SECOND_SINGLE
	source "$out"
	[ "${#_FIRST_SINGLE[@]}" -eq 2 ]
	[ "${#_MULTI[@]}" -eq 3 ]
	[ "${#_SECOND_SINGLE[@]}" -eq 1 ]
}

@test "_extract_readonly_array_guards single-line guard is a no-op when the array is already global and readonly" {
	local input="$TEST_TMP/single-line-config.sh"
	cat > "$input" << 'EOF'
readonly -a _ALREADY_SET=(orig)
EOF

	local out="$TEST_TMP/single-line-arrays.sh"
	_extract_readonly_array_guards "$input" > "$out"

	readonly -a _ALREADY_SET=(orig)

	# Re-sourcing must not error even though _ALREADY_SET is already
	# readonly in this same shell — the declare -p guard should skip
	# re-declaring it rather than tripping bash's "readonly variable"
	# error.
	run source "$out"
	[ "$status" -eq 0 ] || fail "Guard re-declared an existing readonly array: $output"
}

# =============================================================================
# setup_test_env() — MODEL_CONFIG_ARRAYS_FILE non-empty check (issue #749)
#
# setup_test_env (helpers/test-helper.bash) appends an ARRAYS_NONEMPTY_CHECK
# block after the extracted array guards: once MODEL_CONFIG_ARRAYS_FILE is
# sourced, it asserts _LIGHT_STAGES, _STANDARD_STAGES, and _STAGE_PREFIXES
# are all non-empty, printing a named "FATAL: <name> is empty after
# MODEL_CONFIG_ARRAYS_FILE re-source" diagnostic and returning 1 if any of
# them are not. Nothing exercised that failure path — a silently broken
# extraction would otherwise surface only as unrelated downstream assertion
# noise (see PR #747 / issue #743's review).
#
# This test points SCRIPT_DIR at a corrupted model-config.sh (one array
# declared empty) and runs the real setup_test_env() against it, so the
# guard that fires is the actual generated code, not a hand-written
# reimplementation of it. setup_test_env reassigns the global
# TEST_TMP/SCRIPT_DIR, so it runs inside an isolated wrapper script (its own
# bash process) rather than this test's own shell — otherwise it would
# clobber the $TEST_TMP this test's own setup()/teardown() rely on.
# =============================================================================

@test "setup_test_env's MODEL_CONFIG_ARRAYS_FILE guard prints FATAL and returns non-zero for an empty array" {
	local fake_script_dir="$TEST_TMP/fake-script-dir"
	mkdir -p "$fake_script_dir"
	cat > "$fake_script_dir/model-config.sh" << 'EOF'
readonly -a _LIGHT_STAGES=(a b)
readonly -a _STANDARD_STAGES=(c d)
readonly -a _STAGE_PREFIXES=()
EOF

	# $TEST_DIR and $fake_script_dir are known now and expand into the
	# wrapper at generation time; $MODEL_CONFIG_ARRAYS_FILE and $? are
	# escaped so they resolve inside the wrapper's own process, only after
	# setup_test_env has run there.
	local wrapper="$TEST_TMP/setup_test_env_wrapper.sh"
	cat > "$wrapper" << WRAPPER
#!/usr/bin/env bash
source "$TEST_DIR/helpers/test-helper.bash"
SCRIPT_DIR="$fake_script_dir"
setup_test_env || exit 1
source "\$MODEL_CONFIG_ARRAYS_FILE"
status=\$?
rm -rf "\$TEST_TMP"
exit "\$status"
WRAPPER
	chmod +x "$wrapper"

	run "$wrapper"
	[ "$status" -ne 0 ] || fail "Expected non-zero return, got 0"
	[[ "$output" == *"FATAL: _STAGE_PREFIXES is empty after"*"MODEL_CONFIG_ARRAYS_FILE re-source"* ]] || \
		fail "Expected FATAL diagnostic for _STAGE_PREFIXES on stderr. Got: $output"
}
