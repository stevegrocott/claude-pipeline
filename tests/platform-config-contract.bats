#!/usr/bin/env bats
#
# tests/platform-config-contract.bats
# Guards the contract between the orchestrator and `.claude/config/platform.sh`
# (issue #894).
#
# platform.sh is CONSUMER-OWNED and seeded once (sync.sh:7), never updated
# afterwards, while the orchestrator ships with the plugin and is replaced on
# every upgrade. So an orchestrator change that reads a NEW platform.sh variable
# breaks exactly the consumers who adopted earliest — on their machine, not in
# this repo (#886: `CLAUDE_CLI: unbound variable`, 0/N tasks).
#
# Crash rule (this file): every platform.sh variable the orchestrator reads
# bare (`$VAR` / `${VAR}`, no `:-` default) must be (a) defaulted at the
# orchestrator level, (b) protected by an EARLIER `-n` / `-z` / `-v` test of the
# same variable, or (c) on the REQUIRED_VARS list below.
#
# (b) is deliberately file-ordered, not function-scoped: the orchestrator gates
# a stage in one function (`should_run_deploy_verify` returns early on
# `-z "$DEPLOY_VERIFY_CMD"`) and reads the variable bare in helpers that only
# run after that gate (`_select_deploy_cmd`). A per-function rule would flag
# those. The cost is that a guard in an unrelated earlier function also clears
# later reads — an accepted approximation; reads BEFORE any guard are caught.
#
# Silent-disable rule: a platform.sh variable with a NON-EMPTY template default
# must be mirrored in the orchestrator — a top-level `VAR="${VAR:-x}"`, or only
# inline non-empty defaults at each read. An empty fallback (bare read, `${V:-}`,
# `-n`/`-z` guard) turns the feature off for consumers whose seeded platform.sh
# predates the variable.
#
# The check is an awk scan rather than a line-number list on purpose: the
# orchestrator grows constantly, so enumerated sites drift on the next edit.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
PLATFORM_SH="$REPO_ROOT/.claude/config/platform.sh"
ORCHESTRATOR="$REPO_ROOT/.claude/scripts/implement-issue-orchestrator.sh"

# Variables the orchestrator may read bare because a run is meaningless without
# them. Format: "NAME|why it is required". Keep this list short — "required" is
# a recorded decision, not a way to silence the guard.
# Empty today: no platform.sh variable is currently read bare without a default
# or guard. Add an entry only as a deliberate decision.
REQUIRED_VARS=()

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
}

