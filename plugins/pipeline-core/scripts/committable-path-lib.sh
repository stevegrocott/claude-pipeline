#!/usr/bin/env bash
#
# committable-path-lib.sh - Single definition of which paths a pipeline
# commit may touch (issue #928).
#
# Sourced by every gate that must agree on committability, so the intake
# check and the post-commit guard cannot drift apart (issue #909 lost two
# tasks to exactly that drift: `.bash` was accepted at intake and rejected
# by the post-commit guard).
#
# Public API:
#   committable_path_class PATH
#     Prints nothing; classifies PATH through the exit status:
#       0  committable (root-level markdown, tests/, docs/, skills,
#          agents, prisma, docker-compose, or a recognised source
#          extension)
#       1  not committable by default, but overridable by an operator
#          through EXTRA_COMMIT_PATHS
#       2  hard-denied (.github/workflows/**) and never overridable
#   committable_path_is_hard_denied PATH
#     Succeeds only for class 2.
#   committable_path_admitted PATH
#     Succeeds when a commit may touch PATH: class 0, or class 1 matched
#     by a pipe-separated glob in EXTRA_COMMIT_PATHS (whitespace around
#     entries is trimmed). Class 2 is never admitted.
#
# Decision (issue #789 AC4): root-level CLAUDE.md is admitted, not
# denylisted. Markdown cannot execute or alter runtime behaviour the way
# .github/workflows/** can, and the commit is still reviewed on the PR.

# Idempotent source guard.
[[ -n "${_COMMITTABLE_PATH_LIB_SOURCED:-}" ]] && return 0
_COMMITTABLE_PATH_LIB_SOURCED=1

committable_path_class() {
	local path="$1"

	# Root-level docs (no directory separator) are always admitted;
	# nested markdown falls through to the default arm below.
	if [[ "$path" == *.md && "$path" != */* ]]; then
		return 0
	fi

	case "$path" in
		# Hard denylist: not overridable by EXTRA_COMMIT_PATHS.
		.github/workflows/**) return 2 ;;
		tests/*) return 0 ;;
		prisma/** | */prisma/**) return 0 ;;
		docker-compose*.yml) return 0 ;;
		docs/**) return 0 ;;
		.claude/agents/**) return 0 ;;
		.claude/skills/**) return 0 ;;
		plugins/pipeline-core/skills/**) return 0 ;;
		*.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs) return 0 ;;
		# *.bash is a shell source exactly like *.sh (issue #928): the
		# bats helper libraries are .bash files.
		*.sh | *.bash | *.bats | *.py | *.go | *.rb | *.java | *.rs)
			return 0 ;;
		*.c | *.cpp | *.h | *.hpp) return 0 ;;
		# Stylesheets are source, not config (issue #978).
		*.css | *.scss | *.sass | *.less | *.styl) return 0 ;;
	esac
	return 1
}

committable_path_is_hard_denied() {
	local rc=0
	committable_path_class "$1" || rc=$?
	((rc == 2))
}

committable_path_admitted() {
	local path="$1"
	local rc=0 ep
	local -a raw=()

	committable_path_class "$path" || rc=$?
	case "$rc" in
		0) return 0 ;;
		2) return 1 ;;
	esac

	[[ -n "${EXTRA_COMMIT_PATHS:-}" ]] || return 1
	IFS='|' read -ra raw <<< "$EXTRA_COMMIT_PATHS"
	for ep in "${raw[@]}"; do
		ep="${ep#"${ep%%[![:space:]]*}"}"
		ep="${ep%"${ep##*[![:space:]]}"}"
		[[ -n "$ep" ]] || continue
		# shellcheck disable=SC2254
		case "$path" in
			$ep) return 0 ;;
		esac
	done
	return 1
}
