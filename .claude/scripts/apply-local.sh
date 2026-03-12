#!/usr/bin/env bash
# apply-local.sh — Copy local customizations over generic pipeline defaults
#
# Usage: .claude/scripts/apply-local.sh [--dry-run]
#
# Copies files from .claude/local/ over their counterparts in .claude/
# This allows local customizations to survive upstream pipeline syncs:
#   1. Pull upstream changes (updates generic defaults)
#   2. Run apply-local.sh (re-applies your customizations on top)
#
# The .claude/local/ directory mirrors the .claude/ structure:
#   .claude/local/agents/backend-developer.md  →  .claude/agents/backend-developer.md
#   .claude/local/skills/my-skill/SKILL.md     →  .claude/skills/my-skill/SKILL.md
#   .claude/local/config/platform.sh           →  .claude/config/platform.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCAL_DIR="${CLAUDE_DIR}/local"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

if [[ ! -d "$LOCAL_DIR" ]]; then
    echo "No .claude/local/ directory found. Nothing to apply."
    echo "Run /adapting-claude-pipeline to create local customizations."
    exit 0
fi

copied=0
skipped=0

while IFS= read -r -d '' local_file; do
    # Compute relative path within local/
    rel_path="${local_file#"${LOCAL_DIR}/"}"
    target="${CLAUDE_DIR}/${rel_path}"

    # Ensure target directory exists
    target_dir="$(dirname "$target")"

    if $DRY_RUN; then
        echo "[dry-run] Would copy: local/${rel_path} → ${rel_path}"
        ((copied++))
    else
        mkdir -p "$target_dir"
        cp "$local_file" "$target"
        echo "Applied: local/${rel_path} → ${rel_path}"
        ((copied++))
    fi
done < <(find "$LOCAL_DIR" -type f -print0)

if $DRY_RUN; then
    echo ""
    echo "Dry run complete. ${copied} file(s) would be applied."
else
    echo ""
    echo "Applied ${copied} local customization(s)."
fi
