#!/usr/bin/env bash
# panel-lib.sh — shared helpers for the panel skill scripts. Source it; do not execute.
# Requirements: bash 4+, jq, herdr, running inside a Herdr pane (HERDR_ENV=1).

# ---- site config (.env): every host-specific value lives OUTSIDE this repo -----------------------
# Precedence: real environment variable > ~/.config/agent-skills/panel.env > built-in defaults.
# The repo ships skills/panel/panel.env.example; copy it, edit, and keep it untracked (it is in
# .gitignore as .env / *.local — copy it to ~/.config so it never lands in git at all).
PANEL_ENV_FILE="${PANEL_ENV_FILE:-$HOME/.config/agent-skills/panel.env}"
if [ -f "$PANEL_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$PANEL_ENV_FILE"
fi

PANEL_SESSIONS_ROOT="${PANEL_SESSIONS_ROOT:-$HOME/.local/state/agent-skills/panel/sessions}"
PANEL_PREFIX="${PANEL_PREFIX:-panel-}"
PANEL_MAX_ROUNDS="${PANEL_MAX_ROUNDS:-200}"           # discussion rounds (blind + cross); ratify rounds are extra — owner default 200 (2026-09-07)
PANEL_NUDGE_AFTER_S="${PANEL_NUDGE_AFTER_S:-90}"       # settled with no answer file for this long -> one reminder
PANEL_PANEL_TIMEOUT_S="${PANEL_PANEL_TIMEOUT_S:-900}"  # per-panel hard timeout per round
PANEL_COLLECT_TIMEOUT_S="${PANEL_COLLECT_TIMEOUT_S:-540}"  # one panel-collect invocation; re-run to continue
PANEL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PANEL_TEMPLATES="$PANEL_SKILL_DIR/templates"
PANEL_LIB="$PANEL_SKILL_DIR/lib"

die()  { printf 'panel: ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'panel: %s\n' "$*" >&2; }
now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date +%s; }
file_mtime(){ stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# date_epoch <any-date-string> -> epoch seconds, GNU date -d or BSD date -j -f fallback (macOS).
# Callers pass the same shapes GNU `date -d` accepts: "2026-09-06T03:44:00Z", "@1789014721",
# "Sep 6 03:44". Returns empty when neither parses (callers treat empty as no-epoch).
date_epoch() {
  local v="$1" out
  out="$(date -d "$v" +%s 2>/dev/null)" && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  case "$v" in
    @*) printf '%s' "${v#@}" ;;
    *)  # BSD: try ISO first, then "Mon D HH:MM" style
        out="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$v" +%s 2>/dev/null)" && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
        out="$(date -j -f "%b %e %H:%M" "$v" +%s 2>/dev/null)" && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
        out="$(date -j -f "%H:%M" "$v" +%s 2>/dev/null)" && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
        ;;
  esac
}
# date_fmt <epoch> <strftime> -> formatted; GNU date -d @N or BSD date -r N.
date_fmt() { date -d "@$1" "$2" 2>/dev/null || date -r "$1" "$2" 2>/dev/null; }

require_herdr() {
  [ "${HERDR_ENV:-}" = 1 ] || die "not inside a Herdr pane (HERDR_ENV != 1); refusing to drive Herdr from outside"
  command -v herdr >/dev/null 2>&1 || die "herdr CLI not on PATH"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  [ -n "${HERDR_WORKSPACE_ID:-}" ] || die "HERDR_WORKSPACE_ID unset"
  [ -n "${HERDR_PANE_ID:-}" ] || die "HERDR_PANE_ID unset"
}

# resolve_session <name|path> -> absolute session dir (must exist)
resolve_session() {
  local s="$1"
  if [ -d "$s" ]; then (cd "$s" && pwd); return 0; fi
  if [ -d "$PANEL_SESSIONS_ROOT/$s" ]; then printf '%s\n' "$PANEL_SESSIONS_ROOT/$s"; return 0; fi
  die "session not found: $s (root: $PANEL_SESSIONS_ROOT)"
}

# latest_round <session> -> highest N with rounds/rN, or 0
latest_round() {
  local d="$1" n=0 r
  shopt -s nullglob
  for r in "$d"/rounds/r*/; do
    r="${r%/}"; r="${r##*/r}"
    [ "$r" -gt "$n" ] 2>/dev/null && n="$r"
  done
  printf '%s\n' "$n"
}

# transcript <session> <event> <text...>  — append-only chain log
transcript() {
  local d="$1" ev="$2"; shift 2
  printf -- '- %s  **%s**  %s\n' "$(now_iso)" "$ev" "$*" >> "$d/transcript.md"
}

# json_set <file> <jq-filter> [jq args...]  — in-place update
json_set() {
  local f="$1" filter="$2"; shift 2
  local tmp; tmp="$(mktemp "${f}.XXXXXX")"
  jq "$@" "$filter" "$f" > "$tmp" && mv "$tmp" "$f"
}

# session_state <session> <state>  — update session.json state + timestamp
session_state() {
  json_set "$1/session.json" '.state=$s | .updated=$t' --arg s "$2" --arg t "$(now_iso)"
  transcript "$1" state "$2"
}

# agent_status <pane_id> -> idle|done|working|blocked|unknown|none|gone
agent_status() {
  local out
  if out="$(herdr agent get "$1" 2>/dev/null)"; then
    printf '%s' "$out" | jq -r '.result.agent.agent_status // "none"'
  elif herdr pane get "$1" >/dev/null 2>&1; then
    printf 'none\n'
  else
    printf 'gone\n'
  fi
}

# render_template <template-file> KEY=VALUE...  — {{KEY}} substitution, multi-line safe
# Single pass over the template: values are never re-scanned, so a value may contain `&`, `\`, or a literal
# `{{KEY}}` and is embedded verbatim. (Iteration 5 D6: bash 5.2 patsub_replacement expanded `&` in the unquoted
# replacement of `${tpl//"{{$key}}"/$val}` into the matched placeholder, and a later key substituted placeholder
# text that an earlier value had carried — the ratify/cross briefs misquoted panels' own `&&`.)
render_template() {
  local tpl; tpl="$(cat "$1")"; shift
  local -A kv=(); local pair
  for pair in "$@"; do kv["${pair%%=*}"]="${pair#*=}"; done
  local out="" rest="$tpl" pre key
  while [[ "$rest" == *"{{"* ]]; do
    pre="${rest%%\{\{*}"; rest="${rest#*\{\{}"
    if [[ "$rest" == *"}}"* ]]; then
      key="${rest%%\}\}*}"; rest="${rest#*\}\}}"
      if [[ -v kv["$key"] ]]; then out+="$pre${kv[$key]}"; else out+="$pre{{$key}}"; fi
    else
      out+="$pre{{"
    fi
  done
  printf '%s\n' "$out$rest"
}

# strip_html_comments <file> — print the file with all properly-closed <!-- … --> comments removed.
# Multi-line comments are handled; text before/after a comment on the same line is preserved.
# An UNCLOSED "<!--" is deliberately left intact so a <<FILL>> marker hidden behind malformed
# markup cannot become a validation bypass (fail closed). Implemented in Python because the
# previous hand-rolled awk state machine appended comment bodies regardless of its state flag.
strip_html_comments() { python3 "$PANEL_SKILL_DIR/lib/strip_comments.py" "$1"; }

# charter_unfilled <charter-file> — exit 0 (true) iff a <<FILL …>> marker remains in the *content*
# (HTML comments ignored). Used by panel-dispatch / panel-next so an unfilled charter is refused, but
# a fully-filled one whose template comment still mentions "<<FILL" dispatches cleanly.
charter_unfilled() { strip_html_comments "$1" | grep -q '<<FILL'; }

# ---------------------------------------------------------------------------------------------
# Manifest, state, failure classification, budget (added 2026-09-05 after trial 1)
# ---------------------------------------------------------------------------------------------
PANEL_MANIFEST="${PANEL_MANIFEST:-$HOME/.local/state/agent-skills/panel/panels.json}"   # per-workspace panel manifest (panel-manifest capture)
PANEL_STATE_DIR="${PANEL_STATE_DIR:-$HOME/.local/state/agent-skills/panel/state}"       # budget/probe state, survives sessions
PANEL_BUDGET_BUFFER="${PANEL_BUDGET_BUFFER:-10}"                   # percentage points above linear pace still allowed
PANEL_PROBE_RETRIES="${PANEL_PROBE_RETRIES:-4}"                     # probe screen re-reads (PANEL_PROBE_WAIT_S apart) until the output is provably fresh (D3-A)
PANEL_PROBE_WAIT_S="${PANEL_PROBE_WAIT_S:-3}"
PANEL_FILE_QUIET_S="${PANEL_FILE_QUIET_S:-$PANEL_PROBE_WAIT_S}"          # quiet time an answer file must show before the sweep, the timeout branch or panel-matrix takes it (D3-B; its own knob — claude C9, iteration 9)
PANEL_ROUND_GRACE_S="${PANEL_ROUND_GRACE_S:-60}"                    # D2-A (iteration 9): a file still changing at timeout_s is taken, marked "not quiet", once timeout_s + this has passed — bounded, never lost, never unclosable
PANEL_BUDGET_SCHEMA_MIN="1.9.0"                                      # D4-A (iteration 9): first writer that persisted every field budget_check reads; an older/unversioned `written_by` is treated as uncertain (D5-A variant b, enforced)
PANEL_TRANSIENT_RETRY_S="${PANEL_TRANSIENT_RETRY_S:-60}"            # spacing for the second nudge on transient errors

