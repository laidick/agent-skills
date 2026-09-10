#!/usr/bin/env bash
# escalate-lib.sh — shared helpers for the `escalate` CLI (autonomous-escalation skill).
# Requires: bash, jq, sha256sum (or shasum), date. No server, no DB — state is one JSON file.
set -u

ESC_VERSION="1.0.0"

ESC_ROOT="${ESCALATE_ROOT:-$PWD}"          # project root containing .pi/
ESC_PI="$ESC_ROOT/.pi"
ESC_STATE="$ESC_PI/escalations/state.json"
ESC_HELP_DIR="$ESC_PI/help"
ESC_ESC_DIR="$ESC_PI/escalations"
ESC_GOAL_STATE="$ESC_PI/goal-state.md"

# --- exit codes (documented in SKILL.md) -----------------------------------
ESC_E_OK=0
ESC_E_USAGE=2
ESC_E_DUP=10          # same-question re-escalation suppressed
ESC_E_COOLDOWN=11     # cooldown after last same-question escalation
ESC_E_DEPTH=12        # depth > max (reviewer must not spawn another non-human path)
ESC_E_BUDGET=13       # per-goal escalation budget exhausted -> HUMAN_FALLBACK
ESC_E_REJECTED=20     # answer kind does not match the escalation class
ESC_E_STALE=40        # answer recorded, but underlying state changed since packet

esc_die() { printf 'ERROR: %s\n' "$*" >&2; exit "$ESC_E_USAGE"; }

esc_sha_str() { printf '%s' "$1" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}'; }
esc_sha_file() { { command -v sha256sum >/dev/null 2>&1 && sha256sum "$1" || shasum -a 256 "$1"; } | awk '{print $1}'; }
esc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Redact known secret shapes from a stream (stderr-safe, line-oriented).
# Patterns are deliberately over-broad for safety; false positives read "[REDACTED]".
esc_redact() {
  sed -E \
    -e 's/(AKIA|ASIA)[0-9A-Z]{16}/[REDACTED]/g' \
    -e 's/(ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9]{20,}/[REDACTED]/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED]/g' \
    -e 's/sk-[A-Za-z0-9_-]{20,}/[REDACTED]/g' \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTED-PRIVATE-KEY]/g' \
    -e 's/(Bearer|bearer) [A-Za-z0-9._-]{16,}/\1 [REDACTED]/g' \
    -e 's/((password|passwd|secret|api[_-]?key|token|access[_-]?key|auth)[^:=[:space:]]{0,12}[=:])[^[:space:]]+/\1[REDACTED]/gI'
}

esc_bound() { # esc_bound <max-lines> — read stdin, keep first N lines
  local n="$1"
  sed -n "1,${n}p"
}

# --- state access -----------------------------------------------------------
esc_require_state() {
  command -v jq >/dev/null 2>&1 || esc_die "jq is required"
  [ -f "$ESC_STATE" ] || esc_die "no state at $ESC_STATE — run: escalate init --goal \"...\" (ESCALATE_ROOT=$ESC_ROOT)"
}

esc_state_get() { # esc_state_get [-r] [jq-args...] <filter> — jq -r over state
  jq -r "$@" "$ESC_STATE" 2>/dev/null
}
esc_state_q() { # esc_state_q [jq-args...] <filter> — jq -r over state (objects print as JSON)
  jq -r "$@" "$ESC_STATE" 2>/dev/null
}
esc_state_set() { # esc_state_set <jq-expression>
  local tmp
  tmp="$(mktemp)"
  jq "$1" "$ESC_STATE" > "$tmp" || { rm -f "$tmp"; esc_die "state update failed: $1"; }
  mv "$tmp" "$ESC_STATE"
}
esc_json() { jq -n --arg s "$1" '$s'; }   # -> double-quoted JSON string literal (no trailing newline)

