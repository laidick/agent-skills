#!/usr/bin/env bash
# install.sh — symlink the shared `panel` skill into every coding agent present on THIS host.
# Idempotent; safe to re-run. Same wiring pattern as skills/wiki/install.sh (no hooks needed here).
set -u
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
ok()   { printf '  ✓ %s\n' "$*"; }
skip() { printf '  – %s\n' "$*"; }
chmod +x "$SKILL_DIR"/bin/* "$0" 2>/dev/null || true

link_skill() {  # link_skill <skills-parent-dir>
  local parent="$1"
  [ -d "$parent" ] || { skip "$parent (not present)"; return; }
  ln -sfn "$SKILL_DIR" "$parent/panel" && ok "$parent/panel -> $SKILL_DIR"
}
printf '== panel skill symlinks ==\n'
link_skill "$HOME/.claude/skills"
link_skill "$HOME/.pi/agent/skills"
link_skill "$HOME/.hermes/skills/productivity"
[ -d "$HOME/.codex" ] && mkdir -p "$HOME/.codex/skills"; link_skill "$HOME/.codex/skills"
[ -d "$HOME/.gemini" ] && mkdir -p "$HOME/.gemini/skills"; link_skill "$HOME/.gemini/skills"
link_skill "$HOME/.gemini/config/skills"
[ -d "$HOME/.config/opencode" ] && mkdir -p "$HOME/.config/opencode/skills"; link_skill "$HOME/.config/opencode/skills"
link_skill "$HOME/.agents/skills"

root="${PANEL_SESSIONS_ROOT:-$HOME/.local/state/agent-skills/panel/sessions}"
mkdir -p "$root" && ok "sessions root $root"
for c in herdr jq; do command -v "$c" >/dev/null 2>&1 && ok "$c found" || printf '  ! %s not on PATH — required at run time\n' "$c"; done
printf 'Done. Restart long-running agents (hermes gateway) so they re-scan skills.\n'