# manifest_get <label> <jq-expr-on-entry> [default]
manifest_get() {
  local out
  if [ -f "$PANEL_MANIFEST" ]; then
    out="$(jq -r --arg l "$1" ".panels[\$l] | ($2) // empty" "$PANEL_MANIFEST" 2>/dev/null || true)"
  fi
  printf '%s' "${out:-${3:-}}"
}
manifest_has() { [ -f "$PANEL_MANIFEST" ] && jq -e --arg l "$1" '.panels[$l] != null' "$PANEL_MANIFEST" >/dev/null 2>&1; }

# pane_by_label <label> -> pane_id or empty (current workspace)
pane_by_label() {
  herdr pane list --workspace "$HERDR_WORKSPACE_ID" 2>/dev/null | jq -r --arg l "$1" '.result.panes[] | select(.label==$l) | .pane_id' | head -1
}

# split_pane_for_label <label> <cwd> -> new pane_id (printed) or empty on failure.
# v1.14.1 (2026-09-10, opencode-seat incident): recreate a MISSING panel pane in its GRID SLOT, never a
# down-split from the orchestrator pane. The old path landed recreated panes ~16-20 rows tall in
# the left column, and opencode's bun TUI SIGILL-crashes (RC 132) in short narrow panes, so
# `herdr agent start` timed out forever while heal logged "no agent but a foreground process is
# running" on the dead shell (live sessions lost the opencode seat every round).
# Recipe: the newest layout snapshot ($PANEL_STATE_DIR/layout/panels-snapshot-*.json) carries
# each label's target rect. When a pane dies its space is absorbed by a live sibling that now
# OVERLAPS the dead slot. Candidates = live panes overlapping our snapshot rect (row band, x-range),
# by descending x-overlap. For each: the new pane's width = donor_live_w - donor_snapshot_w (the
# absorbed width; fallback: our snapshot w), clamped so BOTH the donor and the new pane keep >= 20
# cols (TUI crash zone) — first candidate passing the guards wins. Split the donor RIGHT; if the
# donor sits RIGHT of us in the snapshot, swap the new pane LEFT once so both return to their
# snapshot order. No snapshot / no valid donor -> empty; heal falls back to the orchestrator
# down-split, logged loudly (panel-restore --force remains the exact-geometry tool).
split_pane_for_label() {
  local label="$1" cwd="$2" snap="" x="" y="" w="" h=""
  snap="$(ls -t "$PANEL_STATE_DIR"/layout/panels-snapshot-*.json 2>/dev/null | head -1 || true)"
  { [ -n "$snap" ] && [ -s "$snap" ]; } || { printf ''; return; }
  read -r x y w h <<<"$(jq -r --arg l "$label" '.panels[$l] | "\(.x) \(.y) \(.w) \(.h)"' "$snap" 2>/dev/null)"
  { [ -n "$x" ] && [ -n "$w" ] && [ "$w" -gt 0 ] 2>/dev/null; } || { printf ''; return; }

  # live panes of this workspace with rects (one pane list + one layout read of its tab)
  local plist probe tab_lay
  plist="$(herdr pane list --workspace "$HERDR_WORKSPACE_ID" 2>/dev/null)"
  probe="$(printf '%s' "$plist" | jq -r '[.result.panes[] | .pane_id] | first // empty')"
  { [ -n "$probe" ]; } || { printf ''; return; }
  tab_lay="$(herdr pane layout --pane "$probe" 2>/dev/null)"
  [ -n "$tab_lay" ] || { printf ''; return; }

  # candidates: live panes overlapping our snapshot slot, by descending x-overlap
  local cands="" cand donor="" d_live_w="" d_label="" d_snap_w="" d_snap_x="" new_w="" r="" new=""
  cands="$(printf '%s' "$tab_lay" | jq -r --arg x0 "$x" --arg x1 "$((x + w))" --arg y0 "$y" --arg y1 "$((y + h))" '
    [.result.layout.panes[] |
      (.rect.x) as $px | (.rect.width) as $pw | (.rect.y) as $py | (.rect.height) as $ph |
      (([$px, ($x0|tonumber)] | max)) as $ox0 |
      (([($px + $pw), ($x1|tonumber)] | min)) as $ox1 |
      (([$py, ($y0|tonumber)] | max)) as $oy0 |
      (([($py + $ph), ($y1|tonumber)] | min)) as $oy1 |
      select($ox1 > $ox0 and $oy1 > $oy0) |
      {p: .pane_id, ov: ($ox1 - $ox0), ovy: ($oy1 - $oy0), x: $px, w: $pw}] |
    sort_by([-.ov, .x]) | .[].p' 2>/dev/null)"
  [ -n "$cands" ] || { printf ''; return; }

  for cand in $cands; do
    d_live_w="$(printf '%s' "$tab_lay" | jq -r --arg p "$cand" '.result.layout.panes[] | select(.pane_id==$p) | .rect.width')"
    { [ -n "$d_live_w" ] && [ "$d_live_w" -gt 0 ] 2>/dev/null; } || continue
    d_label="$(printf '%s' "$plist" | jq -r --arg p "$cand" '.result.panes[] | select(.pane_id==$p) | .label // empty')"
    d_snap_w="$(jq -r --arg l "$d_label" '.panels[$l].w // empty' "$snap" 2>/dev/null)"
    d_snap_x="$(jq -r --arg l "$d_label" '.panels[$l].x // empty' "$snap" 2>/dev/null)"
    # new-pane width: the absorbed part when the donor is in the snapshot, else our snapshot width
    if [ -n "$d_snap_w" ] && [ "$d_snap_w" -gt 0 ] 2>/dev/null; then
      new_w="$((d_live_w - d_snap_w))"
    else
      new_w="$w"
    fi
    # guards: both sides keep >= 20 cols; a candidate that cannot fund the new pane is skipped
    { [ "$new_w" -ge 20 ] 2>/dev/null && [ "$((d_live_w - new_w))" -ge 20 ] 2>/dev/null; } || continue
    r="$(python3 -c "d=$d_live_w; n=$new_w; print(round(1 - n/d, 4))" 2>/dev/null)"
    [ -n "$r" ] || continue
    new="$(herdr pane split --pane "$cand" --direction right --ratio "$r" --cwd "$cwd" --no-focus 2>/dev/null | jq -r '.result.pane.pane_id // empty')"
    [ -n "$new" ] || continue
    # order: donor RIGHT of us in the snapshot -> new pane must sit LEFT of the donor; a right-split
    # put it on the donor's right, so swap it left once (both panes return to their slots)
    if [ -n "$d_snap_x" ] && [ "$d_snap_x" -ge "$((x + w))" ] 2>/dev/null; then
      herdr pane swap --pane "$new" --direction left >/dev/null 2>&1 || true
    fi
    printf '%s' "$new"; return
  done
  printf ''; return
}

# classify_screen  (stdin: screen text) -> "class<TAB>hint"
# classes: usage-limit | auth | transient | context-window | permission-dialog | unknown
classify_screen() {
  local t cls=unknown hint
  t="$(cat)"
  if   printf '%s' "$t" | grep -qiE "usage limit|hit your (usage |weekly |session )?limit|rate.?limit|quota (exceeded|exhausted|reached)|too many requests|\b429\b|purchase more credits|out of credits|insufficient[_ ]quota|limit reached"; then cls=usage-limit
  elif printf '%s' "$t" | grep -qiE "unauthorized|\b401\b|\b403\b|invalid api key|api key (is )?(missing|invalid)|please (log ?in|sign in|authenticate)|session expired|not logged in"; then cls=auth
  elif printf '%s' "$t" | grep -qiE "ECONNREFUSED|ECONNRESET|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|network error|connection (reset|refused|error|closed|lost)|\b50[234]\b|\b529\b|overloaded|fetch failed|socket hang up|try again later|temporarily unavailable|stream (closed|error)"; then cls=transient
  elif printf '%s' "$t" | grep -qiE "context window (exceeded|is full|too small|limit|overflow)|exceed(s|ed) (the |your )?context window|prompt is too long|maximum context (length |window )?(exceeded|reached)|too many tokens|context length exceeded|exceeds the (model|context)"; then cls=context-window   # iteration 4: 'context window' alone is ordinary model prose (a panel's r1 false positive) — require an error phrase
  elif printf '%s' "$t" | grep -qiE "allow (once|always|for this session)|do you want to (proceed|allow|run)|\(y/n\)|\[y/N\]|yes, (allow|proceed)|approve this"; then cls=permission-dialog
  fi
  hint="$(printf '%s' "$t" | tr '\n' ' ' | grep -oiE "(try again (at|in) [^.]{1,30}|resets? (at|in) [^.·|]{1,30}|reset(s)? [0-9]{1,2}(:[0-9]{2})? ?(am|pm)?|available again [^.]{1,30})" | head -1 || true)"
  printf '%s\t%s\n' "$cls" "$hint"
}

