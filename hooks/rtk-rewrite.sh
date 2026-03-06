#!/usr/bin/env bash
# rtk-hook-version: 2
# RTK Claude Code hook — rewrites commands to use rtk for token savings.
# Requires: rtk >= 0.23.0, jq
#
# This is a thin delegating hook: all rewrite logic lives in `rtk rewrite`,
# which is the single source of truth (src/discover/registry.rs).
# To add or change rewrite rules, edit the Rust registry — not this file.

if ! command -v jq &>/dev/null; then
  exit 0
fi

if ! command -v rtk &>/dev/null; then
  exit 0
fi

# Version guard: rtk rewrite was added in 0.23.0.
# Older binaries: warn once and exit cleanly (no silent failure).
RTK_VERSION=$(rtk --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -n "$RTK_VERSION" ]; then
  MAJOR=$(echo "$RTK_VERSION" | cut -d. -f1)
  MINOR=$(echo "$RTK_VERSION" | cut -d. -f2)
  # Require >= 0.23.0
  if [ "$MAJOR" -eq 0 ] && [ "$MINOR" -lt 23 ]; then
    echo "[rtk] WARNING: rtk $RTK_VERSION is too old (need >= 0.23.0). Upgrade: cargo install rtk" >&2
    exit 0
  fi
fi

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$CMD" ]; then
  exit 0
fi

# Normalize path-prefixed commands for matching only.
# Claude Code often invokes tools via venv or full path, e.g.
# ".venv/bin/pytest -v" or "/usr/local/bin/ruff check .".
# Strip the directory prefix from the first word so rtk rewrite
# can match the bare command name.
FIRST_WORD="${CMD%% *}"
BASE_CMD="$(basename "$FIRST_WORD")"
if [ "$FIRST_WORD" != "$BASE_CMD" ]; then
  NORM_CMD="${BASE_CMD}${CMD#"$FIRST_WORD"}"
else
  NORM_CMD="$CMD"
fi

# Delegate all rewrite logic to the Rust binary.
# rtk rewrite exits 1 when there's no rewrite — hook passes through silently.
REWRITTEN=$(rtk rewrite "$NORM_CMD" 2>/dev/null) || exit 0

# If the original command had a path prefix and the rewrite simply
# prepended "rtk ", rebuild using the original path so the correct
# binary (e.g. .venv/bin/pytest) is invoked at runtime.
if [ "$FIRST_WORD" != "$BASE_CMD" ] && [ "$REWRITTEN" = "rtk $NORM_CMD" ]; then
  REWRITTEN="rtk $CMD"
fi

# No change — nothing to do.
if [ "$CMD" = "$REWRITTEN" ]; then
  exit 0
fi

ORIGINAL_INPUT=$(echo "$INPUT" | jq -c '.tool_input')
UPDATED_INPUT=$(echo "$ORIGINAL_INPUT" | jq --arg cmd "$REWRITTEN" '.command = $cmd')

jq -n \
  --argjson updated "$UPDATED_INPUT" \
  '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "allow",
      "permissionDecisionReason": "RTK auto-rewrite",
      "updatedInput": $updated
    }
  }'
