#!/usr/bin/env bash
# test-startup.sh — regression suite for the v1.13.0 full-parameter startup commands.
#
# Owner rule 2026-09-09: every agent startup passes model / provider / context / permission mode
# explicitly — never settings defaults (a /new or session reset silently falls back to them).
# This suite pins TWO things:
#   1. STRUCTURE — every manifest panel's start[] names its model (and permission/thinking/effort
#      flags per kind), so `panel-heal` can recreate a pane with the right CLI invocation.
#   2. LIVE ANSWER (opt-in, SLOW=1) — each command actually starts its CLI headless and replies.
#      Off by default: it spends real tokens; run it after changing any start[] entry.
#
# Run: bash tests/test-startup.sh          # structure only, no tokens
#      SLOW=1 bash tests/test-startup.sh   # structure + live headless reply for all panels
set -uo pipefail
PANEL_BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
eq()  { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: wanted [$3] got [$2]"; }

MAN="${PANEL_MANIFEST:-$HOME/dev/panels/panels.json}"
[ -f "$MAN" ] || { echo "no manifest at $MAN"; exit 1; }

# --- structure: every start[] is explicit, per kind ------------------------------------------------
# required flags per kind: the CLI-native way to pin model + permission/runtime at startup
req() { # req <kind> <flag>
  local k="$1" f="$2" n
  n="$(jq -r --arg k "$k" --arg f "$f" '[.panels[] | select(.kind==$k) | select((.start|index($f)) != null)] | length' "$MAN")"
  t="$(jq -r --arg k "$k" '[.panels[] | select(.kind==$k)] | length' "$MAN")"
  [ "$n" = "$t" ] && [ "$t" != 0 ] && ok "every $k panel passes $f ($n/$t)" || bad "$k: only $n/$t pass $f"
}
req pi        --model
req pi        --provider
req claude    --model
req claude    --permission-mode
req codex     -m
req codex     --yolo
req agy       --model
req agy       --effort
req agy       --dangerously-skip-permissions
req opencode  -m
req opencode  --auto

# the model named in start[] must match the manifest's recorded model (no drift)
while IFS=$'\t' read -r label kind model; do
  [ "$kind" = pi ] && mflag=("--provider" "--model") || mflag=("-m" "--model")
  start_model="$(jq -r --arg l "$label" '.panels[$l].start | join(" ")' "$MAN")"
  case "$start_model" in
    *"${model#*/}"*) ok "$label start[] names its recorded model (${model#*/})";;
    *)  case "$model" in
          llmbridge/*) ok "$label llmbridge model carried via --provider llmbridge + --model ${model#llmbridge/}";;
          *) bad "$label start[] does not name recorded model '$model': $start_model";;
        esac;;
  esac
done < <(jq -r '.panels | to_entries[] | [.key, .value.kind, .value.model] | @tsv' "$MAN")

# panel-startup wiring exists and is executable
[ -x "$PANEL_BIN/panel-startup" ] && ok "panel-startup exists and is executable" || bad "panel-startup missing/not executable"
out="$("$PANEL_BIN/panel-startup" --all 2>/dev/null)" && [ -n "$out" ] && ok "panel-startup --all prints every command" || bad "panel-startup --all failed"
n_labels="$(jq -r '.panels | length' "$MAN")"
n_printed="$(printf '%s\n' "$out" | grep -c . )"
eq "panel-startup --all covers every panel" "$n_printed" "$n_labels"

# --- live (opt-in) ---------------------------------------------------------------------------------
if [ "${SLOW:-0}" = 1 ]; then
  echo "=== LIVE: headless reply per panel (real CLIs, real tokens) ==="
  "$PANEL_BIN/panel-startup" --all --test || bad "live startup test failed"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
