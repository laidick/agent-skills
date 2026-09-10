#!/usr/bin/env bash
# install.sh — wire every generic skill in this repo into every coding agent present on THIS host.
#
# Design:
#   * ONE canonical source (this repo). Agents get SYMLINKS, never copies.
#   * Idempotent: safe to re-run; repairs stale/wrong symlinks in place.
#   * Refuses to clobber a REAL directory/file that isn't ours (no silent data loss).
#   * Delegates to a skill's own install.sh when it has one (hooks/plugins/systemd wiring).
#
# Usage:
#   ./install.sh              # install every skill in skills/
#   ./install.sh panel        # install only named skill(s)
#   ./install.sh --check      # report what WOULD change; make no modifications
#   ./install.sh --list       # list discovered skills and agent targets
set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="$REPO/skills"

CHECK=0; LIST=0; ARGS=()
for a in "$@"; do
  case "$a" in
    --check|-n) CHECK=1 ;;
    --list)     LIST=1 ;;
    -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
    -*)         printf 'unknown option: %s\n' "$a" >&2; exit 2 ;;
    *)          ARGS+=("$a") ;;
  esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '  – %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; RC=1; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
RC=0

# Agent skill-directory targets. Each entry: <parent-dir>[:create]
# ":create" means make the parent when its agent root exists but skills/ does not.
agent_targets() {
  cat <<'TARGETS'
$HOME/.claude/skills
$HOME/.pi/agent/skills
$HOME/.hermes/skills/productivity
$HOME/.codex/skills:$HOME/.codex
$HOME/.gemini/skills:$HOME/.gemini
$HOME/.gemini/config/skills
$HOME/.config/opencode/skills:$HOME/.config/opencode
$HOME/.agents/skills
TARGETS
}

# link_one <canonical-src> <parent-dir> <link-name>
# Creates/repairs parent/link-name -> canonical-src. Never overwrites a real path.
link_one() {
  # NOTE: `local a=$1 b=$a` does NOT work — bash expands every argument to the
  # `local` builtin BEFORE assigning any of them, so $a is still unset there
  # (fatal under `set -u`). Declare first, derive afterwards.
  local src="$1" parent="$2" name="$3"
  local dest="$parent/$name" cur
  [ -d "$parent" ] || { skip "$parent (agent not present)"; return 0; }
  if [ -L "$dest" ]; then
    cur="$(readlink -f "$dest" 2>/dev/null || true)"
    if [ "$cur" = "$src" ]; then ok "$dest (already correct)"; return 0; fi
    if [ "$CHECK" = 1 ]; then warn "WOULD REPAIR $dest ($cur -> $src)"; return 0; fi
    ln -sfn "$src" "$dest" && ok "repaired $dest -> $src" || err "failed to repair $dest"
    return 0
  fi
  if [ -e "$dest" ]; then
    err "REFUSING to replace real path $dest (not a symlink). Move it aside, then re-run."
    return 0
  fi
  if [ "$CHECK" = 1 ]; then warn "WOULD CREATE $dest -> $src"; return 0; fi
  ln -sfn "$src" "$dest" && ok "$dest -> $src" || err "failed to link $dest"
}

discover_skills() {
  local d
  for d in "$SKILLS_DIR"/*/; do
    [ -f "${d}SKILL.md" ] || continue
    basename "$d"
  done
}

if [ "$LIST" = 1 ]; then
  hdr "Skills in $REPO/skills"
  for s in $(discover_skills); do printf '  %s\n' "$s"; done
  hdr "Agent targets (present on this host)"
  while IFS= read -r spec; do
    parent="$(eval echo "${spec%%:*}")"
    [ -d "$parent" ] && printf '  %s\n' "$parent" || printf '  %s (absent)\n' "$parent"
  done < <(agent_targets)
  exit 0
fi

SELECTED=("${ARGS[@]:-}")
[ -z "${SELECTED[0]:-}" ] && SELECTED=($(discover_skills))

[ "$CHECK" = 1 ] && hdr "DRY RUN — no changes will be made"

for skill in "${SELECTED[@]}"; do
  src="$SKILLS_DIR/$skill"
  if [ ! -f "$src/SKILL.md" ]; then err "no such skill: $skill"; continue; fi
  hdr "== $skill =="
  [ "$CHECK" = 1 ] || chmod +x "$src"/bin/* "$src"/*.sh 2>/dev/null || true
  while IFS= read -r spec; do
    parent="$(eval echo "${spec%%:*}")"
    create_root=""
    case "$spec" in *:*) create_root="$(eval echo "${spec#*:}")";; esac
    if [ -n "$create_root" ] && [ -d "$create_root" ] && [ ! -d "$parent" ] && [ "$CHECK" = 0 ]; then
      mkdir -p "$parent"
    fi
    link_one "$src" "$parent" "$skill" || true
  done < <(agent_targets)

  # Skill-specific extras (hooks, plugins, systemd units). The skill owns that logic.
  if [ -x "$src/install.sh" ]; then
    if [ "$CHECK" = 1 ]; then
      warn "WOULD RUN $skill/install.sh (skill-specific hooks/plugins)"
    else
      printf '  running %s/install.sh …\n' "$skill"
      AGENT_SKILLS_REPO="$REPO" "$src/install.sh" 2>&1 | sed 's/^/    /'
    fi
  fi
done

hdr "Done"
[ "$CHECK" = 1 ] && printf 'Dry run only — re-run without --check to apply.\n'
printf 'Restart long-running agents (e.g. hermes gateway) so they re-scan skills.\n'
exit $RC
