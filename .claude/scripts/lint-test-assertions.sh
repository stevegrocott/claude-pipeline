#!/usr/bin/env bash
#
# lint-test-assertions.sh — Deterministic linter for hollow assertion patterns
#
# Scans test files for three hollow-assertion patterns and emits structured
# JSON findings for use by the pipeline's test-validation stage.
#
# Usage: lint-test-assertions.sh <file1> [<file2> …]
#
# Detects:
#   mock-timing-perf    — performance.now() threshold on a mocked function
#   constant-arithmetic — expect() wraps compile-time constant arithmetic
#   self-referential    — toBe/toEqual compares same property on two objects
#
# Environment:
#   LINT_TEST_ASSERTIONS  Set to 0 to disable; defaults to 1 (enabled)
#
# Output (stdout):
#   JSON array: [{file,line,pattern,snippet,severity}, …]
#   Emits [] when no findings or when the linter is disabled.
#
# Exit codes:
#   0  Success (with or without findings)
#   1  Usage error
#

set -u
set -o pipefail

readonly SCRIPT_NAME="${0##*/}"

_err() {
	printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
}

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME <file1> [<file2> …]

Scan test files for hollow assertion patterns; emit JSON findings.

Patterns:
  mock-timing-perf    performance.now() threshold against a mocked function
  constant-arithmetic expect() argument is compile-time constant arithmetic
  self-referential    toBe/toEqual compares identical property from two objects

Environment:
  LINT_TEST_ASSERTIONS  0 disables the linter (default: 1)
EOF
}

# -----------------------------------------------------------------------
# _ltrim <string>
# Print string with leading whitespace stripped.
# -----------------------------------------------------------------------
_ltrim() {
	local s="$1"
	printf '%s' "${s#"${s%%[![:space:]]*}"}"
}

# -----------------------------------------------------------------------
# _emit_finding <tmpdir> <file> <lineno> <pattern> <snippet> <severity>
# Append one JSON finding object to <tmpdir>/findings.jsonl.
# -----------------------------------------------------------------------
_emit_finding() {
	local tmpdir="$1" file="$2" lineno="$3"
	local pattern="$4" snippet="$5" severity="$6"
	jq -n \
		--arg    file     "$file"     \
		--argjson line    "$lineno"   \
		--arg    pattern  "$pattern"  \
		--arg    snippet  "$snippet"  \
		--arg    severity "$severity" \
		'{file:$file,line:$line,pattern:$pattern,
		  snippet:$snippet,severity:$severity}' \
		>> "$tmpdir/findings.jsonl"
}