# parse_reset_epoch <hint> -> epoch seconds or empty. Understands "6:34 PM", "3pm", "22:35" (today's instance), "in 2h 15m", "in 45 minutes".
# D1-B (iteration 8, claude C1 → 4/4): ONE dated-hint recogniser shared by parse_reset_epoch and reset_hint_dated, covering every dated
# shape PROBE_HINT_RE can capture — "on 6 Sep" / "on 6 September", "Sep 6," / "September 6", and ISO "2026-09-06". Two functions that
# must agree do not own two patterns. reset_date_of prints the date as date(1) wants it ("Sep 6", "2026-09-06") or nothing.
PANEL_MON_RE='(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*'
reset_date_of() {
  local h="$1" m mon day
  if m="$(printf '%s' "$h" | grep -oiE "\bon [0-9]{1,2} $PANEL_MON_RE\b" | head -1)" && [ -n "$m" ]; then m="${m#* }"; day="${m%% *}"; mon="${m#* }"        # "on 6 September"
  elif m="$(printf '%s' "$h" | grep -oiE "\b$PANEL_MON_RE [0-9]{1,2}\b" | head -1)" && [ -n "$m" ]; then mon="${m%% *}"; day="${m#* }"                          # "Sept 7"
  elif m="$(printf '%s' "$h" | grep -oE '\b[0-9]{4}-[0-9]{2}-[0-9]{2}\b' | head -1)" && [ -n "$m" ]; then printf '%s' "$m"; return 0                             # ISO
  else return 1; fi
  printf '%s %s' "$(printf '%s' "${mon:0:3}" | sed 's/^\(.\)/\U\1/')" "$day"   # month normalised to its 3-letter form: "Sept"/"September" → "Sep" (date(1) rejects "Sept")
}
# reset_clock_of <hint> -> the first clock in the hint ("03:44", "1:49am", "3pm") or nothing
reset_clock_of() { local c; c="$(printf '%s' "$1" | grep -oiE '\b([01]?[0-9]|2[0-3]):[0-5][0-9] ?(am|pm)?\b|\b[0-9]{1,2} ?(am|pm)\b' | head -1 || true)"; printf '%s' "$c"; [ -n "$c" ]; }
parse_reset_epoch() {
  local h="$1" now t="" tm dd hh mm
  now="$(now_epoch)"
  # iteration 5: "resets 03:36 on 6 Sep" carries its own date — use it (no day inference needed); iteration 8: every shape reset_date_of knows
  local dm; dm="$(reset_date_of "$h" || true)"
  tm="$(reset_clock_of "$h" || true)"
  if [ -n "$dm" ] && [ -n "$tm" ]; then
    t="$(date_epoch "$dm $tm" 2>/dev/null || true)"
    [ -n "$t" ] || { printf ''; return 0; }   # D1-B (iteration 9, codex C1 → 4/4): a recognised date that date(1) rejects ("Feb 30") is no reset at all — never today's clock while the hint reads as dated
  fi
  tm="$(printf '%s' "$h" | grep -oiE '[0-9]{1,2}(:[0-9]{2})? ?(am|pm)' | head -1 || true)"
  if [ -z "$t" ] && [ -n "$tm" ]; then
    t="$(date_epoch "$tm" 2>/dev/null || true)"   # today's instance; may be in the past — callers decide (stale banner vs tomorrow)
  fi
  if [ -z "$t" ]; then   # iteration 4: 24-hour clock ("resets 22:35", "at 07:17") — codex's /status hint went unparsed and the pace gate fell through
    tm="$(printf '%s' "$h" | grep -oE '\b([01]?[0-9]|2[0-3]):[0-5][0-9]\b' | head -1 || true)"
    [ -n "$tm" ] && t="$(date_epoch "$tm" 2>/dev/null || true)"
  fi
  if [ -z "$t" ]; then
    dd="$(printf '%s' "$h" | grep -oiE '[0-9]+ ?(d|day)' | grep -oE '[0-9]+' | head -1 || true)"
    hh="$(printf '%s' "$h" | grep -oiE '[0-9]+ ?(h|hr|hour)' | grep -oE '[0-9]+' | head -1 || true)"
    mm="$(printf '%s' "$h" | grep -oiE '[0-9]+ ?(m|min|minute)' | grep -oE '[0-9]+' | head -1 || true)"
    [ -n "$dd$hh$mm" ] && t=$((now + ${dd:-0} * 86400 + ${hh:-0} * 3600 + ${mm:-0} * 60))
  fi
  printf '%s' "${t:-}"
}

# reset_hint_dated <hint> -> exit 0 when the hint carries its own calendar date AND a clock, i.e. parse_reset_epoch used no day inference
# (D1-B, iteration 7: such a reset is never day-shifted by any writer). A predicate, because callers run parse_reset_epoch in $(…).
# Iteration 8 (D1-B, 4/4): decided by the same recogniser parse_reset_epoch uses — the two cannot drift again.
reset_hint_dated() { local dm tm; dm="$(reset_date_of "$1")" && tm="$(reset_clock_of "$1")" && [ -n "$(date_epoch "$dm $tm" 2>/dev/null)" ]; }   # iteration 9: dated only if date(1) accepts it too

# window_seconds "5h" | "24h" | "7d" | "" -> seconds (default 18000)
window_seconds() {
  case "${1:-}" in
    *d) printf '%s' $(( ${1%d} * 86400 ));;
    *h) printf '%s' $(( ${1%h} * 3600 ));;
    *m) printf '%s' $(( ${1%m} * 60 ));;
    ''|null) printf '18000';;
    *) printf '%s' "$1";;
  esac
}

# budget_write <label> <class> <hint> <reset_epoch|""> <used_pct|""> <source> [dated 0|1] [caveat] [positional 0|1]
# D1-B (iteration 7): a reset that carried an explicit date is stored as parsed — never day-shifted; only an undated past clock is
# inferred as tomorrow's instance. D3-A(=D): a reading accepted with the provider's own caveat ("limits may be stale") is persisted as
# uncertain=true with the caveat text. D2-B (iteration 8): a positional pick (window token absent, first candidate line used) is
# persisted too — the gate reads only this file, so a warning that dies at the transcript protects nobody (claude C4, spark r2).
# `written_by` records the schema that wrote the state (D5-A, spark variant b).
budget_write() {
  local r="${4:-}" dated="${7:-0}" cav="${8:-}" pos="${9:-0}"
  if [ -n "$r" ] && [ "$r" -lt "$(now_epoch)" ] && [ "$dated" != 1 ]; then r=$((r + 86400)); fi
  mkdir -p "$PANEL_STATE_DIR/budget"
  jq -n --arg l "$1" --arg c "$2" --arg h "$3" --arg r "$r" --arg u "${5:-}" --arg s "$6" --arg t "$(now_iso)" --argjson te "$(now_epoch)" --arg dated "$dated" --arg cav "$cav" --arg pos "$pos" \
    '{label:$l, class:$c, hint:$h, reset_epoch:(if $r=="" then null else ($r|tonumber) end), used_pct:(if $u=="" then null else ($u|tonumber) end), source:$s, seen_at:$t, seen_epoch:$te, dated:($dated=="1"), uncertain:($cav!=""), caveat:(if $cav=="" then null else $cav end), positional:($pos=="1"), written_by:"panel 1.10.0"}' \
    > "$PANEL_STATE_DIR/budget/$1.json"
}

