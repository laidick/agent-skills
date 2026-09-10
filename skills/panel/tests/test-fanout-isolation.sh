#!/usr/bin/env bash
# test-fanout-isolation.sh — behavioral regression suite for the v1.12.3 dispatch/reset fan-out contract.
#
# WHAT THIS ADDS OVER test-pane-reuse-isolation.sh: that suite drives the reset LIFECYCLE functions
# (reset_pane / reset_check / reset_mark_used) directly — it never runs panel-dispatch or panel-reset.
# The four production failures of 2026-09-08 were CONTROL-FLOW failures: one participant's reset or
# dispatch aborting the whole fan-out, a partial round returning rc 0, a genuinely fresh pane reset
# into a false failure, r1 text typed into a model picker. Those live in the scripts' own loops, so
# this suite drives the REAL panel-dispatch / panel-reset fan-outs against a simulated herdr pane
# fleet and asserts exact exit codes and per-participant outcomes:
#   Test D — a pane in a model picker: brief withheld (I4), others still dispatch
#   Test E — a blocked participant: recorded, not interrupted, others continue (rule 8)
#   Test F — three participants, B's delivery fails: C still receives its work (the set -e regression)
#   Test G — every participant fails: correct not-dispatched status, no false "running" claim
#   Test H — a genuinely fresh pane: reset verifies without a false failure, r1 accepted
#
# The fleet: a fake `herdr` earlier on PATH. Every pane is a file-backed state machine (conversation,
# model, footer, modal class, agent_status) — a canary in a pane's conversation is recoverable exactly
# when dispatch genuinely typed r1 text into it, and the isolation probe answers from what the
# conversation still holds (the same trick as test-pane-reuse-isolation.sh, one level up).
#
# Run: bash tests/test-fanout-isolation.sh
set -uo pipefail
PANEL_BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
eq()  { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: wanted [$3] got [$2]"; }
jget() { jq -r "if has(\"$2\") then (.\"$2\"|tostring) else \"absent\" end" "$1"; }   # jq `//` swallows false — read explicitly

TMP="$(mktemp -d /tmp/panel-fanout.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state/reset" "$TMP/sessions" "$TMP/fleet"
export PANEL_STATE_DIR="$TMP/state"
export PANEL_RESET_DIR="$TMP/state/reset"
export PANEL_MANIFEST="$TMP/panels.json"
export PANEL_SESSIONS_ROOT="$TMP/sessions"
export PANEL_RESET_MODE=inplace   # v1.14.0: restart mode is the default; these suites pin the in-place lifecycle they assert
export PANEL_RESET_SETTLE_S=0
export PANEL_SEND_SETTLE_S=0
export PANEL_PROBE_WAIT_S=1
export PANEL_RESET_PROBE_TIMEOUT_S=2
export PANEL_FRESH_FLOOR_K=32
export HERDR_ENV=1 HERDR_WORKSPACE_ID=wTEST HERDR_PANE_ID=p0
export FLEET="$TMP/fleet"
export PATH="$TMP/bin:$PATH"

# --- the pane fleet -----------------------------------------------------------------------------
# Each pane: <pane>.conv (conversation), .model, .status (agent_status), .modal (modal class or empty),
# .footer (context footer). labels.json maps panel-X -> pane pX.
mkpane() { # mkpane <pane> [model] [status]
  printf 'conversation start\n' > "$FLEET/$1.conv"
  printf '%s' "${2:-DEFAULT_MODEL}" > "$FLEET/$1.model"
  printf '%s' "${3:-idle}" > "$FLEET/$1.status"
  printf '%s' '' > "$FLEET/$1.modal"
  printf '%s' '0k/262k' > "$FLEET/$1.footer"
}

# --- the fake herdr ------------------------------------------------------------------------------
# Production argument shapes (pane id / text / key are $3/$4/$4):
#   herdr pane list --workspace W            -> panes from labels.json (all idle)
#   herdr pane read PANE --source visible    -> the rendered screen: conv tail, footer, THEN the model
#                                              status line last (the real TUI's bottom status bar)
#   herdr pane send-text PANE TEXT           -> a "/" command parks in .pending (waits for Enter);
#                                              anything else lands in .conv (r1 delivery = canary test)
#   herdr pane send-keys PANE Enter|Escape   -> Enter EXECUTES a pending slash command (/new clears the
#                                              conversation and drops the model to the TUI default;
#                                              /model sets it); Escape closes a modal
#   herdr agent get PANE                     -> agent_status from .status
#   herdr agent prompt PANE TEXT             -> lands in .conv; the isolation probe is ANSWERED from
#                                              what .conv still holds; panes listed in $FLEET/dead fail
cat > "$TMP/bin/herdr" <<'HERDR'
#!/usr/bin/env bash
[ -n "${FLEET:-}" ] || { echo "herdr: FLEET unset" >&2; exit 2; }
pf() { printf '%s/%s' "$FLEET" "$1"; }

case "$1 $2" in
  "pane list")
    jq -n --slurpfile labels "$FLEET/labels.json" \
      '{result:{panes:($labels[0] | to_entries | map({label:.key, pane_id:.value, agent:"pi", agent_status:"idle", cwd:"/tmp"}))}}'
    exit 0
    ;;
  "pane read")
    pane="$3"; modal="$(cat "$(pf "$pane").modal" 2>/dev/null)"
    model="$(cat "$(pf "$pane").model" 2>/dev/null)"; status="$(cat "$(pf "$pane").status" 2>/dev/null)"
    conv="$(tail -5 "$(pf "$pane").conv" 2>/dev/null)"; footer="$(cat "$(pf "$pane").footer" 2>/dev/null)"
    case "$modal" in
      picker)     printf 'No matching models · Enter to select\n─ model picker ─\n%s\n%s\n' "$conv" "$footer";;
      permission) printf 'Allow once / Always · approve this action?\n%s\n%s\n' "$conv" "$footer";;
      *)          printf '%s\n%s\nmodel: %s (%s)\n' "$conv" "$footer" "$model" "$status";;
    esac
    exit 0
    ;;
  "pane send-text")
    pane="$3"; text="$4"
    case "$text" in
      /*) printf '%s' "$text" > "$(pf "$pane").pending"; printf '%s\n' "typed: $text" >> "$(pf "$pane").conv";;
      *)  printf '%s\n' "$text" >> "$(pf "$pane").conv";;
    esac
    exit 0
    ;;
  "pane send-keys")
    pane="$3"; key="$4"
    if [ "$key" = Enter ] && [ -s "$(pf "$pane").pending" ]; then
      cmd="$(cat "$(pf "$pane").pending")"; rm -f "$(pf "$pane").pending"
      case "$cmd" in
        /new|/clear)      printf 'conversation start\n' > "$(pf "$pane").conv"; printf 'DEFAULT_MODEL' > "$(pf "$pane").model";;
        /model*|/models*) printf '%s' "${cmd#* }" > "$(pf "$pane").model";;
      esac
    fi
    if [ "$key" = Escape ]; then printf '%s' '' > "$(pf "$pane").modal"; fi
    exit 0
    ;;
  "agent get")
    pane="$3"; st="$(cat "$(pf "$pane").status" 2>/dev/null || printf none)"
    jq -n --arg s "$st" '{result:{agent:{agent_status:$s}}}'
    exit 0
    ;;
  "pane get")
    pane="$3"; [ -f "$(pf "$pane").status" ]; exit $?
    ;;
  "agent prompt")
    pane="$3"; text="$4"
    if [ -s "$FLEET/dead" ] && grep -qxF "$pane" "$FLEET/dead" 2>/dev/null; then
      printf '{"error":{"code":"agent_prompt_stalled"}}\n' >&2; exit 1
    fi
    # the isolation probe answers from what the conversation held BEFORE this prompt lands —
    # answering after the append would self-match the probe text ("the PANEL TASK you were working on"),
    # and probe lines from earlier probes are excluded for the same reason.
    case "$text" in
      "ISOLATION PROBE"*)
        out="$(printf '%s' "$text" | grep -oE 'Write [^ ]+' | head -1)"; out="${out#Write }"
        if [ -n "$out" ]; then
          held="$(grep -v 'user: ISOLATION PROBE' "$(pf "$pane").conv" 2>/dev/null)"
          if printf '%s' "$held" | grep -q "PANEL TASK"; then
            printf '%s' "$held" | grep -o 'PANEL TASK [A-Za-z0-9_-]*' | head -1 > "$out"
          elif printf '%s' "$held" | grep -q "PREVIOUS_TASK_CANARY"; then
            printf 'PREVIOUS_TASK_CANARY_84721\n' > "$out"
          else
            printf 'NO_PRIOR_CONTEXT\n' > "$out"
          fi
        fi
        ;;
    esac
    printf 'user: %s\n' "$text" >> "$(pf "$pane").conv"
    exit 0
    ;;
  *) echo "herdr: unhandled: $*" >&2; exit 2;;
esac
HERDR
chmod +x "$TMP/bin/herdr"

# --- manifest + sessions ------------------------------------------------------------------------
cat > "$PANEL_MANIFEST" <<'MAN'
{ "version": 1, "workspace": "wTEST",
  "panels": {
    "panel-a": { "kind": "pi", "provider": "local", "cwd": "/tmp", "model": "spark/qwen3.8-flash-next", "thinking": "medium", "effort": null, "timeout_s": 60,
                 "reset": { "settle_s": 0 } },
    "panel-b": { "kind": "pi", "provider": "local", "cwd": "/tmp", "model": "spark/qwen3.8-flash-next", "thinking": null, "effort": null, "timeout_s": 60,
                 "reset": { "settle_s": 0 } },
    "panel-c": { "kind": "pi", "provider": "local", "cwd": "/tmp", "model": "spark/qwen3.8-flash-next", "thinking": null, "effort": null, "timeout_s": 60,
                 "reset": { "settle_s": 0 } }
  } }
MAN
jq -n '{ "panel-a": "pa", "panel-b": "pb", "panel-c": "pc" }' > "$FLEET/labels.json"
mkpane pa; mkpane pb; mkpane pc

mk_session() { # mk_session <name> -> dir with a filled charter
  local d="$PANEL_SESSIONS_ROOT/$1"; mkdir -p "$d/rounds"
  jq -n --arg id "$1" '{session_id:$id, state:"intake", max_rounds:3}' > "$d/session.json"
  printf '# Charter\n\n## Problem\nDecide the fan-out isolation policy.\n\n## Questions\nQ1. Is per-pane isolation enforced?\n' > "$d/charter.md"
  printf '# Panel session %s — transcript\n' "$1" > "$d/transcript.md"
  echo "$d"
}

echo "=== Test H — a genuinely fresh pane resets clean (no false failure) ==="
# Brand-new pane: footer at the fresh baseline (0k/262k — nothing to drop), probe answers NO_PRIOR_CONTEXT.
dH="$(mk_session fanout-h)"
rm -f "$PANEL_RESET_DIR"/panel-*.json
"$PANEL_BIN/panel-reset" "$dH" >"$TMP/h-reset.out" 2>&1; rcR=$?
eq "panel-reset on brand-new panes verifies them all clean" "$rcR" 0
eq "fresh pane reset_verified=true (footer at baseline is not negative evidence)" "$(jget "$PANEL_RESET_DIR/panel-a.json" reset_verified)" true
eq "fresh pane eligible_r1=true" "$(jget "$PANEL_RESET_DIR/panel-a.json" eligible_r1)" true
jq -r '.evidence[]' "$PANEL_RESET_DIR/panel-a.json" | grep -q "NO EFFECT" && bad "fresh pane misread as NO EFFECT (Test H regression)" || ok "no NO EFFECT false failure at the baseline footer"
"$PANEL_BIN/panel-dispatch" "$dH" blind >"$TMP/h.out" 2>&1; rcH=$?
eq "fresh panes dispatch rc=0 (blind r1 fan-out all-clean)" "$rcH" 0
grep -q "PANEL TASK" "$FLEET/pa.conv" && ok "r1 delivered to the fresh pane" || bad "fresh pane got no r1: $(tail -5 "$TMP/h.out")"

echo
echo "=== Test F — B's failure never aborts A and C (the set -e regression) ==="
# B's delivery fails (agent prompt stalls) — A and C must still receive their briefs; the round is PARTIAL (5).
dF="$(mk_session fanout-f)"
rm -f "$PANEL_RESET_DIR"/panel-*.json
mkpane pa; mkpane pb; mkpane pc
printf 'pb\n' > "$FLEET/dead"
"$PANEL_BIN/panel-dispatch" "$dF" blind >"$TMP/f.out" 2>&1; rcF=$?
rm -f "$FLEET/dead"
eq "partial fan-out exits 5 (PARTIAL — not 0, not a die)" "$rcF" 5
grep -q "PANEL TASK" "$FLEET/pa.conv" && ok "A received its brief after B failed" || bad "A was aborted by B's failure"
grep -q "PANEL TASK" "$FLEET/pc.conv" && ok "C received its brief after B failed (fan-out isolation)" || bad "C was aborted by B's failure — the 2026-09-08 regression"
jq -e '.state == "failed" or .state == "skipped"' "$dF/rounds/r1/meta/b.json" >/dev/null 2>&1 && ok "B's failure recorded in its meta" || bad "B's outcome not recorded"
grep -q "PARTIAL dispatch" "$dF/transcript.md" && ok "transcript records the PARTIAL dispatch" || bad "no PARTIAL record in transcript"

echo
echo "=== Test D — a picker withholds the brief and fails the reset (I4) ==="
dD="$(mk_session fanout-d)"
rm -f "$PANEL_RESET_DIR"/panel-*.json
mkpane pa; mkpane pb; mkpane pc
printf 'picker' > "$FLEET/pb.modal"    # B sits in a model picker (an observed opencode case)
"$PANEL_BIN/panel-dispatch" "$dD" blind >"$TMP/d.out" 2>&1; rcD=$?
printf '%s' '' > "$FLEET/pb.modal"
eq "picker pane: fan-out exits 5 (others reached)" "$rcD" 5
grep -q "PANEL TASK" "$FLEET/pa.conv" && ok "A dispatched while B sat in a picker" || bad "A aborted by B's picker"
grep -q "PANEL TASK" "$FLEET/pb.conv" && bad "r1 text typed INTO the picker (I4 violation)" || ok "no r1 text typed into B's picker"
mB="$(jq -r .state "$dD/rounds/r1/meta/b.json" 2>/dev/null)"
case "$mB" in skipped|failed) ok "B recorded as $mB";; *) bad "B's picker outcome not recorded: $mB";; esac
case "$(jget "$PANEL_RESET_DIR/panel-b.json" reset_failure_class)" in modal-*) ok "failure class names the modal ($(jget "$PANEL_RESET_DIR/panel-b.json" reset_failure_class))";; *) bad "reset_failure_class missing the modal class: $(jget "$PANEL_RESET_DIR/panel-b.json" reset_failure_class)";; esac
eq "picker pane is not eligible for r1" "$(jget "$PANEL_RESET_DIR/panel-b.json" eligible_r1)" false

echo
echo "=== Test E — a blocked participant is never interrupted; others dispatch ==="
dE="$(mk_session fanout-e)"
rm -f "$PANEL_RESET_DIR"/panel-*.json
mkpane pa; mkpane pb; mkpane pc
printf 'blocked' > "$FLEET/pb.status"
beforeB="$(cat "$FLEET/pb.conv")"
"$PANEL_BIN/panel-dispatch" "$dE" blind >"$TMP/e.out" 2>&1; rcE=$?
printf 'idle' > "$FLEET/pb.status"
eq "blocked-participant round exits 5 (others reached)" "$rcE" 5
[ "$beforeB" = "$(cat "$FLEET/pb.conv")" ] && ok "the blocked pane's conversation was not touched" || bad "a blocked pane was modified"
grep -q "PANEL TASK" "$FLEET/pa.conv" && ok "A dispatched while B was blocked" || bad "A aborted by B's blocked state"
eq "B's reset not attempted (recorded)" "$(jget "$PANEL_RESET_DIR/panel-b.json" reset_attempted)" false

echo
echo "=== Test G — every participant fails: correct status, no false running ==="
dG="$(mk_session fanout-g)"
rm -f "$PANEL_RESET_DIR"/panel-*.json
mkpane pa; mkpane pb; mkpane pc
printf 'pa\npb\npc\n' > "$FLEET/dead"    # every send fails
"$PANEL_BIN/panel-dispatch" "$dG" blind >"$TMP/g.out" 2>&1; rcG=$?
rm -f "$FLEET/dead"
eq "all-fail fan-out exits 1 (nothing sent, rolled back)" "$rcG" 1
[ ! -d "$dG/rounds/r1" ] && ok "round dir removed on the all-fail dispatch" || bad "all-fail round dir survived"
grep -q "r1-blind-dispatched" "$dG/session.json" && bad "all-fail dispatch claimed running" || ok "no dispatched state claimed"
grep -q "nothing was sent" "$dG/transcript.md" && ok "transcript records the rollback" || bad "rollback not recorded"

echo
echo "=== Test A — prior-session canary destroyed by the lifecycle; r1 lands canary-free ==="
CANARY="PREVIOUS_TASK_CANARY_84721"
dA="$(mk_session fanout-a)"
rm -f "$PANEL_RESET_DIR"/panel-*.json
mkpane pa; mkpane pb; mkpane pc
printf 'assistant: noted %s from the previous task\n' "$CANARY" >> "$FLEET/pa.conv"
printf 'assistant: noted %s\n' "$CANARY" >> "$FLEET/pb.conv"
"$PANEL_BIN/panel-reset" "$dA" >"$TMP/a-reset.out" 2>&1; rcR=$?
eq "panel-reset fan-out resets every contaminated pane clean" "$rcR" 0
grep -q "$CANARY" "$FLEET/pa.conv" && bad "canary survived the reset lifecycle" || ok "canary destroyed by the reset lifecycle (panel-reset fan-out)"
eq "model restored from the manifest after /new" "$(cat "$FLEET/pa.model")" "spark/qwen3.8-flash-next"
"$PANEL_BIN/panel-dispatch" "$dA" blind >"$TMP/a.out" 2>&1; rcA2=$?
eq "post-reset blind dispatch (all clean now) exits 0" "$rcA2" 0
grep -q "$CANARY" "$FLEET/pa.conv" && bad "r1 delivered with the canary still in context" || ok "r1 delivered into a canary-free conversation"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
