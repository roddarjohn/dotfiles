#!/usr/bin/env bash
# Regenerate the Claude Code stow package (claude/.claude/) from the pi harness
# config (pi/.pi/agent/). pi is the single source of truth; everything under
# claude/.claude/ is generated and should never be hand-edited.
#
# What it converts:
#   pi/.pi/agent/AGENTS.md        -> claude/.claude/CLAUDE.md   (global user memory)
#   pi/.pi/agent/skills/<name>/   -> claude/.claude/skills/<name>/
#
# pi and Claude Code both use the agentskills.io SKILL.md format, so skills copy
# across verbatim. (Claude Code requires each skill's frontmatter `name:` to match
# its directory name — keep the pi source that way and no transform is needed.)
#
# Usage: scripts/sync-claude-from-pi.sh  (run from anywhere; --check to verify only)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    :
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
SRC="$REPO_ROOT/pi/.pi/agent"
DEST="$REPO_ROOT/claude/.claude"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

if [ ! -d "$SRC" ]; then
    echo "✗ pi source not found: $SRC" >&2
    exit 1
fi

# When only checking, build into a scratch dir and diff against the committed
# tree so we can fail fast (used by the pre-commit hook / CI).
if [ "$CHECK_ONLY" -eq 1 ]; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    OUT="$WORK/.claude"
else
    OUT="$DEST"
fi

GEN_NOTE="GENERATED from pi/.pi/agent by scripts/sync-claude-from-pi.sh — do not edit."

# ── AGENTS.md -> CLAUDE.md ───────────────────────────────────────────────────
mkdir -p "$OUT"
if [ -f "$SRC/AGENTS.md" ]; then
    {
        printf '<!-- %s -->\n\n' "$GEN_NOTE"
        cat "$SRC/AGENTS.md"
    } >"$OUT/CLAUDE.md"
else
    echo "  • no AGENTS.md; skipping CLAUDE.md" >&2
fi

# ── skills/ ──────────────────────────────────────────────────────────────────
rm -rf "$OUT/skills"
mkdir -p "$OUT/skills"

if [ -d "$SRC/skills" ]; then
    for skill_dir in "$SRC/skills"/*/; do
        [ -d "$skill_dir" ] || continue
        name="$(basename "$skill_dir")"
        target="$OUT/skills/$name"
        # Copy the whole skill tree, dropping editor/runtime cruft.
        rsync -a \
            --exclude='*~' \
            --exclude='.gitkeep' \
            --exclude='node_modules/' \
            --exclude='__pycache__/' \
            --exclude='.venv/' \
            "$skill_dir" "$target/"

        if [ ! -f "$target/SKILL.md" ]; then
            echo "  • $name: no SKILL.md, skipping" >&2
            rm -rf "$target"
            continue
        fi
        echo "  ✓ skill: $name"
    done
fi

# ── check mode: diff scratch build vs committed tree ─────────────────────────
if [ "$CHECK_ONLY" -eq 1 ]; then
    if ! diff -r "$OUT" "$DEST" >/dev/null 2>&1; then
        echo "✗ claude/.claude is stale; run: scripts/sync-claude-from-pi.sh" >&2
        exit 1
    fi
    echo "✓ claude/.claude is up to date"
fi