# budget_check <label> -> prints "ok"|"skip"<TAB>reason ; exit 0 always
# Rules: usage-limit with reset in the future -> skip. A CLEAN probed used% above linear pace + buffer -> skip. Else ok.
# D6-B (iteration 8, 4/4): a reading the provider itself caveats never skips a panel — a wrong skip silences a member for a whole session and
# cannot be undone inside it, a wrong dispatch costs one round and the provider's own hard limit (usage-limit class, with its reset time) still
# skips. D2-B: a positional reading inherits that rule (the stronger warning — the toolkit could not tie the number to the configured window).
# D5-A: a state without the `uncertain` field was written before the field existed (pre-1.8.0) and is treated as uncertain — has(), not `//`,
# because jq's alternative operator would also swallow an explicit false (a panel's r2).
budget_check() {
  local f="$PANEL_STATE_DIR/budget/$1.json" now cls reset used win seen elapsed pace unc pos why margin wb wbv
  now="$(now_epoch)"
  [ -f "$f" ] || { printf 'ok\tno budget state\n'; return 0; }
  cls="$(jq -r .class "$f")"; reset="$(jq -r '.reset_epoch // empty' "$f")"; used="$(jq -r '.used_pct // empty' "$f")"; seen="$(jq -r .seen_epoch "$f")"
  win="$(window_seconds "$(manifest_get "$1" '.usage.window' '')")"
  if [ "$cls" = usage-limit ]; then
    if [ -n "$reset" ] && [ "$reset" -gt "$now" ]; then printf 'skip\tusage limit until %s\n' "$(date_fmt "$reset" +%H:%M 2>/dev/null || echo "$reset")"; return 0; fi
    if [ -z "$reset" ] && [ $((now - seen)) -lt "$win" ]; then printf 'skip\tusage limit seen %s min ago, no reset time\n' $(( (now - seen) / 60 )); return 0; fi
    printf 'ok\tlimit window passed\n'; return 0
  fi
  if [ -n "$used" ] && [ -n "$reset" ] && [ $((now - seen)) -lt "$win" ]; then
    elapsed=$(( win - (reset - now) )); [ "$elapsed" -lt 0 ] && elapsed=0; [ "$elapsed" -gt "$win" ] && elapsed="$win"
    pace=$(( elapsed * 100 / win ))
    unc="$(jq -r 'if has("uncertain") then (.uncertain|tostring) else "absent" end' "$f")"; margin="$PANEL_BUDGET_BUFFER"
    pos="$(jq -r 'if has("positional") then (.positional|tostring) else "absent" end' "$f")"   # D4-A (iteration 9, 4/4): the same has() fail-safe as `uncertain` — `//` read an absent field as clean
    why=""; case "$unc" in true) why="provider-caveated reading";; absent) why="pre-1.8.0 state (uncertain field absent)";; esac
    case "$pos" in true) why="${why:+$why, }positional reading (window token not found)";; absent) why="${why:+$why, }pre-1.9.0 state (positional field absent)";; esac
    wb="$(jq -r '.written_by // empty' "$f")"; wbv="${wb#panel }"   # D4-A: written_by is enforced, not decorative — a state from a writer older than the schema the gate reads is uncertain
    if [ -z "$wb" ] || [ "$(printf '%s\n%s\n' "$PANEL_BUDGET_SCHEMA_MIN" "$wbv" | sort -V | head -1)" != "$PANEL_BUDGET_SCHEMA_MIN" ]; then why="${why:+$why, }written by ${wb:-an unversioned writer} (schema < $PANEL_BUDGET_SCHEMA_MIN)"; fi
    if [ "$used" -gt $(( pace + margin )) ]; then
      if [ -n "$why" ]; then printf 'ok\tover pace (used %s%% at %s%% of window, +%s buffer) but NOT skipped — %s (D6-B/D2-B/D5-A): a real limit arrives as usage-limit\n' "$used" "$pace" "$margin" "$why"; return 0; fi
      printf 'skip\tover pace: used %s%% at %s%% of window (+%s buffer)\n' "$used" "$pace" "$margin"; return 0
    fi
    printf 'ok\tused %s%% at %s%% of window%s\n' "$used" "$pace" "${why:+ ($why)}"; return 0
  fi
  printf 'ok\tstate stale or incomplete\n'
}

# probe_parse <cmd> <win_tok> <pre_screen_file> <post_screen_file> [accept_stale 0|1] -> "status<US>used<US>hint<US>flags<US>note" (US = \x1f, so an EMPTY field survives `IFS=$'\x1f' read`; tabs collapsed — iteration 10 observation); status fresh|stale|waiting|none;
# flags: comma list of `caveat` (provider says its limits may be stale, accepted on the last read) and `positional` (window token absent — first candidate line used, claude C4 iteration 7)
# D3-A (iteration 6): a measurement counts only when it is provably the output of THIS probe — the block after a NEW echo of the
# command (echo count grew vs the pre-command screen) or, for TUIs that do not echo, a screen that changed after the command.
# Old screen text is never reused: no new echo → none, unchanged screen → waiting, a "may be stale" banner → stale (callers re-read).
# Candidate lines carry a limit word (`NN% used|left|remaining`) and are not context/cache/token stats (claude's `97% of input tokens
# from cache` was read as usage); the manifest window token wins; used% and the reset hint are paired from the chosen line and the two
# lines under it (codex C5) before falling back to the whole block.
# D1-B (iteration 9, codex C1 → 4/4): the extractor speaks the recogniser's date grammar — month names via PANEL_MON_RE (so "September" is not
# dropped) and an ISO alternative (so "2026-09-06 03:44" is not cut to "resets 20"); grep -o is leftmost-longest, so the complete dated form wins.
PROBE_HINT_RE="(resets? (at|in) [^.·|()]{1,30}|reset(s)? [0-9]{1,2}(:[0-9]{2})? ?(am|pm)?( on [0-9]{1,2} $PANEL_MON_RE)?|resets? $PANEL_MON_RE [0-9]{1,2},? [0-9]{1,2}(:[0-9]{2})? ?(am|pm)?|resets? [0-9]{4}-[0-9]{2}-[0-9]{2},? [0-9]{1,2}:[0-9]{2} ?(am|pm)?)"
probe_parse() {
  local cmd="$1" win_tok="$2" pre="$3" post="$4" line_tok="${6:-}" npre npost blk pl pline used hint idx flags="" pos_note=""
  npre="$(awk '{l=$0; gsub(/^[[:space:]>›❯$]+|[[:space:]]+$/,"",l); print l}' "$pre" | grep -cxF -- "$cmd" || true)"
  npost="$(awk '{l=$0; gsub(/^[[:space:]>›❯$]+|[[:space:]]+$/,"",l); print l}' "$post" | grep -cxF -- "$cmd" || true)"
  if [ "${npost:-0}" -gt "${npre:-0}" ]; then
    blk="$(awk -v c="$cmd" '{l=$0; gsub(/^[[:space:]>›❯$]+|[[:space:]]+$/,"",l)} l==c{buf=""; next} {buf=buf $0 "\n"} END{printf "%s", buf}' "$post")"
  elif cmp -s "$pre" "$post"; then printf 'waiting\x1f\x1f\x1f\x1fscreen unchanged after %s\n' "$cmd"; return 0
  elif [ "${npost:-0}" -eq 0 ]; then blk="$(cat "$post")"   # no echo at all (full-screen view): the changed screen is the response
  else printf 'none\x1f\x1f\x1f\x1fno new echo of %s (%s before, %s after) — old output not reused\n' "$cmd" "${npre:-0}" "${npost:-0}"; return 0; fi
  local caveat=""
  if printf '%s' "$blk" | grep -qi 'may be stale'; then   # codex prints this inside its own status box until its refresh lands
    [ "${5:-0}" = 1 ] || { printf 'stale\x1f\x1f\x1f\x1fprovider says limits may be stale\n'; return 0; }
    caveat=" (provider caveat: limits may be stale — accepted on the last re-read)"; flags="caveat"
  fi
  pl="$(printf '%s\n' "$blk" | grep -nE '[0-9]{1,3}[[:space:]]*%[[:space:]]*(used|left|remaining)\b' | grep -viE 'context|cache|token' || true)"
  [ -n "$pl" ] || { printf 'none\x1f\x1f\x1f\x1fno "NN%% used|left|remaining" line in the fresh output\n'; return 0; }
  pline=""; [ -z "$win_tok" ] || pline="$(printf '%s\n' "$pl" | grep -iF -- "$win_tok" | head -1 || true)"
  # D3-A (iteration 9, 4/4): when the provider's usage box has no window token (claude's /usage has no "5h"), the manifest may name the line to read
  # (usage.line, e.g. "Current session") — a verified, non-positional reading, so the pace gate has something real to act on again
  if [ -z "$pline" ] && [ -n "$line_tok" ]; then   # the label may sit on the line above the bar ("Current session" / "██ 4% used"): first candidate at or within two lines below it
    tl="$(printf '%s\n' "$blk" | grep -niF -- "$line_tok" | head -1 | cut -d: -f1 || true)"
    [ -z "$tl" ] || pline="$(printf '%s\n' "$pl" | awk -F: -v t="$tl" '$1 >= t && $1 <= t + 2 { print; exit }')"
    [ -z "$pline" ] || pos_note=" (line named by manifest usage.line '$line_tok'${win_tok:+; window token '$win_tok' absent})"
  fi
  if [ -z "$pline" ]; then pline="$(printf '%s\n' "$pl" | head -1)"; [ -z "$win_tok$line_tok" ] || { flags="${flags:+$flags,}positional"; pos_note=" (window token '${win_tok:-none}'${line_tok:+ and usage.line '$line_tok'} not found — first candidate line used)"; }; fi
  idx="${pline%%:*}"; pline="${pline#*:}"
  used="$(printf '%s' "$pline" | grep -oE '[0-9]{1,3}[[:space:]]*%[[:space:]]*(used|left|remaining)' | head -1 | grep -oE '^[0-9]+' || true)"
  if [ -n "$used" ] && printf '%s' "$pline" | grep -qiE '%[[:space:]]*(left|remaining)'; then used=$((100 - used)); fi
  hint="$(printf '%s\n' "$blk" | sed -n "${idx},$((idx + 2))p" | tr '\n' ' ' | grep -oiE "$PROBE_HINT_RE" | head -1 || true)"
  [ -n "$hint" ] || hint="$(printf '%s' "$blk" | tr '\n' ' ' | grep -oiE "$PROBE_HINT_RE" | head -1 || true)"
  pline="$(printf '%s' "$pline" | sed 's/[█░▌▏▎▍▋▊▉]//g; s/^[[:space:]│|]*//; s/[[:space:]]\{2,\}/ /g')"
  printf 'fresh\x1f%s\x1f%s\x1f%s\x1fline %s: %s%s%s\n' "$used" "$hint" "$flags" "$idx" "${pline:0:80}" "$caveat" "$pos_note"
}

# agent_name_from_label <label> -> herdr-legal agent name  [a-z][a-z0-9_-]{0,31}
agent_name_from_label() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '-' | sed 's/^[^a-z]*//' | cut -c1-32; }