# Current baseline hash: explicit baseline file (frozen design) if set,
# otherwise git HEAD when in a repo, otherwise "nogit".
esc_current_baseline() {
  local p h
  esc_require_state
  p="$(esc_state_get '.baseline_path')"
  if [ -n "$p" ] && [ "$p" != "null" ] && [ -f "$p" ]; then
    esc_sha_file "$p"
    return 0
  fi
  if [ -n "$p" ] && [ "$p" != "null" ]; then
    printf 'missing:%s\n' "$p"; return 0
  fi
  h="$(git -C "$ESC_ROOT" rev-parse --verify HEAD 2>/dev/null || true)"
  [ -n "$h" ] && printf 'git:%s\n' "$h" || printf 'nogit\n'
}

# Ladder for repeated-unhelpful-help: implementation/debug -> architecture -> human.
# (External/research is off-ladder; unhelpful research goes straight to human.)
esc_class_level() {
  case "$1" in
    "IMPLEMENTATION/DEBUG") echo 0 ;;
    "ARCHITECTURE/PANEL")   echo 1 ;;
    "HUMAN")                echo 2 ;;
    "EXTERNAL/RESEARCH")    echo 0 ;;
    *) esc_die "unknown class: $1" ;;
  esac
}
esc_level_class() {
  case "$1" in
    0) echo "IMPLEMENTATION/DEBUG" ;;
    1) echo "ARCHITECTURE/PANEL" ;;
    *) echo "HUMAN" ;;
  esac
}
# Next class up the ladder for an unhelpful escalation of $1.
esc_class_up() {
  local lvl
  case "$1" in
    "IMPLEMENTATION/DEBUG") echo "ARCHITECTURE/PANEL" ;;
    "ARCHITECTURE/PANEL")   echo "HUMAN" ;;
    "EXTERNAL/RESEARCH")    echo "HUMAN" ;;
    "HUMAN") echo "HUMAN" ;;
  esac
}

# Class determined by the latest recorded governance event (if any), else default.
esc_class_from_events() {
  local last
  last="$(esc_state_get '[.events[]?.kind] | last // empty')"
  esc_class_from_events_kind "$last"
}
# Kind -> class mapping (pure function; also used for events not yet in state).
esc_class_from_events_kind() {
  case "$1" in
    "") echo "IMPLEMENTATION/DEBUG" ;;
    deviation|design-conflict|architecture)     echo "ARCHITECTURE/PANEL" ;;
    external-conflict|current-fact|external)    echo "EXTERNAL/RESEARCH" ;;
    destructive|credentials|irreversible|security-auth|human-required) echo "HUMAN" ;;
    *) echo "IMPLEMENTATION/DEBUG" ;;
  esac
}

# Re-render .pi/goal-state.md from state, preserving the worker's "## Notes" tail.
esc_render_goal_state() {
  local tmp notes
  tmp="$(mktemp)"
  notes=""
  if [ -f "$ESC_GOAL_STATE" ]; then
    notes="$(awk '/^## Notes/{f=1; next} f' "$ESC_GOAL_STATE")"
  fi
  {
    echo "# GOAL STATE (managed by autonomous-escalation skill)"
    echo
    esc_state_get -r '. as $s |
      "GOAL: " + $s.goal + "\n" +
      "STATUS: " + $s.state + "\n" +
      "distinct failed attempts (streak): " + ($s.fail_streak|tostring) + " / " + ($s.config.min_distinct_attempts|tostring) + "\n" +
      "no-progress streak: " + ($s.no_progress_streak|tostring) + " / " + ($s.config.no_progress_cycles|tostring) + "\n" +
      "total distinct attempts: " + ($s.attempts|length|tostring) + "\n" +
      "escalations used: " + ($s.escalations|length|tostring) + " / " + ($s.config.max_escalations_per_goal|tostring) + "\n" +
      "baseline_ref: " + $s.baseline_ref'
    echo
    echo "## Escalation log"
    esc_state_get -r '.escalations[] | "- " + .id + " [" + .class + "] status=" + .status + (if .helpful then " helpful=yes" else "" end) + (if .stale then " STALE" else "" end)'
    echo
    echo "## Notes"
    [ -n "$notes" ] && printf '%s\n' "$notes"
  } > "$tmp"
  mv "$tmp" "$ESC_GOAL_STATE"
}
