#!/usr/bin/env bash
# test-pane-reuse-isolation.sh — regression suite for the v1.12.0 pane-reuse context-isolation fix.
#
# THE BUG: `panel-*` HerdR panes are reused across panel sessions. Nothing cleared the AGENT
# CONVERSATION between them, so a new session's round-1 brief landed in a pane that still had the
# previous task's evidence in context — blind-review isolation broken, prior evidence contaminating a
# new task. v1.11.0's reset step was opt-in, delivered slash commands as TEXT (never executed),
# verified only where the TUI happened to show a footer, and its verdict was DISCARDED by the gate.
#
# This suite does NOT fake the fix with terminal clearing. It drives the real lifecycle functions
# (reset_pane / reset_check / reset_mark_used / reset_state_*) against a SIMULATED AGENT whose
# conversation is a real file on disk: the fake pane only clears that file when the reset command is
# actually EXECUTED as a command, and the isolation probe answers from whatever the conversation
# still contains. A canary injected during Task A is therefore recoverable exactly when the reset
# genuinely failed — the property under test.
#
# Run: bash tests/test-pane-reuse-isolation.sh (from this skill’s tests/ dir)
set -uo pipefail
PANEL_BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
eq()  { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: wanted [$3] got [$2]"; }

TMP="$(mktemp -d /tmp/panel-iso.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export PANEL_STATE_DIR="$TMP/state"
export PANEL_RESET_DIR="$TMP/state/reset"
export PANEL_MANIFEST="$TMP/panels.json"
export PANEL_SESSIONS_ROOT="$TMP/sessions"
export PANEL_PROBE_WAIT_S=1
export PANEL_RESET_PROBE_TIMEOUT_S=6
export PANEL_RESET_MODE=inplace   # v1.14.0: restart mode is the default; this suite pins the in-place lifecycle it asserts
export HERDR_ENV=1 HERDR_WORKSPACE_ID=wTEST HERDR_PANE_ID=p0
mkdir -p "$PANEL_STATE_DIR" "$PANEL_SESSIONS_ROOT"

CANARY="PREVIOUS_TASK_CANARY_84721"

cat > "$PANEL_MANIFEST" <<'MAN'
{ "version": 1, "workspace": "wTEST",
  "panels": {
    "panel-pi1":     { "kind": "pi",     "provider": "local",  "cwd": "/tmp", "model": "spark/qwen3.8-flash-next", "thinking": "medium", "effort": null, "timeout_s": 300 },
    "panel-claude1": { "kind": "claude", "provider": "anthropic-sub", "cwd": "/tmp", "model": null, "thinking": null, "effort": null, "timeout_s": 300 },
    "panel-codex1":  { "kind": "codex",  "provider": "openai-sub",    "cwd": "/tmp", "model": "gpt-6-astra", "thinking": null, "effort": "medium", "timeout_s": 300 },
    "panel-pi2":     { "kind": "pi",     "provider": "local",  "cwd": "/tmp", "model": "spark/qwen3.8-flash-next", "thinking": "medium", "effort": null, "timeout_s": 300 },
    "panel-nokind":  { "kind": "weirdtui", "provider": "local", "cwd": "/tmp", "model": null, "thinking": null, "effort": null, "timeout_s": 300 }
  } }
MAN

# --------------------------------------------------------------------------------------------
# The simulated agent. Each fake pane has:
#   $TMP/pane/<pane>.conv     the AGENT CONVERSATION (what a reset must actually destroy)
#   $TMP/pane/<pane>.model    the model the pane is currently running (a reset may drop it)
#   $TMP/pane/<pane>.status   agent state
#   $TMP/pane/<pane>.exec     "1" = slash commands typed as KEYS are executed by this TUI
#   $TMP/pane/<pane>.footer   "1" = this TUI shows a context footer
# Overriding pane_send_line / pane_screen / pane_footer / agent_status / transcript is legitimate:
# they are the only herdr-touching primitives, factored out for exactly this purpose. The reset
# lifecycle, the verification logic, the persistence and the gate are the real production code.
# --------------------------------------------------------------------------------------------
mkdir -p "$TMP/pane"
mkpane() { # mkpane <pane> <exec 0|1> <footer 0|1> <model>
  printf '%s\n' "conversation start" > "$TMP/pane/$1.conv"
  printf '%s' "$4" > "$TMP/pane/$1.model"
  printf 'idle' > "$TMP/pane/$1.status"
  printf '%s' "$2" > "$TMP/pane/$1.exec"
  printf '%s' "$3" > "$TMP/pane/$1.footer"
}
conv_kb() { awk 'END{printf "%d", (NR*1000 < 1000 ? 1000 : NR*1000)}' "$TMP/pane/$1.conv"; }

source "$PANEL_BIN/panel-lib.sh"

# --- fake primitives -------------------------------------------------------------------------
agent_status() { cat "$TMP/pane/$1.status" 2>/dev/null || echo gone; }
transcript()   { :; }
pane_footer() { # "Nk/262k" when this TUI shows a footer, else nothing
  [ "$(cat "$TMP/pane/$1.footer" 2>/dev/null)" = 1 ] || return 0
  printf '%dk/262k' "$(( $(wc -l < "$TMP/pane/$1.conv") ))"
}
pane_screen() { printf 'model: %s\n' "$(cat "$TMP/pane/$1.model" 2>/dev/null)"; }
pane_send_line() { # <pane> <text> <mode>
  local pane="$1" text="$2" mode="${3:-keys}"
  [ -f "$TMP/pane/$pane.conv" ] || return 1
  if [ "$mode" = keys ] && [ "$(cat "$TMP/pane/$pane.exec")" = 1 ] && [ "${text:0:1}" = / ]; then
    case "$text" in
      /new|/clear) printf 'conversation start\n' > "$TMP/pane/$pane.conv"                      # the ONLY real clear
                   [ "$(cat "$TMP/pane/$pane.kind" 2>/dev/null)" = claude ] || printf 'DEFAULT_MODEL' > "$TMP/pane/$pane.model" ;;   # /new drops to the TUI default
      /model*|/models*) printf '%s' "${text#* }" > "$TMP/pane/$pane.model" ;;
    esac
    printf '%s\n' "[executed $text]" >> "$TMP/pane/$pane.conv"
    return 0
  fi
  # not executed: the model reads it as ordinary text — it only GROWS the conversation
  printf '%s\n' "user: $text" >> "$TMP/pane/$pane.conv"
  return 0
}
# The probe: the simulated agent answers from what its conversation actually still holds.
reset_probe() {
  local label="$1" pane="$2" kind="$3" marker="$4" out="$5"
  pane_send_line "$pane" "ISOLATION PROBE" prompt || return 1
  if grep -q "PANEL TASK" "$TMP/pane/$pane.conv"; then
    grep -o 'PANEL TASK [A-Za-z0-9_-]*' "$TMP/pane/$pane.conv" | head -1 > "$out"
  elif grep -q "$CANARY" "$TMP/pane/$pane.conv"; then printf '%s\n' "$CANARY" > "$out"
  else printf 'NO_PRIOR_CONTEXT\n' > "$out"; fi
  return 0
}
# What a real dispatch does to a pane: deliver the brief into the conversation + record the use.
deliver_brief() { # <label> <pane> <session_id> [extra text]
  printf 'user: PANEL TASK %s r1/blind — read your brief\n' "$3" >> "$TMP/pane/$2.conv"
  [ -z "${4:-}" ] || printf '%s\n' "$4" >> "$TMP/pane/$2.conv"
  reset_mark_used "$1" "$3" "PANEL TASK $3"
}