# ---------------------------------------------------------------------------------------------
# Pane-reuse context isolation (v1.12.0) — a reused pane must start a panel session with a FRESH
# agent conversation. State lives in $PANEL_STATE_DIR/reset/<label>.json and survives sessions, so
# the contamination marker left by session A is still there when session B reuses the pane.
# ---------------------------------------------------------------------------------------------
PANEL_RESET_DIR="${PANEL_RESET_DIR:-$PANEL_STATE_DIR/reset}"
PANEL_RESET_SETTLE_S="${PANEL_RESET_SETTLE_S:-8}"        # default seconds to wait after a reset prompt
PANEL_RESET_MODE="${PANEL_RESET_MODE:-restart}"          # v1.14.0 (owner 2026-09-09): restart = kill+respawn the pane's agent
                                                        # from the manifest start[] — a NEW process is a fresh session by
                                                        # construction (new session file; model pinned by CLI args, rule 24),
                                                        # so reset+restore+verify collapses to ~1-2s per pane. The old in-place
                                                        # lifecycle (keystrokes, footer/probe verification, settle waits —
                                                        # minutes for 8 panels) remains available as PANEL_RESET_MODE=inplace
                                                        # for panes that must keep their process (e.g. a stateful agent you
                                                        # cannot restart mid-session).
PANEL_FRESH_FLOOR_K="${PANEL_FRESH_FLOOR_K:-32}"         # a context footer at/below this many k is the TUI's fresh-session baseline (pi ~0k, claude ~12-20k of system prompt): it cannot DROP, so it is not negative evidence for a fresh pane (Test H) — the probe carries the verdict; manifest-overridable via reset.fresh_floor_k
PANEL_RESET_PROBE_TIMEOUT_S="${PANEL_RESET_PROBE_TIMEOUT_S:-90}"   # how long the isolation probe may take to write its file
PANEL_RESET_WRITER="panel 1.12.3"

reset_state_file() { printf '%s/%s.json' "$PANEL_RESET_DIR" "$1"; }

# reset_state_get <label> <jq-expr> [default]
reset_state_get() {
  local f out; f="$(reset_state_file "$1")"
  [ -s "$f" ] || { printf '%s' "${3:-}"; return 0; }
  # jq's `//` swallows an explicit `false` (the trap the skill already ratified for uncertain/positional,
  # D5-A) — an absent field and a persisted `false` must not read the same. `\u0000` is unusable here
  # (command substitution strips NULs), so absence is signalled with a sentinel string.
  out="$(jq -r "($2) as \$v | if \$v == null then \"\\u241a-absent\" else (\$v|tostring) end" "$f" 2>/dev/null || true)"
  case "$out" in ''|*'-absent') printf '%s' "${3:-}";; *) printf '%s' "$out";; esac
}

# reset_state_set <label> <jq-filter> [jq args...] — create-or-update the per-pane reset state
reset_state_set() {
  local label="$1" filter="$2"; shift 2
  local f; f="$(reset_state_file "$label")"
  mkdir -p "$PANEL_RESET_DIR"
  [ -s "$f" ] || jq -n --arg l "$label" '{label:$l, reset_attempted:false, reset_verified:false, reset_at:null, reset_reason:null,
      used_by_session:null, used_marker:null, evidence:[], written_by:"'"$PANEL_RESET_WRITER"'"}' > "$f"
  json_set "$f" "$filter" "$@"
}

# reset_mark_used <label> <session_id> <marker> — the pane has now SEEN this session's work; until a
# verified reset clears it, any later session reusing the pane is contaminated. Called by panel-dispatch
# the moment a brief is actually delivered (dispatched or queued-then-delivered).
reset_mark_used() {
  reset_state_set "$1" '.used_by_session=$s | .used_marker=$m | .used_at=$t | .reset_verified=false | .eligible_r1=false | .reset_reason="pane used by session \($s) after its last verified reset"' \
    --arg s "$2" --arg m "${3:-PANEL TASK $2}" --arg t "$(now_iso)"
}

# reset_check <label> <session_id> -> "clean"|"unclean"|"unknown"<TAB>reason ; exit 0 always.
#   clean   — a VERIFIED reset for this session, or this session's own in-progress work (in-session reuse
#             is not contamination: the pane is answering the round it was reset for).
#   unclean — the pane carries ANOTHER session's conversation, or its reset was attempted and not verified.
#   unknown — no isolation record at all. Not a claim of cleanliness: the blind gate
#             (PANEL_REQUIRE_CLEAN=1) refuses it, later rounds of an already-reset session tolerate it.
reset_check() {
  local label="$1" sid="$2" f v used rsid rs att
  f="$(reset_state_file "$label")"
  [ -s "$f" ] || { printf 'unknown\tno isolation record for this pane — a reset must run and be verified before r1\n'; return 0; }
  used="$(jq -r '.used_by_session // empty' "$f")"
  v="$(jq -r 'if has("reset_verified") then (.reset_verified|tostring) else "absent" end' "$f")"
  att="$(jq -r 'if has("reset_attempted") then (.reset_attempted|tostring) else "absent" end' "$f")"
  rsid="$(jq -r '.reset_session // empty' "$f")"
  rs="$(jq -r '.reset_reason // "no reason recorded"' "$f")"
  if [ -n "$used" ]; then
    if [ -n "$sid" ] && [ "$used" = "$sid" ]; then printf 'clean\tin-session reuse: this pane already holds session %s work\n' "$sid"; return 0; fi
    printf 'unclean\tpane carries session %s context — %s\n' "$used" "$rs"; return 0
  fi
  if [ "$v" = true ]; then
    if [ -n "$sid" ] && [ -n "$rsid" ] && [ "$rsid" != "$sid" ]; then printf 'unclean\tlast verified reset was for session %s, not %s\n' "$rsid" "$sid"; return 0; fi
    printf 'clean\t%s\n' "$rs"; return 0
  fi
  [ "$att" = true ] && { printf 'unclean\t%s\n' "$rs"; return 0; }
  [ "$(jq -r 'if has("reset_failed") then (.reset_failed|tostring) else "false" end' "$f")" = true ] && { printf 'unclean\t%s\n' "$rs"; return 0; }
  printf 'unknown\t%s\n' "$rs"
}

# footer_kilo "118k/262k" -> 118 ; "1.2M/…" -> 1200 ; "9000/262k" -> 9
footer_kilo() {
  local n="${1%%/*}"
  case "$n" in
    *M) awk -v v="${n%M}" 'BEGIN{printf "%d", v*1000}';;
    *k) awk -v v="${n%k}" 'BEGIN{printf "%d", v}';;
    *)  awk -v v="$n" 'BEGIN{printf "%d", v/1000}';;
  esac
}
# pane_footer <pane> -> the TUI context footer ("118k/262k") if this TUI shows one
pane_footer() { herdr pane read "$1" --source visible 2>/dev/null | grep -oE '[0-9.]+[kM]?/[0-9.]+[kM]\b' | tail -1 || true; }

# reset_spec <label> <kind> -> compact JSON reset recipe, or empty when this kind has none.
# Manifest wins: .panels[label].reset, then .kinds[kind].reset; otherwise the built-in per-kind default
# for the panel kinds installed on this host. Fields: prompts[] · send(keys|prompt) · settle_s · restore[]
# · verify {footer:bool, probe:bool}.
reset_spec() {
  local label="$1" kind="${2:-}" m="" k=""
  if [ -f "$PANEL_MANIFEST" ]; then
    m="$(jq -c --arg l "$label" '.panels[$l].reset // empty' "$PANEL_MANIFEST" 2>/dev/null || true)"
    [ -n "$m" ] || m="$(jq -c --arg k "$kind" '.kinds[$k].reset // empty' "$PANEL_MANIFEST" 2>/dev/null || true)"
  fi
  case "$kind" in
    pi)               k='{"prompts":["/new"],"send":"keys","settle_s":8,"restore":["/model {{model}}"],"verify":{"footer":true,"probe":true}}';;
    claude)           k='{"prompts":["/clear"],"send":"keys","settle_s":6,"restore":[],"verify":{"footer":true,"probe":true}}';;
    codex)            k='{"prompts":["/new"],"send":"keys","settle_s":6,"restore":["/model {{model}} {{effort}}"],"verify":{"footer":true,"probe":true}}';;
    hermes)           k='{"prompts":["/new"],"send":"keys","settle_s":6,"restore":[],"verify":{"footer":true,"probe":true}}';;
    agy|gemini)       k='{"prompts":["/clear"],"send":"keys","settle_s":6,"restore":[],"verify":{"footer":true,"probe":true}}';;
    opencode)         k='{"prompts":["/new"],"send":"keys","settle_s":6,"restore":["/models {{model}}"],"verify":{"footer":true,"probe":true}}';;
    *)                k='';;
  esac
  if [ -n "$m" ] && [ -n "$k" ]; then jq -c -n --argjson d "$k" --argjson o "$m" '$d * $o'   # manifest overrides field by field
  elif [ -n "$m" ]; then printf '%s' "$m"
  else printf '%s' "$k"; fi
}