# -----------------------------------------------------------------------
# _scan_constant_arithmetic <file> <tmpdir>
# Flag expect(<const_expr>) where the argument is purely numeric literals
# combined with arithmetic operators — no runtime values involved.
# Example: expect(30000/5).toBe(6000)
# Example: expect(413+369.4 < 1024).toBe(true)
# Two-signal: first operand AND operator AND second operand are all numeric.
# -----------------------------------------------------------------------
_scan_constant_arithmetic() {
	local file="$1" tmpdir="$2"
	local rawline lineno snippet

	while IFS= read -r rawline; do
		lineno="${rawline%%:*}"
		snippet="$(_ltrim "${rawline#*:}")"
		_emit_finding "$tmpdir" "$file" "$lineno" \
			"constant-arithmetic" "$snippet" "minor"
	done < <(grep -nE \
		'expect\([[:space:]]*[0-9][0-9.]*[[:space:]]*[-+*/][[:space:]]*[0-9]' \
		"$file" 2>/dev/null)
}

# -----------------------------------------------------------------------
# _scan_self_referential <file> <tmpdir>
# Flag expect(OBJ1.PROP).toBe(OBJ2.PROP) / .toEqual() where PROP is the
# same identifier on both sides — both values share the same source key,
# so the assertion passes even when both are wrong.
# Example: expect(result1.userThreshold).toBe(result2.userThreshold)
# -----------------------------------------------------------------------
_scan_self_referential() {
	local file="$1" tmpdir="$2"
	local rawline lineno snippet prop1 prop2
	# Regex helpers: expect(OBJ.PROP).toBe/toEqual(OBJ2.PROP)
	local ident re_grep re1 re2
	ident='[A-Za-z_][A-Za-z0-9_]*'
	re_grep="expect\(${ident}\.${ident}\)\.to(Be|Equal)\(${ident}\.${ident}\)"
	re1="s/.*expect\(${ident}\.([A-Za-z_][A-Za-z0-9_]*)\).*/\1/"
	re2="s/.*\.to(Be|Equal)\(${ident}\.([A-Za-z_][A-Za-z0-9_]*)\).*/\2/"

	while IFS= read -r rawline; do
		lineno="${rawline%%:*}"
		snippet="$(_ltrim "${rawline#*:}")"

		# Extract property name from expect(OBJ.PROP)
		prop1=$(printf '%s' "$snippet" | sed -E "$re1")

		# Extract property from .toBe(OBJ.PROP) or .toEqual(OBJ.PROP)
		prop2=$(printf '%s' "$snippet" | sed -E "$re2")

		# Guard: both extractions must look like valid identifiers
		if [[ "$prop1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && \
		   [[ "$prop2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && \
		   [[ "$prop1" == "$prop2" ]]; then
			_emit_finding "$tmpdir" "$file" "$lineno" \
				"self-referential" "$snippet" "minor"
		fi
	done < <(grep -nE "$re_grep" "$file" 2>/dev/null)
}

# -----------------------------------------------------------------------
# _scan_mock_timing_perf <file> <tmpdir>
# Flag performance.now() timing assertions against mocked functions.
# Three-signal gate (reduces false positives):
#   1. File contains jest.mock() or vi.mock()
#   2. Line contains performance.now()
#   3. toBeLessThan[OrEqual]( appears within ±10 lines of signal 2
# Example: const t=performance.now(); await mockedFn();
#          expect(performance.now()-t).toBeLessThan(200)
# -----------------------------------------------------------------------
_scan_mock_timing_perf() {
	local file="$1" tmpdir="$2"
	local window=10

	# Signal 1: skip files with no mock declarations
	grep -qE '(jest|vi)\.mock\(' "$file" 2>/dev/null || return 0

	local rawline lineno snippet start end
	while IFS= read -r rawline; do
		lineno="${rawline%%:*}"
		snippet="$(_ltrim "${rawline#*:}")"

		start=$(( lineno - window < 1 ? 1 : lineno - window ))
		end=$(( lineno + window ))

		# Signal 3: toBeLessThan[OrEqual] within the window
		if sed -n "${start},${end}p" "$file" 2>/dev/null | \
			grep -qE 'toBeLessThan(OrEqual)?\('; then
			_emit_finding "$tmpdir" "$file" "$lineno" \
				"mock-timing-perf" "$snippet" "minor"
		fi
	done < <(grep -nE 'performance\.now\(\)' "$file" 2>/dev/null)
}

# -----------------------------------------------------------------------
# main
# -----------------------------------------------------------------------
main() {
	if [[ $# -eq 0 ]]; then
		usage >&2
		exit 1
	fi

	# Env-var disable gate
	if [[ "${LINT_TEST_ASSERTIONS:-1}" == "0" ]]; then
		printf '[]\n'
		return 0
	fi

	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '${tmpdir}'" EXIT

	touch "$tmpdir/findings.jsonl"

	local file
	for file in "$@"; do
		if [[ ! -f "$file" ]]; then
			_err "file not found: $file"
			continue
		fi

		_scan_constant_arithmetic "$file" "$tmpdir"
		_scan_self_referential    "$file" "$tmpdir"
		_scan_mock_timing_perf    "$file" "$tmpdir"
	done

	if [[ ! -s "$tmpdir/findings.jsonl" ]]; then
		printf '[]\n'
		return 0
	fi

	jq -s '.' "$tmpdir/findings.jsonl"
}

main "$@"