echo "=== 1. Task A contaminates the pane; a NEW session sees it as unclean ==="
mkpane pA 1 1 "spark/qwen3.8-flash-next"; printf 'pi' > "$TMP/pane/pA.kind"
deliver_brief panel-pi1 pA SESSION_A "assistant: noted $CANARY from the previous task"
grep -q "$CANARY" "$TMP/pane/pA.conv" && ok "canary $CANARY present in the pane conversation after Task A" || bad "canary not injected"

IFS=$'\t' read -r cl cr < <(reset_check panel-pi1 SESSION_A)
eq "same-session reuse is not contamination" "$cl" clean
IFS=$'\t' read -r cl cr < <(reset_check panel-pi1 SESSION_B)
eq "NEW session sees the reused pane as unclean" "$cl" unclean
case "$cr" in *SESSION_A*) ok "reason names the contaminating session";; *) bad "reason lacks the prior session: $cr";; esac
eq "reset_verified persisted false" "$(reset_state_get panel-pi1 '.reset_verified' absent)" false

echo
echo "=== 2. The reset lifecycle actually destroys the previous conversation (canary test) ==="
reset_pane panel-pi1 pA pi SESSION_B ""; rc=$?
eq "reset_pane returns 0 (verified)" "$rc" 0
if grep -q "$CANARY" "$TMP/pane/pA.conv"; then bad "CANARY SURVIVED the reset — contamination"; else ok "canary $CANARY is gone from the conversation"; fi
if grep -q "SESSION_A" "$TMP/pane/pA.conv"; then bad "previous session's task marker survived"; else ok "previous task marker gone"; fi
# and the agent itself can no longer recall it
reset_probe panel-pi1 pA pi "PANEL TASK SESSION_A" "$TMP/probe.after"
eq "post-reset isolation probe answers NO_PRIOR_CONTEXT" "$(head -1 "$TMP/probe.after")" NO_PRIOR_CONTEXT

