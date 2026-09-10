#!/usr/bin/env bash
# install.sh — wire the `autonomous-escalation` skill into every coding agent present on THIS host.
# Idempotent; safe to re-run. Same wiring pattern as skills/panel/install.sh (no hooks needed).
# Also keeps a ~/wiki/skills compatibility symlink (only if a ~/wiki repo exists on this host;
# matching the ratified convention: canonical source here, installed to agent dirs.
set -u
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="$(basename "$SKILL_DIR")"
ok()   { printf '  ✓ %s\n' "$*"; }
skip() { printf '  – %s\n' "$*"; }
link_skill() {  # link_skill <skills-parent-dir>
  local parent="$1" cur
  [ -d "$parent" ] || { skip "$parent (agent not present)"; return 0; }
  local dest="$parent/$NAME"
  if [ -L "$dest" ]; then
    cur="$(readlink -f "$dest" 2>/dev/null || true)"
    if [ "$cur" = "$SKILL_DIR" ]; then ok "$dest (already correct)"; return 0; fi
  fi
  [ -e "$dest" ] && { printf '  ✗ REFUSING to replace real path %s\n' "$dest" >&2; return 0; }
  ln -sfn "$SKILL_DIR" "$dest" && ok "$dest -> $SKILL_DIR"
}
chmod +x "$SKILL_DIR"/bin/* "$0" 2>/dev/null || true
printf '== %s skill symlinks ==\n' "$NAME"
link_skill "$HOME/.claude/skills"
link_skill "$HOME/.pi/agent/skills"
link_skill "$HOME/.hermes/skills/productivity"
[ -d "$HOME/.codex" ] && link_skill "$HOME/.codex/skills"
[ -d "$HOME/.gemini" ] && link_skill "$HOME/.gemini/skills"
link_skill "$HOME/.gemini/config/skills"
[ -d "$HOME/.config/opencode" ] && link_skill "$HOME/.config/opencode/skills"
link_skill "$HOME/.agents/skills"

# Optional compat surface: if a ~/wiki/skills dir exists on this host (some setups keep
# skills there), link into it too — guarded, so strangers without ~/wiki are unaffected.
if [ -d "$HOME/wiki/skills" ]; then
  link_skill "$HOME/wiki/skills"
fi

for c in jq git; do command -v "$c" >/dev/null 2>&1 && ok "$c found" || printf '  ! %s not on PATH — required at run time\n' "$c"; done
printf 'Done. Restart long-running agents (hermes gateway) so they re-scan skills.\n'