teardown() {
	[[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
	return 0
}

# platform_vars FILE — names assigned in a platform.sh, one per line.
# Matches assignments at line start, indented (`    CLAUDE_CLI=` inside an
# `if`), and after `&&` / `||` (`[[ ... ]] && X=true || X=false`). Comment lines
# are dropped first; `${VAR:-}` expansions never match because no `=` follows
# the name.
platform_vars() {
	grep -vE '^[[:space:]]*#' "$1" \
		| grep -oE '(^|[[:space:];&|])(export[[:space:]]+)?[A-Z][A-Z0-9_]*=' \
		| sed -E 's/^[^A-Z]*(export[[:space:]]+)?//; s/=$//' \
		| sort -u
}

# required_names — REQUIRED_VARS names, one per line.
required_names() {
	local entry
	for entry in "${REQUIRED_VARS[@]}"; do
		printf '%s\n' "${entry%%|*}"
	done
}

# unguarded_reads ORCHESTRATOR VARS_FILE REQUIRED_FILE
# Prints "NAME:LINE" for each bare read that is not defaulted, not preceded by
# an -n/-z/-v guard in the same function, and not required.
unguarded_reads() {
	awk -v varsfile="$2" -v reqfile="$3" '
		BEGIN {
			while ((getline v < varsfile) > 0) vars[v] = 1
			while ((getline v < reqfile) > 0) req[v] = 1
		}
		function boundary(v) { return v "([^A-Za-z0-9_]|$)" }
		# Pass 1: orchestrator-level defaults — VAR="${VAR:-x}", VAR="${VAR-x}",
		# or : "${VAR:=x}".
		FNR == NR {
			for (v in vars)
				if ($0 ~ ("(^|[^A-Za-z0-9_])" v "=\"?\\$\\{" v ":?-") ||
				    $0 ~ (":[[:space:]]+\"?\\$\\{" v ":?="))
					defaulted[v] = 1
			next
		}
		# Pass 2: bare reads.
		/^[[:space:]]*#/ { next }
		{
			line = $0
			for (v in vars) {
				# Guard tests read the variable by definition — record the guard,
				# then blank it so it is not counted as a bare read.
				g1 = "-[nz][[:space:]]+\"?\\$\\{?" boundary(v)
				g2 = "-v[[:space:]]+" boundary(v)
				if (line ~ g1) { guarded[v] = 1; gsub(g1, " ", line) }
				if (line ~ g2) { guarded[v] = 1; gsub(g2, " ", line) }
				# Defaulted / alternate-value expansions are not bare.
				gsub("\\$\\{" v ":?[-=+?]", " ", line)
				if (line ~ ("\\$\\{?" boundary(v)) && !(v in guarded) &&
				    !(v in defaulted) && !(v in req))
					print v ":" FNR
			}
		}
	' "$1" "$1"
}

# run_crash_rule ORCHESTRATOR PLATFORM — sets $output/$status via bats `run`.
run_crash_rule() {
	platform_vars "$2" >"$TEST_TMP/vars"
	required_names >"$TEST_TMP/required"
	run unguarded_reads "$1" "$TEST_TMP/vars" "$TEST_TMP/required"
}

# nonempty_default_vars FILE — names whose template default is non-empty
# (`VAR="${VAR:-x}"`, `VAR="${VAR-x}"`), one per line.
nonempty_default_vars() {
	grep -vE '^[[:space:]]*#' "$1" \
		| grep -oE '(^|[[:space:];&|])[A-Z][A-Z0-9_]*="?\$\{[A-Z][A-Z0-9_]*:?-[^}"]' \
		| sed -E 's/^[^A-Z]*//; s/=.*//' \
		| sort -u
}

# silent_disables ORCHESTRATOR NONEMPTY_VARS_FILE
# A consumer platform.sh seeded before a variable existed leaves it unset. If the
# template default is non-empty (e.g. AUTO_MERGE-style "on" switches), an
# orchestrator read that falls back to empty — bare, `${V:-}`, or an -n/-z/-v
# test — silently disables the feature for those consumers. Prints "NAME:LINE"
# for each such read when the orchestrator has no top-level non-empty default.
silent_disables() {
	awk -v varsfile="$2" '
		BEGIN { while ((getline v < varsfile) > 0) vars[v] = 1 }
		FNR == NR {
			for (v in vars)
				if ($0 ~ ("(^|[^A-Za-z0-9_])" v "=\"?\\$\\{" v ":?-[^}]"))
					mirrored[v] = 1
			next
		}
		/^[[:space:]]*#/ { next }
		{
			for (v in vars) {
				if (v in mirrored) continue
				b = "(^|[^A-Za-z0-9_])"
				e = "([^A-Za-z0-9_]|$)"
				if ($0 ~ ("\\$\\{" v ":?-\\}") ||
				    $0 ~ ("-[nzv][[:space:]]+\"?(\\$\\{?)?" v e) ||
				    $0 ~ ("\\$" v e) || $0 ~ ("\\$\\{" v "\\}"))
					print v ":" FNR
			}
		}
	' "$1" "$1"
}

# run_silent_disable ORCHESTRATOR PLATFORM — sets $output/$status via bats `run`.
run_silent_disable() {
	nonempty_default_vars "$2" >"$TEST_TMP/nonempty"
	run silent_disables "$1" "$TEST_TMP/nonempty"
}

# ---------------------------------------------------------------------------
# Parser (AC3)
# ---------------------------------------------------------------------------

@test "platform_vars: finds plain, indented and && || conditional assignments" {
	run platform_vars "$PLATFORM_SH"
	[ "$status" -eq 0 ]
	grep -qx 'TRACKER' <<<"$output"
	grep -qx 'CLAUDE_CLI' <<<"$output"
	grep -qx 'E2E_TDD_ENABLED' <<<"$output"
}

@test "platform_vars: finds every variable the template assigns" {
	run platform_vars "$PLATFORM_SH"
	[ "$status" -eq 0 ]
	[ "$(wc -l <<<"$output")" -ge 41 ]
}

# ---------------------------------------------------------------------------
# Crash rule (AC1, AC2, AC4, AC5, AC7)
# ---------------------------------------------------------------------------

@test "crash rule: passes on the real orchestrator (AC5, AC7)" {
	run_crash_rule "$ORCHESTRATOR" "$PLATFORM_SH"
	[ "$status" -eq 0 ]
	[ -z "$output" ] || {
		echo "unguarded platform.sh reads: $output" >&2
		return 1
	}
}

@test "crash rule: removing CLAUDE_CLI's orchestrator default fails the guard (AC2)" {
	grep -qE '^CLAUDE_CLI="\$\{CLAUDE_CLI:-' "$ORCHESTRATOR"
	sed -E '/^CLAUDE_CLI="\$\{CLAUDE_CLI:-/d' "$ORCHESTRATOR" >"$TEST_TMP/orch.sh"
	run_crash_rule "$TEST_TMP/orch.sh" "$PLATFORM_SH"
	grep -q '^CLAUDE_CLI:' <<<"$output"
}

@test "crash rule: flags a bare read of a variable with no default (AC1)" {
	printf 'NEW_VAR="${NEW_VAR:-x}"\nOTHER=1\n' >"$TEST_TMP/platform.sh"
	printf 'main() {\n  echo "$NEW_VAR"\n}\n' >"$TEST_TMP/orch.sh"
	run_crash_rule "$TEST_TMP/orch.sh" "$TEST_TMP/platform.sh"
	[ "$output" = "NEW_VAR:2" ]
}

@test "crash rule: an orchestrator-level default clears the variable" {
	printf 'NEW_VAR="${NEW_VAR:-x}"\n' >"$TEST_TMP/platform.sh"
	printf 'NEW_VAR="${NEW_VAR:-x}"\nmain() {\n  echo "$NEW_VAR"\n}\n' >"$TEST_TMP/orch.sh"
	run_crash_rule "$TEST_TMP/orch.sh" "$TEST_TMP/platform.sh"
	[ -z "$output" ]
}

@test "crash rule: an inline :- default is not a bare read" {
	printf 'NEW_VAR="${NEW_VAR:-x}"\n' >"$TEST_TMP/platform.sh"
	printf 'main() {\n  echo "${NEW_VAR:-y}" "${NEW_VAR-z}"\n}\n' >"$TEST_TMP/orch.sh"
	run_crash_rule "$TEST_TMP/orch.sh" "$TEST_TMP/platform.sh"
	[ -z "$output" ]
}

@test "crash rule: an earlier -n/-z guard protects bare reads (AC7)" {
	printf 'A_VAR="${A_VAR:-}"\nB_VAR="${B_VAR:-}"\nC_VAR="${C_VAR:-}"\n' >"$TEST_TMP/platform.sh"
	cat >"$TEST_TMP/orch.sh" <<'ORCH'
f() {
  [[ -z "${A_VAR-}" ]] && return 0
  echo "$A_VAR"
  if [[ -n "$B_VAR" ]]; then
    echo "${B_VAR}"
  fi
  [[ -n "${C_VAR:-}" && -f "$C_VAR" ]] || return 0
}
ORCH
	run_crash_rule "$TEST_TMP/orch.sh" "$TEST_TMP/platform.sh"
	[ -z "$output" ]
}

@test "crash rule: a guard in an earlier gating function protects later helpers" {
	printf 'A_VAR="${A_VAR:-}"\n' >"$TEST_TMP/platform.sh"
	cat >"$TEST_TMP/orch.sh" <<'ORCH'
f() {
  [[ -n "${A_VAR:-}" ]] || return 0
  echo "$A_VAR"
}
g() {
  echo "$A_VAR"
}
ORCH
	run_crash_rule "$TEST_TMP/orch.sh" "$TEST_TMP/platform.sh"
	[ -z "$output" ]
}

@test "crash rule: a read before its guard is still flagged" {
	printf 'A_VAR="${A_VAR:-}"\n' >"$TEST_TMP/platform.sh"
	cat >"$TEST_TMP/orch.sh" <<'ORCH'
f() {
  echo "$A_VAR"
  [[ -n "${A_VAR:-}" ]] || return 0
}
ORCH
	run_crash_rule "$TEST_TMP/orch.sh" "$TEST_TMP/platform.sh"
	[ "$output" = "A_VAR:2" ]
}

@test "crash rule: indented and conditional assignments are tracked (AC3)" {
	cat >"$TEST_TMP/platform.sh" <<'PLAT'
if [[ -x "$HOME/x" ]]; then
    IND_VAR="$HOME/x"
fi
[[ -n "${Z:-}" ]] && COND_VAR=true || COND_VAR=false
PLAT
	printf 'main() {\n  echo "$IND_VAR" "$COND_VAR"\n}\n' >"$TEST_TMP/orch.sh"
	run_crash_rule "$TEST_TMP/orch.sh" "$TEST_TMP/platform.sh"
	grep -q '^IND_VAR:2$' <<<"$output"
	grep -q '^COND_VAR:2$' <<<"$output"
}

@test "crash rule: REQUIRED_VARS entries are not flagged and each names a reason (AC4)" {
	printf 'REQ_VAR="${REQ_VAR:-}"\n' >"$TEST_TMP/platform.sh"
	printf 'main() {\n  echo "$REQ_VAR"\n}\n' >"$TEST_TMP/orch.sh"
	REQUIRED_VARS=("REQ_VAR|the run is meaningless without it")
	run_crash_rule "$TEST_TMP/orch.sh" "$TEST_TMP/platform.sh"
	[ -z "$output" ]

}

@test "REQUIRED_VARS: every entry names its variable and a reason (AC4)" {
	local entry
	for entry in ${REQUIRED_VARS[@]+"${REQUIRED_VARS[@]}"}; do
		[[ "$entry" =~ ^[A-Z][A-Z0-9_]*\|.+ ]]
	done
}

# ---------------------------------------------------------------------------
# Silent-disable rule
# ---------------------------------------------------------------------------

@test "silent-disable: passes on the real orchestrator" {
	run_silent_disable "$ORCHESTRATOR" "$PLATFORM_SH"
	[ "$status" -eq 0 ]
	[ -z "$output" ] || {
		echo "non-empty platform.sh defaults not mirrored: $output" >&2
		return 1
	}
}

@test "silent-disable: nonempty_default_vars finds non-empty defaults only" {
	printf 'ON_VAR="${ON_VAR:-1}"  # c\nEMPTY_VAR="${EMPTY_VAR:-}"\n' >"$TEST_TMP/platform.sh"
	run nonempty_default_vars "$TEST_TMP/platform.sh"
	[ "$output" = "ON_VAR" ]
}

@test "silent-disable: flags an empty-fallback read with no mirrored default" {
	printf 'ON_VAR="${ON_VAR:-1}"\n' >"$TEST_TMP/platform.sh"
	printf 'f() {\n  [[ "${ON_VAR:-}" == 1 ]]\n}\n' >"$TEST_TMP/orch.sh"
	run_silent_disable "$TEST_TMP/orch.sh" "$TEST_TMP/platform.sh"
	[ "$output" = "ON_VAR:2" ]
}

@test "silent-disable: flags a -n guard with no mirrored default" {
	printf 'ON_VAR="${ON_VAR:-1}"\n' >"$TEST_TMP/platform.sh"
	printf 'f() {\n  [[ -n "$ON_VAR" ]]\n}\n' >"$TEST_TMP/orch.sh"
	run_silent_disable "$TEST_TMP/orch.sh" "$TEST_TMP/platform.sh"
	[ "$output" = "ON_VAR:2" ]
}

@test "silent-disable: a top-level non-empty default clears it" {
	printf 'ON_VAR="${ON_VAR:-1}"\n' >"$TEST_TMP/platform.sh"
	printf 'ON_VAR="${ON_VAR:-1}"\nf() {\n  [[ -n "$ON_VAR" ]]\n}\n' >"$TEST_TMP/orch.sh"
	run_silent_disable "$TEST_TMP/orch.sh" "$TEST_TMP/platform.sh"
	[ -z "$output" ]
}

@test "silent-disable: an inline non-empty default is fine" {
	printf 'ON_VAR="${ON_VAR:-1}"\n' >"$TEST_TMP/platform.sh"
	printf 'f() {\n  [[ "${ON_VAR:-1}" == 1 ]]\n}\n' >"$TEST_TMP/orch.sh"
	run_silent_disable "$TEST_TMP/orch.sh" "$TEST_TMP/platform.sh"
	[ -z "$output" ]
}

@test "silent-disable: variables with an empty template default are ignored" {
	printf 'EMPTY_VAR="${EMPTY_VAR:-}"\n' >"$TEST_TMP/platform.sh"
	printf 'f() {\n  [[ -n "${EMPTY_VAR:-}" ]]\n}\n' >"$TEST_TMP/orch.sh"
	run_silent_disable "$TEST_TMP/orch.sh" "$TEST_TMP/platform.sh"
	[ -z "$output" ]
}