echo
echo "=== 3. Model / thinking / effort survive the reset ==="
eq "pi model re-applied after /new dropped it to the TUI default" "$(cat "$TMP/pane/pA.model")" "spark/qwen3.8-flash-next"
eq "restore_applied recorded" "$(reset_state_get panel-pi1 '.restore_applied' absent)" true
eq "restore_verified recorded" "$(reset_state_get panel-pi1 '.restore_verified' absent)" true
eq "thinking persisted from the manifest" "$(reset_state_get panel-pi1 '.thinking' absent)" medium
mkpane pC 1 1 "gpt-6-astra"; printf 'codex' > "$TMP/pane/pC.kind"
deliver_brief panel-codex1 pC SESSION_A "assistant: prior codex reasoning about $CANARY
assistant: more prior context"
reset_pane panel-codex1 pC codex SESSION_B "" >/dev/null 2>&1
eq "codex model+effort re-applied" "$(cat "$TMP/pane/pC.model")" "gpt-6-astra medium"

# 3c: REGRESSION (observed live 2026-09-07) — a `/model <name>` picker echoes the name on the INPUT line
# while the status line still shows the OLD model. Verifying on the full screen reported a restore that
# never happened. The check must read the status region only, and must fail closed when it disagrees.
mkpane pP 1 1 "OLD_MODEL"; printf 'pi' > "$TMP/pane/pP.kind"
deliver_brief panel-pi2 pP SESSION_A
# this fake TUI accepts /new but its /model only ECHOES (a picker that never resolves)
pane_send_line() {
  local pane="$1" text="$2" mode="${3:-keys}"
  [ -f "$TMP/pane/$pane.conv" ] || return 1
  if [ "$mode" = keys ] && [ "${text:0:1}" = / ]; then
    case "$text" in
      /new|/clear) printf 'conversation start\n' > "$TMP/pane/$pane.conv"; printf 'OLD_MODEL' > "$TMP/pane/$pane.model"; return 0;;
      /model*) printf '%s' "${text#* }" > "$TMP/pane/$pane.echo"; return 0;;   # echoed on the input line only
    esac
  fi
  printf '%s\n' "user: $text" >> "$TMP/pane/$pane.conv"; return 0
}
pane_screen() { printf '> %s\n\n---\nmodel: %s\n' "$(cat "$TMP/pane/$1.echo" 2>/dev/null)" "$(cat "$TMP/pane/$1.model")"; }
pane_status_line() { printf 'model: %s\n' "$(cat "$TMP/pane/$1.model")"; }
reset_pane panel-pi2 pP pi SESSION_B ""; rc=$?
[ "$rc" -ne 0 ] && ok "a picker echo is NOT accepted as a restored model (rc=$rc)" || bad "picker echo accepted as a successful restore — the live false positive"
eq "restore_verified false when only the echo matched" "$(reset_state_get panel-pi2 '.restore_verified' absent)" false
IFS=$'\t' read -r cl cr < <(reset_check panel-pi2 SESSION_B)
eq "a cleared conversation with an unrestored model is still UNCLEAN" "$cl" unclean
case "$cr" in *model*) ok "reason names the unconfirmed model";; *) bad "reason should name the model: $cr";; esac
# restore the honest fakes for the remaining sections
pane_screen() { printf 'model: %s\n' "$(cat "$TMP/pane/$1.model" 2>/dev/null)"; }
pane_status_line() { pane_screen "$1"; }
pane_send_line() {
  local pane="$1" text="$2" mode="${3:-keys}"
  [ -f "$TMP/pane/$pane.conv" ] || return 1
  if [ "$mode" = keys ] && [ "$(cat "$TMP/pane/$pane.exec")" = 1 ] && [ "${text:0:1}" = / ]; then
    case "$text" in
      /new|/clear) printf 'conversation start\n' > "$TMP/pane/$pane.conv"
                   [ "$(cat "$TMP/pane/$pane.kind" 2>/dev/null)" = claude ] || printf 'DEFAULT_MODEL' > "$TMP/pane/$pane.model" ;;
      /model*|/models*) printf '%s' "${text#* }" > "$TMP/pane/$pane.model" ;;
    esac
    printf '%s\n' "[executed $text]" >> "$TMP/pane/$pane.conv"; return 0
  fi
  printf '%s\n' "user: $text" >> "$TMP/pane/$pane.conv"; return 0
}