# --- the reset lifecycle itself ---------------------------------------------------------------
# The pane-touching primitives are separate one-line functions so the regression suite can drive the
# whole lifecycle against a simulated agent (a real conversation file that only an EXECUTED command
# clears) instead of stubbing bash internals. Production bodies use herdr only.
#
# pane_send_line <pane> <text> <mode>   mode=keys: type it and press Enter (a slash command is EXECUTED);
#                                       mode=prompt: herdr agent prompt (the model reads it as TEXT).
# PANEL_SEND_SETTLE_S: these TUIs autocomplete/render a picker as the text arrives; an Enter sent in the
# same instant is swallowed or hits a half-drawn list (observed live on pi's /model, 2026-09-07).
PANEL_SEND_SETTLE_S="${PANEL_SEND_SETTLE_S:-2}"
pane_send_line() {
  local pane="$1" text="$2" mode="${3:-keys}"
  if [ "$mode" = prompt ]; then herdr agent prompt "$pane" "$text" >/dev/null 2>&1; return $?; fi
  herdr pane send-text "$pane" "$text" >/dev/null 2>&1 || return 1
  sleep "$PANEL_SEND_SETTLE_S"
  herdr pane send-keys "$pane" Enter >/dev/null 2>&1
}
# pane_confirm_enter <pane> — one extra Enter, for a command that opened a selection list (pi's /model)
pane_confirm_enter() { herdr pane send-keys "$1" Enter >/dev/null 2>&1; }
# pane_screen <pane> -> visible screen text
pane_screen() { herdr pane read "$1" --source visible 2>/dev/null || true; }
# pane_status_line <pane> -> ONLY the TUI's bottom status region (the last non-empty lines).
# The model must be confirmed HERE, never on the full screen: a `/model <name>` picker echoes the name
# you just typed on the input line, so a full-screen grep reports a restore that never happened
# (observed live 2026-09-07: the picker echo read as success while the status line still showed the old
# model). The status line is the TUI's own report of what it is actually running.
# The status BAR is the last non-empty line, and an input/echo line is never it: a line that starts with
# the input prompt or with the very command we typed is the picker echo, not the TUI's report.
# (Live 2026-09-07: `tail -3` still caught "/model spark/qwen3.8-flash-next" on the input line and
# reported a restore while the bar still read `qwen3.8-coding`.)
pane_status_line() {
  pane_screen "$1" | grep -v '^[[:space:]─│|]*$' \
    | grep -vE '^[[:space:]]*([>›❯$]|/[a-zA-Z])' \
    | tail -1
}

# pane_dismiss_modal <pane> — one Escape, to close a picker/selection widget the restore or a previous
# session left open. Closing a UI widget is NOT answering a safety flow: permission dialogs are never
# dismissed by the reset (rule 5) — those fail closed for the human to decide instead.
pane_dismiss_modal() { herdr pane send-keys "$1" Escape >/dev/null 2>&1 || true; }

# screen_modal_class (stdin: screen text) -> "modal-picker"|"permission-dialog"|"" (empty = no modal seen).
# I4 (v1.12.1): a pane sitting in a modal UI state is NOT clean — r1 text typed into it lands in the
# dialog's input, never in the conversation (observed live 2026-09-08: two r1 pointers were typed into
# model-picker search boxes). Signatures are deliberately narrow — picker cues must co-occur on one
# screen; a false positive costs one dismissed pane (re-run the reset), a false negative costs the
# blind-review invariant, so the picker class errs toward detection. The permission-dialog branch
# mirrors classify_screen's, so the two classifiers cannot drift.
screen_modal_class() {
  local t; t="$(cat)"
  if printf '%s' "$t" | grep -qiE 'no matching models|enter to select.{0,60}(set as default|ctrl\+s)|(select|choose|pick) a? ?model.{0,120}esc(ape)?'; then printf 'modal-picker\n'
  elif printf '%s' "$t" | grep -qiE 'allow (once|always|access)|do you want to (proceed|allow|run)|yes, (allow|proceed)|approve (this|access)|permission (request|dialog)'; then printf 'permission-dialog\n'
  else printf '\n'; fi
}

# reset_probe <label> <pane> <kind> <marker> <probe_file> -> writes the agent's answer to <probe_file>.
# THE isolation test: the agent is asked to report, in a file, any prior panel task it can still recall.
# A contaminated conversation answers with the previous session's marker/canary; a fresh one cannot.
reset_probe() {
  local label="$1" pane="$2" kind="$3" marker="$4" out="$5" waited=0
  rm -f "$out"
  pane_send_line "$pane" "ISOLATION PROBE. Do not use any tool other than writing one file. Write $out containing exactly one line: the identifier of the PANEL TASK you were working on before this message if you can still recall one from this conversation, otherwise the single word NO_PRIOR_CONTEXT. Reply with only that path." prompt || return 1
  while [ "$waited" -lt "$PANEL_RESET_PROBE_TIMEOUT_S" ]; do
    [ -s "$out" ] && { sleep 1; return 0; }
    sleep "$PANEL_PROBE_WAIT_S"; waited=$((waited + PANEL_PROBE_WAIT_S))
  done
  return 1
}

