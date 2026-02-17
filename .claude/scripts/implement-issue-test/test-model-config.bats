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

@test "stage implement maps to advanced" {
	run_with_config '_stage_to_tier "implement"'
	[ "$status" -eq 0 ]
	[[ "$output" == "advanced" ]]
}

@test "stage task-review maps to standard" {
	run_with_config '_stage_to_tier "task-review"'
	[ "$status" -eq 0 ]
	[[ "$output" == "standard" ]]
}

@test "stage fix maps to advanced" {
	run_with_config '_stage_to_tier "fix"'
	[ "$status" -eq 0 ]
	[[ "$output" == "advanced" ]]
}

@test "stage test maps to light" {
	run_with_config '_stage_to_tier "test"'
	[ "$status" -eq 0 ]
	[[ "$output" == "light" ]]
}

@test "stage review maps to standard" {
	run_with_config '_stage_to_tier "review"'
	[ "$status" -eq 0 ]
	[[ "$output" == "standard" ]]
}

@test "stage simplify maps to standard" {
	run_with_config '_stage_to_tier "simplify"'
	[ "$status" -eq 0 ]
	[[ "$output" == "standard" ]]
}

@test "stage pr maps to light" {
	run_with_config '_stage_to_tier "pr"'
	[ "$status" -eq 0 ]
	[[ "$output" == "light" ]]
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

@test "complexity M maps to advanced" {
	run_with_config '_complexity_to_tier "M"'
	[ "$status" -eq 0 ]
	[[ "$output" == "advanced" ]]
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

@test "resolve_model returns opus for implement stage" {
	run_with_config 'resolve_model "implement"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model returns haiku for test stage" {
	run_with_config 'resolve_model "test"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model returns haiku for pr stage" {
	run_with_config 'resolve_model "pr"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
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

@test "resolve_model returns opus for fix stage" {
	run_with_config 'resolve_model "fix"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model returns sonnet for simplify stage" {
	run_with_config 'resolve_model "simplify"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
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

@test "resolve_model with M complexity returns opus for implement stage" {
	run_with_config 'resolve_model "implement" "M"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model with L complexity returns opus for implement stage" {
	run_with_config 'resolve_model "implement" "L"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "complexity hint overrides stage default when provided" {
	# fix stage defaults to advanced (opus)
	# S complexity maps to standard (sonnet)
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

@test "complexity hint upgrades task-review from standard to advanced with M" {
	run_with_config 'resolve_model "task-review" "M"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

# =============================================================================
# resolve_model() - STAGE NAME PREFIX MATCHING
# =============================================================================

@test "resolve_model matches implement prefix in implement-task-1" {
	run_with_config 'resolve_model "implement-task-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model matches review prefix in review-task-1-iter-2" {
	run_with_config 'resolve_model "review-task-1-iter-2"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model matches test prefix in test-loop-iter-1" {
	run_with_config 'resolve_model "test-loop-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
}

@test "resolve_model matches fix prefix in fix-review-task-1-iter-1" {
	run_with_config 'resolve_model "fix-review-task-1-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model matches simplify prefix in simplify-task-1-iter-1" {
	run_with_config 'resolve_model "simplify-task-1-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
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
	[[ "$output" == "opus" ]]
}

@test "resolve_model matches fix prefix in fix-task-1-attempt-1" {
	run_with_config 'resolve_model "fix-task-1-attempt-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model matches fix prefix in fix-pr-review-iter-1" {
	run_with_config 'resolve_model "fix-pr-review-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model matches fix prefix in fix-test-quality-iter-1" {
	run_with_config 'resolve_model "fix-test-quality-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model matches task-review prefix in task-review-1-attempt-1" {
	run_with_config 'resolve_model "task-review-1-attempt-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "resolve_model matches test prefix in test-validate-iter-1" {
	run_with_config 'resolve_model "test-validate-iter-1"'
	[ "$status" -eq 0 ]
	[[ "$output" == "haiku" ]]
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
	# implement-task-1 defaults to opus, S overrides to sonnet
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
	# test-loop-iter-1 defaults to haiku, M overrides to opus
	run_with_config 'resolve_model "test-loop-iter-1" "M"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "resolve_model unknown composite stage with complexity hint" {
	# Unknown stage falls back to opus, S complexity overrides to sonnet
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
# resolve_model() - COMPLEXITY HINT UPGRADES LIGHT STAGES
# =============================================================================

@test "complexity S upgrades parse-issue from light to standard" {
	# parse-issue defaults to light (haiku)
	# S complexity maps to standard (sonnet) — upgrades the stage
	run_with_config 'resolve_model "parse-issue" "S"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
}

@test "complexity M upgrades test stage from light to advanced" {
	# test defaults to light (haiku)
	# M complexity maps to advanced (opus) — significant upgrade
	run_with_config 'resolve_model "test" "M"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "complexity L upgrades pr stage from light to advanced" {
	# pr defaults to light (haiku)
	# L complexity maps to advanced (opus)
	run_with_config 'resolve_model "pr" "L"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "complexity S upgrades validate-plan from light to standard" {
	run_with_config 'resolve_model "validate-plan" "S"'
	[ "$status" -eq 0 ]
	[[ "$output" == "sonnet" ]]
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
	# Stays at implement's default: advanced (opus)
	[[ "$output" == "opus" ]]
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
	[[ "$output" == "opus" ]]
}

# =============================================================================
# resolve_model() - REMAINING SUFFIXED STAGE NAMES
# =============================================================================

@test "resolve_model matches docs prefix in docs-generate-iter-1" {
	run_with_config 'resolve_model "docs-generate-iter-1"'
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
	[[ "$output" == "haiku" ]]
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
	# Unknown stage falls back to opus, but M complexity also maps to advanced
	# Net result: opus (both paths agree)
	run_with_config 'resolve_model "nonexistent" "M"'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
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

@test "empty complexity string preserves implement stage default (opus)" {
	run_with_config 'resolve_model "implement" ""'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
}

@test "empty complexity string preserves fix stage default (opus)" {
	run_with_config 'resolve_model "fix" ""'
	[ "$status" -eq 0 ]
	[[ "$output" == "opus" ]]
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