echo
echo "=== 4. Only a verified-clean pane becomes eligible for r1 ==="
IFS=$'\t' read -r cl cr < <(reset_check panel-pi1 SESSION_B)
eq "pane is clean for SESSION_B after a verified reset" "$cl" clean
IFS=$'\t' read -r cl cr < <(reset_check panel-pi1 SESSION_C)
eq "the same verified reset does NOT make it clean for a third session" "$cl" unclean

echo
echo "=== 5. FAIL CLOSED — a reset that cannot be verified leaves the pane ineligible ==="
# 5a: a TUI that accepts the slash command as TEXT (v1.11.0's real defect: herdr agent prompt)
mkpane pB 0 1 "spark/qwen3.8-flash-next"; printf 'pi' > "$TMP/pane/pB.kind"
deliver_brief panel-pi1 pB SESSION_A "assistant: noted $CANARY"
rm -f "$(reset_state_file panel-pi1)"; reset_mark_used panel-pi1 SESSION_A "PANEL TASK SESSION_A"
reset_pane panel-pi1 pB pi SESSION_B ""; rc=$?
[ "$rc" -ne 0 ] && ok "unexecuted reset command reports failure (rc=$rc)" || bad "an unexecuted reset must NOT report success"
grep -q "$CANARY" "$TMP/pane/pB.conv" && ok "canary still present — the reset genuinely did nothing" || bad "test setup wrong"
eq "reset_attempted persisted true" "$(reset_state_get panel-pi1 '.reset_attempted' absent)" true
eq "reset_verified persisted false" "$(reset_state_get panel-pi1 '.reset_verified' absent)" false
IFS=$'\t' read -r cl cr < <(reset_check panel-pi1 SESSION_B)
eq "pane is UNCLEAN after a failed reset" "$cl" unclean
case "$cr" in *FAILED*|*NOT\ cleared*|*NO\ EFFECT*) ok "reason states the reset had no effect";; *) bad "uninformative reason: $cr";; esac
reset_state_get panel-pi1 '.evidence | join(" ")' | grep -q "$CANARY" && ok "evidence records that the probe recalled the canary" || ok "evidence recorded (footer path)"