# reset_pane <label> <pane> <kind> <session_id> [session_dir] -> 0 verified clean, 1 reset failed/unverified,
# 2 not attempted (pane not settled — never interrupted). Always persists the state the roster/status read.
#
# v1.14.0 RESTART MODE (owner 2026-09-09, default): kill the pane's agent process and respawn it from the
# manifest start[] (the full-parameter command, rule 24). A brand-new process IS the fresh-session proof:
# its session file is new (the CLI's own store), the model comes pinned by CLI args (closed over per pane —
# pi source-verified), and no restore/verify dance is needed. What the restart path still enforces, because
# they are process-independent:
#   * working/blocked panes are NEVER restarted (rule 8 — same not-attempted rc=2 as in-place mode)
#   * the screen is read once after respawn; a modal/picker after start = reset_failure_class, fail closed (I4)
#   * the isolation state is persisted with reset_method=restart so the audit trail says WHICH proof ran
# The old in-place lifecycle (keystrokes → restore → footer+probe verification, settle waits) remains as
# PANEL_RESET_MODE=inplace: the strongest evidence when a pane's process must survive.
#
# v1.12.1 (I1/I4/I5, production 2026-09-08): the in-place lifecycle order is reset → RESTORE → VERIFY — the
# isolation probe runs AFTER the restore, so a restore that opened a model picker cannot ride on an
# earlier proof; a restore command whose configured value resolved empty is never sent (a bare `/models`
# OPENS the picker — that is how the opencode panel’s r1 landed inside a picker while restore_applied read
# true); a model confirmed while a picker is still open is re-checked after the picker is dismissed
# (a local-model panel's list line matched the model name inside `No matching models`); a permission dialog is
# never answered and never dismissed — the pane fails closed for the human. Every failure persists a
# reset_failure_class; eligible_r1/observed_model are recorded, never fabricated.
reset_pane() {
  local label="$1" pane="$2" kind="$3" sid="$4" d="${5:-}"

  # ---- v1.14.0 restart mode: fresh process = fresh session, by construction --------------------------
  if [ "${PANEL_RESET_MODE:-restart}" = restart ]; then
    local st argv name out
    st="$(agent_status "$pane")"
    case "$st" in
      idle|done|none) ;;   # settled, or NO agent at all — a dead pane is the textbook restart case (v1.14.0)
      *) reset_state_set "$label" '.reset_attempted=false | .reset_verified=false | .reset_at=$t | .reset_session=$s | .reset_reason=$r | .reset_failure_class="working-pane" | .eligible_r1=false' \
           --arg t "$(now_iso)" --arg s "$sid" --arg r "not restarted — agent is $st; a working or blocked pane is never interrupted (rule 8)"
         return 2;;
    esac
  # restart mode (v1.14.0): the KIND comes from the manifest, never the transient roster — after any
  # restart, herdr briefly reports the pane with agent null and the roster's `// "-"` fallback fed
  # `--kind -` to herdr agent start ("unsupported interactive agent kind: -").
  k_manifest="$(jq -r --arg l "$label" '.panels[$l].kind // empty' "$PANEL_MANIFEST" 2>/dev/null || true)"
  kind="${k_manifest:-$kind}"
  [ -n "$kind" ] && [ "$kind" != "-" ] || { reset_state_set "$label" '.reset_attempted=false | .reset_failed=true | .reset_verified=false | .reset_at=$t | .reset_session=$s | .reset_reason=$r | .reset_failure_class="no-kind" | .eligible_r1=false' \
      --arg t "$(now_iso)" --arg s "$sid" --arg r "restart needs the agent kind (manifest .panels[$label].kind is empty and the roster read '-' — herdr could not classify the pane)"; return 1; }
  mapfile -t argv < <(jq -r --arg l "$label" '.panels[$l].start[1:][]?' "$PANEL_MANIFEST" 2>/dev/null || true)
    [ "${#argv[@]}" -ge 1 ] || { reset_state_set "$label" '.reset_attempted=false | .reset_failed=true | .reset_verified=false | .reset_at=$t | .reset_session=$s | .reset_reason=$r | .reset_failure_class="no-start-command" | .eligible_r1=false' \
        --arg t "$(now_iso)" --arg s "$sid" --arg r "restart needs the manifest start[] (full-parameter command, rule 24)"; return 1; }
    # stop the old process (C-c + /quit + Enter — the empirically-proven stop sequence) then respawn.
    # C-c is the real stop for every CLI here (codex ignores /quit; claude/pi take C-c cleanly); /quit
    # only lands if C-c already dropped to the shell, where zsh reporting "no such file" is harmless.
    herdr pane send-keys "$pane" C-c >/dev/null 2>&1 || true
    herdr pane send-text "$pane" "/quit" >/dev/null 2>&1 || true
    herdr pane send-keys "$pane" Enter >/dev/null 2>&1 || true
    sleep "${PANEL_RESTART_STOP_S:-2}"
    name="$(agent_name_from_label "$label")"
    # a restart re-uses the SAME agent name: release herdr's stale claim on it first (a leftover
    # name->old-terminal mapping otherwise makes `agent start` mint a NEW pane — the v1.14.0 drill
    # created stray duplicate panel panes exactly this way). `|| true`: absent claim is fine.
    herdr pane release-agent "$pane" --source "$HERDR_PANE_ID" --agent "$name" >/dev/null 2>&1 || true
    # `agent start` races the old process's exit ("not an available shell") — bounded retry:
    out=""; started=0
    for attempt in 1 2 3; do
      if out="$(herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout "$(manifest_get "$label" '.start_timeout_ms' '90000')" ${argv[@]+-- "${argv[@]}"} 2>&1)"; then started=1; break; fi
      case "$out" in *"not an available shell"*) sleep "${PANEL_RESTART_RETRY_S:-1}";; *) break;; esac
    done
    if [ "$started" = 1 ]; then
      # guard: the start must land in THIS pane — a name conflict would have minted a new pane
      local landed
      landed="$(herdr pane list 2>/dev/null | jq -r --arg p "$pane" '.result.panes[] | select(.pane_id==$p) | .agent // empty')"
      if [ "$landed" != "$kind" ]; then
        reset_state_set "$label" '.reset_attempted=true | .reset_failed=true | .reset_verified=false | .reset_at=$t | .reset_session=$s | .reset_reason=$r | .reset_failure_class="landed-elsewhere" | .eligible_r1=false | .reset_method="restart"' \
          --arg t "$(now_iso)" --arg s "$sid" --arg r "restart FAILED — the new agent landed outside $pane (name conflict not released?); inspect the workspace for a stray pane"
        return 1
      fi
      sleep "${PANEL_RESTART_SETTLE_S:-1}"
      # I4: a modal/picker after respawn fails closed — the screen is read once, never typed into
      local modal
      modal="$(printf '%s' "$(pane_screen "$pane")" | screen_modal_class)"
      if [ -n "$modal" ]; then
        reset_state_set "$label" '.reset_attempted=true | .reset_failed=true | .reset_verified=false | .reset_at=$t | .reset_session=$s | .reset_reason=$r | .reset_failure_class=$f | .eligible_r1=false | .reset_method="restart"' \
          --arg t "$(now_iso)" --arg s "$sid" --arg r "restart FAILED — pane is in a $modal state after start" --arg f "$modal"
        return 1
      fi
      reset_state_set "$label" '.reset_attempted=true | .reset_failed=false | .reset_verified=true | .reset_at=$t | .reset_session=$s | .reset_reason=$r | .eligible_r1=true | .reset_method="restart"
          | (if $v then (.used_by_session=null | .used_marker=null) else . end) | .observed_model=$m' \
        --arg t "$(now_iso)" --arg s "$sid" --arg r "restart verified — fresh process from start[] (full-parameter command); new session by construction; model pinned by CLI args" \
        --argjson v true --arg m "$(manifest_get "$label" '.model' 'unknown')"
      [ -n "$d" ] && transcript "$d" reset "$label ($pane, $kind): restart verified — fresh process (model pinned by start[])" || true
      return 0
    else
      reset_state_set "$label" '.reset_attempted=true | .reset_failed=true | .reset_verified=false | .reset_at=$t | .reset_session=$s | .reset_reason=$r | .reset_failure_class="start-failure" | .eligible_r1=false | .reset_method="restart"' \
        --arg t "$(now_iso)" --arg s "$sid" --arg r "restart FAILED — herdr agent start: $(printf '%s' "$out" | jq -r '.error.message // .' 2>/dev/null | head -1 | cut -c1-160)"
      return 1
    fi
  fi

  local spec prompts send settle floor restore fb fa st marker probe_out probe_ans model thinking effort
  local verdict="" reason="" probe_ok=absent footer_ok=absent ev="[]" cmd rc fcls="" orig probe_recall=false
  local rst_applied=false rst_verified=absent observed_model="unknown" mshort=""
  local modal="" rst_fail_cls="" tries=0

  spec="$(reset_spec "$label" "$kind")"
  if [ -z "$spec" ]; then
    reset_state_set "$label" '.reset_attempted=false | .reset_failed=true | .reset_verified=false | .reset_at=$t | .reset_session=$s | .reset_reason=$r | .reset_failure_class="no-recipe" | .eligible_r1=false' \
      --arg t "$(now_iso)" --arg s "$sid" --arg r "no reset recipe for kind '${kind:-unknown}' — isolation cannot be established, fail closed"
    return 1
  fi
  # tolerate the v1.11.0 singular `prompt` field alongside `prompts`
  mapfile -t prompts < <(printf '%s' "$spec" | jq -r 'if (.prompts // null) then .prompts[] elif (.prompt // null) then .prompt else empty end')
  send="$(printf '%s' "$spec" | jq -r '.send // "keys"')"
  settle="$(printf '%s' "$spec" | jq -r '.settle_s // empty')"; [ -n "$settle" ] || settle="$PANEL_RESET_SETTLE_S"
  floor="$(printf '%s' "$spec" | jq -r '.fresh_floor_k // empty')"; [ -n "$floor" ] || floor="$PANEL_FRESH_FLOOR_K"
  [ "${#prompts[@]}" -gt 0 ] || { reset_state_set "$label" '.reset_attempted=false | .reset_failed=true | .reset_verified=false | .reset_at=$t | .reset_session=$s | .reset_reason=$r | .reset_failure_class="no-prompts" | .eligible_r1=false' --arg t "$(now_iso)" --arg s "$sid" --arg r "reset recipe has no prompts"; return 1; }

  st="$(agent_status "$pane")"
  case "$st" in idle|done) ;; *)
    reset_state_set "$label" '.reset_attempted=false | .reset_verified=false | .reset_at=$t | .reset_session=$s | .reset_reason=$r | .eligible_r1=false' \
      --arg t "$(now_iso)" --arg s "$sid" --arg r "not reset — agent is $st; a working or blocked pane is never interrupted (rule 8)"
    return 2;; esac

  marker="$(reset_state_get "$label" '.used_marker' '')"
  fb="$(pane_footer "$pane")"
  reset_state_set "$label" '.reset_attempted=true | .reset_at=$t | .reset_session=$s | .reset_verified=false | .reset_reason="reset in progress" | .footer_before=$f | .kind=$k | .spec=$sp | .written_by=$w' \
    --arg t "$(now_iso)" --arg s "$sid" --arg f "$fb" --arg k "$kind" --argjson sp "$spec" --arg w "$PANEL_RESET_WRITER"

  for cmd in "${prompts[@]}"; do
    if ! pane_send_line "$pane" "$cmd" "$send"; then
      reset_state_set "$label" '.reset_verified=false | .reset_failed=true | .reset_reason=$r | .reset_failure_class="send-failure" | .eligible_r1=false' --arg r "could not send '$cmd' to $pane"
      return 1
    fi
    sleep "$settle"
  done
  # v1.12.2 ordering (I1/I4/I5): the footer is read right after the reset prompts — it measures the
  # RESET's own context-clearing effect (a restore command is a control keystroke; it adds no agent
  # context). Everything that guards the RESTORE — the modal check, the isolation probe and the model
  # confirmation — runs AFTER the restore commands and decides the FINAL verdict: the 2026-09-08 false
  # CLEANs happened because the probe ran first, so a restore that opened a model picker rode on an
  # earlier proof (the opencode panel’s empty {{model}} left a bare `/models` that opened the picker; a local-model panel’s
  # valid model hit a catalog mismatch) and the picker was live when the r1 pointer was typed into it.
  fa="$(pane_footer "$pane")"

  # evidence 1 — the TUI's own context footer.
  # A pane with NO footer before the reset is treated as unsettleable-by-footer and skipped as evidence
  # (absent, neither passing nor failing). The SAME applies to a footer that was ALREADY at the fresh-
  # session baseline (kilo ≤ fresh_floor_k): a brand-new pane's footer sits at its TUI's baseline (pi 0k,
  # claude ~12-20k of system prompt) and can never DROP — "NO EFFECT" there was a false FAILED for a
  # genuinely fresh pane (Test H, 2026-09-09). The floor only ever relaxes false→absent, and an absent
  # footer never verifies anything by itself: the probe carries the verdict or the reset fails closed.
  # A footer present before and after that did NOT drop while ABOVE the floor stays the v1.11.0
  # contradiction (the command was accepted as text, not executed).
  if [ -n "$fb" ] && [ -n "$fa" ]; then
    if [ "$(footer_kilo "$fa")" -lt "$(footer_kilo "$fb")" ]; then footer_ok=true; ev="$(printf '%s' "$ev" | jq --arg e "context footer $fb → $fa (dropped)" '. + [$e]')"
    elif [ "$(footer_kilo "$fb")" -le "$floor" ]; then ev="$(printf '%s' "$ev" | jq --arg e "context footer $fb → $fa (already at the fresh-session baseline ≤${floor}k — nothing to clear; the probe carries the verdict)" '. + [$e]')"
    else footer_ok=false; ev="$(printf '%s' "$ev" | jq --arg e "context footer $fb → $fa (NO EFFECT — the command was accepted as text, not executed)" '. + [$e]')"; fi
  fi

  # restore the configured model / thinking / effort the reset may have dropped — BEFORE all post-restore
  # verification, so the modal check, the probe and the model confirmation all see the restored pane
  model="$(manifest_get "$label" '.model' '')"; thinking="$(manifest_get "$label" '.thinking' '')"; effort="$(manifest_get "$label" '.effort' '')"
  restore="$(printf '%s' "$spec" | jq -r '(.restore // [])[]')"
  if [ -n "$restore" ]; then
    while IFS= read -r cmd; do
      [ -n "$cmd" ] || continue
      orig="$cmd"
      # I5 hollow-restore guard (opencode panel, 2026-09-08): a placeholder that resolved EMPTY erases
      # itself — `/models {{model}}` with a null manifest model leaves a BARE `/models`, which OPENS
      # the picker. A restore command that references a value we do not have is never sent.
      if { [[ "$orig" == *'{{model}}'* ]] && [ -z "$model" ]; } || { [[ "$orig" == *'{{thinking}}'* ]] && [ -z "$thinking" ]; } || { [[ "$orig" == *'{{effort}}'* ]] && [ -z "$effort" ]; }; then
        rst_fail_cls="${rst_fail_cls:-restore-empty-value}"
        ev="$(printf '%s' "$ev" | jq --arg e "restore '$orig' references a value that is not configured (model='${model:-}', thinking='${thinking:-}', effort='${effort:-}') — never sent; a bare command would open a picker, fail closed" '. + [$e]')"
        continue
      fi
      cmd="${cmd//\{\{model\}\}/$model}"; cmd="${cmd//\{\{thinking\}\}/$thinking}"; cmd="${cmd//\{\{effort\}\}/$effort}"
      cmd="$(printf '%s' "$cmd" | sed 's/[[:space:]]\{2,\}/ /g; s/[[:space:]]*$//')"
      case "$cmd" in *'{{'*) continue;; esac
      pane_send_line "$pane" "$cmd" "$send" && rst_applied=true || rst_fail_cls="${rst_fail_cls:-send-failure}"
      sleep "$settle"
    done < <(printf '%s\n' "$restore")
  fi

  # evidence 2 — modal check (I4): the screen is read AFTER the restore, and BEFORE the probe: a picker or
  # permission dialog is not clean whatever the footer said — 5090's `No matching models` picker was live
  # while its status line still matched the model name (the false CLEAN of 2026-09-08) — and the probe
  # text must never be typed into an open picker (the r1 pointer ended up in its search box).
  modal="$(printf '%s' "$(pane_screen "$pane")" | screen_modal_class)"
  if [ -n "$modal" ]; then
    rst_fail_cls="${rst_fail_cls:-$modal}"
    ev="$(printf '%s' "$ev" | jq --arg e "pane is in a $modal state after restore — not clean (I4); probe skipped" '. + [$e]')"
  fi

  # evidence 3 — the isolation probe: ask the agent itself what it still remembers. Skipped when a modal
  # holds the pane (there is nowhere for the probe to land): the modal alone fails the verdict closed.
  if [ -z "$modal" ] && [ "$(printf '%s' "$spec" | jq -r 'if (.verify | type) == "object" and (.verify | has("probe")) then (.verify.probe|tostring) else "true" end')" = true ]; then
    probe_out="${PANEL_RESET_DIR}/probe-${label}.txt"; mkdir -p "$PANEL_RESET_DIR"
    if reset_probe "$label" "$pane" "$kind" "$marker" "$probe_out"; then
      probe_ans="$(tr -d '\r' < "$probe_out" | head -3)"
      if [ -n "$marker" ] && printf '%s' "$probe_ans" | grep -qF -- "$marker"; then
        probe_ok=false; ev="$(printf '%s' "$ev" | jq --arg e "isolation probe RECALLED the previous task marker '$marker' — the conversation was NOT cleared" '. + [$e]')"
      elif printf '%s' "$probe_ans" | grep -q 'NO_PRIOR_CONTEXT'; then
        probe_ok=true; ev="$(printf '%s' "$ev" | jq --arg e "isolation probe answered NO_PRIOR_CONTEXT" '. + [$e]')"
      else
        probe_ok=false; ev="$(printf '%s' "$ev" | jq --arg e "isolation probe answered '$(printf '%s' "$probe_ans" | head -1 | cut -c1-120)' — not a proof of a fresh conversation" '. + [$e]')"
      fi
    else
      ev="$(printf '%s' "$ev" | jq --arg e "isolation probe produced no answer within ${PANEL_RESET_PROBE_TIMEOUT_S}s" '. + [$e]')"
    fi
  fi

  # verdict — fail closed: a modal on screen, a failed probe/footer, or a restore command that was
  # never sent is NOT clean; only positive evidence (probe or footer) verifies
  if [ "$probe_ok" = false ] || [ "$footer_ok" = false ] || [ -n "$rst_fail_cls" ]; then verdict=failed; reason="reset FAILED — $(printf '%s' "$ev" | jq -r 'join("; ")')"
  elif [ "$probe_ok" = true ] || [ "$footer_ok" = true ]; then verdict=verified; reason="reset verified — $(printf '%s' "$ev" | jq -r 'join("; ")')"
  else verdict=unverified; reason="reset UNVERIFIED — no footer and no probe answer; isolation could not be proven, so this pane is not eligible for r1"; fi

  # model confirmation (I5) — only when a model is configured. Modal-aware: the status-line match can
  # NEVER confirm while a picker/dialog holds the pane (5090's grep matched the old model name inside
  # the open `No matching models` picker); a modal short-circuits to failure with no confirm keystrokes.
  if [ -n "$model" ] && [ "$verdict" != failed ]; then
    mshort="${model##*/}"
    while :; do
      modal="$(printf '%s' "$(pane_screen "$pane")" | screen_modal_class)"
      if [ -n "$modal" ]; then rst_verified=false; break; fi
      if printf '%s' "$(pane_status_line "$pane")" | grep -qF -- "$mshort"; then rst_verified=true; break; fi
      [ "$tries" -ge "${PANEL_RESTORE_CONFIRMS:-3}" ] && { rst_verified=false; break; }
      pane_confirm_enter "$pane" || true   # the restore command opened a selection list: confirm it, then RE-READ (guarded: one pane's keystroke failure must not abort the reset)
      tries=$((tries + 1)); sleep "$settle"
    done
    if [ "$rst_verified" != true ]; then
      # never leave a half-open picker behind; then one FINAL re-read — the screen, never the keystroke count, decides
      pane_dismiss_modal "$pane"
      modal="$(printf '%s' "$(pane_screen "$pane")" | screen_modal_class)"
      if [ -z "$modal" ] && printf '%s' "$(pane_status_line "$pane")" | grep -qF -- "$mshort"; then rst_verified=true
      else
        verdict=failed; rst_fail_cls="${rst_fail_cls:-model-restore-unconfirmed}"
        reason="reset FAILED — the configured model '$model' could not be confirmed on the pane after restore — not eligible for r1 (fail closed)"
        ev="$(printf '%s' "$ev" | jq --arg e "model restore NOT confirmed on screen (looked for '$mshort'${modal:+, pane in $modal})" '. + [$e]')"
      fi
    fi
    [ "$rst_verified" = true ] && ev="$(printf '%s' "$ev" | jq --arg e "model '$model' confirmed on the pane's status line after restore" '. + [$e]')"
  fi
  if [ "$rst_verified" = true ]; then observed_model="$model"; fi

  reset_state_set "$label" '.reset_attempted=true | .reset_failed=($v|not) | .reset_at=$t | .reset_session=$s | .reset_verified=$v | .reset_reason=$r
      | .footer_after=$fa | .evidence=$ev | .probe_ok=$p | .footer_ok=$f
      | .restore_applied=$ra | .restore_verified=$rv | .model=$m | .observed_model=$om | .thinking=$th | .effort=$ef
      | (if $v then (.used_by_session=null | .used_marker=null | .reset_failed=false) else . end)
      | .eligible_r1=$v
      | (if $fc != "" then .reset_failure_class=$fc else . end)' \
    --arg t "$(now_iso)" --arg s "$sid" --argjson v "$([ "$verdict" = verified ] && echo true || echo false)" --arg r "$reason" \
    --arg fa "$fa" --argjson ev "$ev" --arg p "$probe_ok" --arg f "$footer_ok" \
    --argjson ra "$rst_applied" --arg rv "$rst_verified" --arg m "$model" --arg om "$observed_model" --arg th "$thinking" --arg ef "$effort" --arg fc "$rst_fail_cls"

  [ -n "$d" ] && transcript "$d" reset "$label ($pane, $kind): $reason" || true
  [ "$verdict" = verified ]
}