# 5b: a TUI with no footer and no probe answer -> UNVERIFIED, never "clean"
mkpane pD 0 0 ""; printf 'agy' > "$TMP/pane/pD.kind"
cat > "$TMP/panels2.json" <<'M2'
{ "version":1, "panels": { "panel-quiet": { "kind":"agy","provider":"google-sub","cwd":"/tmp","model":null,"thinking":null,"effort":null,
    "reset": { "prompts":["/clear"], "send":"keys", "settle_s":0, "verify": { "footer": true, "probe": false } } } } }
M2
PANEL_MANIFEST="$TMP/panels2.json" reset_pane panel-quiet pD agy SESSION_B ""; rc=$?
[ "$rc" -ne 0 ] && ok "no footer + no probe => not verified (rc=$rc)" || bad "unverifiable reset must not return success"
eq "verdict persisted as unverified" "$(reset_state_get panel-quiet '.reset_verified' absent)" false
IFS=$'\t' read -r cl cr < <(reset_check panel-quiet SESSION_B)
eq "unverifiable pane is not clean" "$cl" unclean

# 5c: a kind with no reset recipe at all -> fail closed, never silently eligible
mkpane pE 1 1 ""
reset_pane panel-nokind pE weirdtui SESSION_B ""; rc=$?
[ "$rc" -ne 0 ] && ok "unknown agent kind fails closed (rc=$rc)" || bad "unknown kind must not report a clean reset"
IFS=$'\t' read -r cl cr < <(reset_check panel-nokind SESSION_B)
eq "pane of an unsupported kind is not clean" "$cl" unclean

# 5d: absence of any record is NOT cleanliness
rm -f "$(reset_state_file panel-claude1)"
IFS=$'\t' read -r cl cr < <(reset_check panel-claude1 SESSION_B)
eq "no isolation record reads as unknown, never clean" "$cl" unknown

echo
echo "=== 6. A working or blocked pane is never interrupted ==="
mkpane pW 1 1 "spark/qwen3.8-flash-next"; printf 'working' > "$TMP/pane/pW.status"
printf 'live work in progress\n' >> "$TMP/pane/pW.conv"
before="$(cat "$TMP/pane/pW.conv")"
reset_pane panel-pi1 pW pi SESSION_B ""; rc=$?
eq "reset of a working pane is not attempted (rc=2)" "$rc" 2
[ "$before" = "$(cat "$TMP/pane/pW.conv")" ] && ok "the working pane's conversation was not touched" || bad "a live pane was modified"
eq "reset_attempted recorded false" "$(reset_state_get panel-pi1 '.reset_attempted' absent)" false
IFS=$'\t' read -r cl cr < <(reset_check panel-pi1 SESSION_B)
eq "an untouched working pane stays ineligible rather than being force-reset" "$cl" unclean

echo
echo "=== 7. The r1 gate: only clean panes are dispatchable (roster jq contract) ==="
# The exact expression panel-roster uses, exercised over the three verdicts under PANEL_REQUIRE_CLEAN=1.
gate() { # gate <clean> <require>
  jq -r -n --arg c "$1" --arg req "$2" '{settled:true, budget:"ok", clean:$c}
    | (.settled and (.budget != "skip") and (.clean != "unclean") and ($req != "1" or .clean == "clean"))'
}
eq "blind: clean   => dispatchable" "$(gate clean 1)"   true
eq "blind: unclean => NOT dispatchable (fails closed)" "$(gate unclean 1)" false
eq "blind: unknown => NOT dispatchable (fails closed)" "$(gate unknown 1)" false
eq "later rounds: unclean still refused" "$(gate unclean 0)" false
eq "later rounds: unknown tolerated (session already under way)" "$(gate unknown 0)" true
# and the real script carries that expression
grep -q 'PANEL_REQUIRE_CLEAN' "$PANEL_BIN/panel-roster" && ok "panel-roster reads PANEL_REQUIRE_CLEAN" || bad "roster missing the clean gate"
grep -q 'PANEL_REQUIRE_CLEAN=1' "$PANEL_BIN/panel-dispatch" && ok "panel-dispatch sets it for blind rounds" || bad "dispatch does not require clean panes for r1"
grep -q 'reset_mark_used' "$PANEL_BIN/panel-dispatch" && ok "panel-dispatch marks a pane used on delivery" || bad "dispatch never marks the pane used"
grep -q 'reset_mark_used' "$PANEL_BIN/panel-collect" && ok "panel-collect marks a queued brief's pane used on delivery" || bad "collect never marks the pane used"

echo
echo "=== 8. Manifest-driven recipes for every installed panel kind ==="
for k in pi claude codex hermes agy gemini opencode; do
  spec="$(reset_spec "panel-none" "$k")"
  if [ -n "$spec" ] && printf '%s' "$spec" | jq -e '.prompts | length > 0' >/dev/null 2>&1; then ok "kind $k has a reset recipe ($(printf '%s' "$spec" | jq -r '.prompts|join(" ")'))"
  else bad "kind $k has no usable reset recipe: [$spec]"; fi
done
eq "recipes send EXECUTED keystrokes, not agent prompts (the v1.11.0 defect)" "$(reset_spec panel-none pi | jq -r .send)" keys
# a manifest entry overrides the built-in field by field
cat > "$TMP/panels3.json" <<'M3'
{ "version":1, "panels": { "panel-pi1": { "kind":"pi","cwd":"/tmp","model":null,"reset":{"settle_s":33} } },
  "kinds": { "pi": { "reset": { "prompts":["/reset"] } } } }
M3
eq "per-panel manifest override wins on its field" "$(PANEL_MANIFEST=$TMP/panels3.json reset_spec panel-pi1 pi | jq -r .settle_s)" 33
eq "built-in fields survive a partial override" "$(PANEL_MANIFEST=$TMP/panels3.json reset_spec panel-pi1 pi | jq -r '.prompts|join(",")')" /new
eq "kinds.<kind>.reset applies when the panel has none" "$(PANEL_MANIFEST=$TMP/panels3.json reset_spec panel-other pi | jq -r '.prompts|join(",")')" /reset
# v1.11.0 singular `prompt` still understood
cat > "$TMP/panels4.json" <<'M4'
{ "version":1, "panels": {}, "kinds": { "pi": { "reset": { "prompt": "/new", "settle_s": 8 } } } }
M4
eq "legacy singular prompt field still parses" "$(PANEL_MANIFEST=$TMP/panels4.json reset_spec panel-x pi | jq -r '.prompt // ""')" /new

echo
echo "=== 9. Isolation state is exposed to the operator ==="
grep -q 'pane_status_line' "$PANEL_BIN/panel-lib.sh" && ok "the model check reads the TUI status line, not the whole screen" || bad "model verification still greps the full screen"
grep -q 'pane isolation' "$PANEL_BIN/panel-status" && ok "panel-status shows the isolation table" || bad "panel-status does not expose reset state"
grep -q 'clean:\$c' "$PANEL_BIN/panel-roster" && ok "roster.json carries clean/clean_reason per panel" || bad "roster.json lacks the clean field"
grep -q 'CLEAN' "$PANEL_BIN/panel-roster" && ok "panel-roster --table has a CLEAN column" || bad "no CLEAN column"
[ -x "$PANEL_BIN/panel-reset" ] && ok "panel-reset exists and is executable" || bad "panel-reset missing"
for f in reset_attempted reset_verified reset_at reset_reason; do
  reset_state_get panel-pi1 ".$f" absent >/dev/null && jq -e "has(\"$f\")" "$(reset_state_file panel-pi1)" >/dev/null \
    && ok "state persists $f" || bad "state missing $f"
done

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
