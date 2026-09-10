#!/usr/bin/env bash
# test-escalation.sh — deterministic acceptance suite for the autonomous-escalation skill.
# Implements the 20 ratified acceptance checks plus extras. Run:
#   bash skills/autonomous-escalation/tests/test-escalation.sh
# Uses only temp dirs + a fake HOME; never touches the real $HOME or panel sessions.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
E="$REPO/skills/autonomous-escalation/bin/escalate"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
check(){ local desc="$1" want="$2" got="$3"; if [ "$want" = any ] || [ "$got" = "$want" ]; then ok "$desc (rc=$got)"; else bad "$desc: wanted rc=$want got rc=$got"; fi }
assert(){ local desc="$1" hay="$2" needle="$3"; if printf '%s' "$hay" | grep -qF -- "$needle"; then ok "$desc"; else bad "$desc (missing: $needle)"; fi }
negate(){ local desc="$1" hay="$2" needle="$3"; if printf '%s' "$hay" | grep -qF -- "$needle"; then bad "$desc (leaked: $needle)"; else ok "$desc"; fi }

TMP="$(mktemp -d /tmp/esc-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fresh() { # fresh <dir> <goal> [extra init args...] — new project root with state
  local d="$1" goal="$2"; shift 2
  rm -rf "$d"; mkdir -p "$d"; cd "$d"
  git init -q . 2>/dev/null || true
  printf 'frozen design v1\n' > design.md
  git add -A; git -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1 || true
  ESCALATE_ROOT="$d" bash "$E" init --goal "$goal" "$@" >/dev/null || { bad "init in $d"; return 1; }
  ESCALATE_ROOT="$d" bash "$E" baseline --file design.md >/dev/null
}
esc() { ESCALATE_ROOT="$1" bash "$E" "${@:2}"; }
escrc() { ESCALATE_ROOT="$1" bash "$E" "${@:2}" >/dev/null 2>&1; echo $?; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

D="$TMP/p"; fresh "$D" "ship the rate limiter"

echo "=== 1. first debugging failure does NOT escalate ==="
out="$(esc "$D" attempt --hypothesis "off-by-one in window math" --action "clamp the window" --result fail 2>&1)"; rc=$?
check "first failure stays NORMAL" 0 "$rc"
assert "state NORMAL after first failure" "$(esc "$D" status)" "state: NORMAL"

echo "=== 2. repeated identical command/patch does NOT count as distinct ==="
for i in 1 2; do esc "$D" attempt --hypothesis "off-by-one in window math" --action "clamp the window" --result fail >/dev/null; done
st="$(esc "$D" status)"
assert "still exactly 1 distinct attempt" "$st" "distinct_attempts: 1"
assert "no trigger from repeats" "$st" "state: NORMAL"

echo "=== 3. distinct unsuccessful hypotheses satisfy the trigger ==="
esc "$D" attempt --hypothesis "float rounding in window math" --action "use integer seconds" --result fail >/dev/null
out="$(esc "$D" attempt --hypothesis "counter overflow at window edge" --action "reset counter on rollover" --result fail 2>&1)"; rc=$?
check "third distinct failure triggers" 30 "$rc"
assert "state STALLED" "$st=$(esc "$D" status)" "state: STALLED"

echo "=== 4. measurable progress resets stuck state ==="
D2="$TMP/p4"; fresh "$D2" "goal4"
esc "$D2" attempt --hypothesis h1 --action a1 --result fail >/dev/null
esc "$D2" attempt --hypothesis h2 --action a2 --result fail >/dev/null
esc "$D2" attempt --hypothesis h3 --action a3 --result fail --progress "12 -> 5 failing tests" >/dev/null 2>&1
st="$(esc "$D2" status)"
assert "no-progress streak reset" "$st" "no_progress_streak: 0/2"
assert "fail streak reset" "$st" "fail_streak: 0/3"

echo "=== 5. implementation/debug issue routes to advisory reviewer class ==="
assert "default class is IMPLEMENTATION/DEBUG" "$(esc "$D" classify)" "IMPLEMENTATION/DEBUG"
esc "$D" packet --question "Why do window-edge tests fail?" >/dev/null 2>&1
assert "packet class advisory-hint" "$(cat "$D/.pi/help/esc-001.md")" "- requested_decision_type: advisory-hint"
check "advisory answer accepted" 0 "$(escrc "$D" answer esc-001 --kind advisory --text 'use integer math')"

echo "=== 6. architecture deviation routes to PANEL class ==="
D3="$TMP/p6"; fresh "$D3" "goal6"
esc "$D3" event --kind deviation --note "impl contradicts frozen design" >/dev/null 2>&1; rc=$?
check "deviation event is immediate (rc 30)" 30 "$rc"
assert "class ARCHITECTURE/PANEL" "$(esc "$D3" classify)" "ARCHITECTURE/PANEL"
esc "$D3" packet --question "May the parser buffer be redesigned?" >/dev/null 2>&1
assert "packet class panel" "$(cat "$D3/.pi/help/esc-001.md")" "- escalation_class: ARCHITECTURE/PANEL"

echo "=== 7. architecture path uses the visible panel contract, never hidden delegate_task ==="
check "authoritative WITHOUT panel evidence rejected" 2 "$(escrc "$D3" answer esc-001 --kind authoritative)"
mkdir -p "$TMP/sess"; printf '# Consensus\nRatified: redesign adopted.\n' > "$TMP/sess/consensus.md"
SHA="$(sha256_of "$TMP/sess/consensus.md")"
check "authoritative WITH panel evidence accepted" 0 "$(escrc "$D3" answer esc-001 --kind authoritative --panel-session "$TMP/sess" --panel-snapshot-sha "$SHA" --panel-outcome CONSENSUS)"
assert "record keeps snapshot sha evidence" "$(cat "$D3/.pi/escalations/esc-001.md")" "panel_snapshot_sha: $SHA"
skillmd="$(cat "$REPO/skills/autonomous-escalation/SKILL.md")"
assert "SKILL.md names the visible pipeline (panel-dispatch)" "$skillmd" "panel-dispatch"
assert "SKILL.md forbids hidden delegate_task as a panel" "$skillmd" "delegate_task"

echo "=== 8. external-current-fact uncertainty routes to research class ==="
D4="$TMP/p8"; fresh "$D4" "goal8"
esc "$D4" event --kind current-fact --note "provider API behavior contradicts remembered docs" >/dev/null 2>&1
assert "class EXTERNAL/RESEARCH" "$(esc "$D4" classify)" "EXTERNAL/RESEARCH"
esc "$D4" packet --question "Does v3 of the provider API still rate-limit at 60 rpm?" >/dev/null 2>&1
assert "decision type external-fact" "$(cat "$D4/.pi/help/esc-001.md")" "- requested_decision_type: external-fact"
check "external-evidence answer accepted" 0 "$(escrc "$D4" answer esc-001 --kind external-evidence --text 'v3 limits: 120 rpm per key (docs v3.2, checked today)')"
check "advisory kind rejected for research class" 2 "$(escrc "$D4" answer esc-001 --kind advisory --text no)"

echo "=== 9. credential/destructive authorization routes to human class ==="
D5="$TMP/p9"; fresh "$D5" "goal9"
esc "$D5" event --kind destructive --note "drop database prod required" >/dev/null 2>&1
assert "class HUMAN" "$(esc "$D5" classify)" "HUMAN"
esc "$D5" packet --question "May I drop database prod?" >/dev/null 2>&1
assert "decision type yes-no-authorization" "$(cat "$D5/.pi/help/esc-001.md")" "- requested_decision_type: yes-no-authorization"
check "human-authorization accepted" 0 "$(escrc "$D5" answer esc-001 --kind human-authorization --text 'yes, dev schema only')"
assert "authorization recorded durably" "$(cat "$D5/.pi/escalations/esc-001.md")" "kind: human-authorization"

echo "=== 10. bounded help packet contains required evidence ==="
D6="$TMP/p10"; fresh "$D6" "the original goal text"
esc "$D6" attempt --hypothesis "hypo-A" --action "fix-A" --result fail >/dev/null
esc "$D6" packet --question "The exact question here?" >/dev/null 2>&1
pkt="$(cat "$D6/.pi/help/esc-001.md")"
assert "goal present" "$pkt" "- goal: the original goal text"
assert "exact question present" "$pkt" "- exact_question: The exact question here?"
assert "class present" "$pkt" "- escalation_class: IMPLEMENTATION/DEBUG"
assert "question hash present" "$pkt" "- question_hash: "
assert "baseline ref present" "$pkt" "- baseline_ref: "
assert "attempt history present" "$pkt" "- hypo-A | fix-A | fail"
assert "git section present" "$pkt" "## git status"

echo "=== 11. secrets do not leak into the help packet ==="
D7="$TMP/p11"; fresh "$D7" "goal11"
esc "$D7" attempt --hypothesis "key ghp_ABCDEFghijkl1234567890abcdef1234567 is rotated" --action "token=supersecretvalue password=hunter2 AKIAIOSFODNN7EXAMPLE sk-abcdefghij1234567890abcd Bearer eyJhbGciOiOiOiOiXc" --result fail >/dev/null
esc "$D7" packet --question "auth: Bearer aaabbbcccddd112233445566 and secret: mydbpass" >/dev/null 2>&1
pkt="$(cat "$D7/.pi/help/esc-001.md")"
negate "github token redacted" "$pkt" "ghp_ABCDEFghijkl1234567890abcdef1234567"
negate "aws key id redacted" "$pkt" "AKIAIOSFODNN7EXAMPLE"
negate "sk- key redacted" "$pkt" "sk-abcdefghij1234567890abcd"
negate "password value redacted" "$pkt" "hunter2"
negate "bearer token redacted" "$pkt" "eyJhbGciOiOiOiOiXc"
negate "auth token in question redacted" "$pkt" "aaabbbcccddd112233445566"
assert "REDACTED marker present" "$pkt" "[REDACTED]"

echo "=== 12. duplicate same-question escalation is suppressed ==="
D8="$TMP/p12"; fresh "$D8" "goal12"
esc "$D8" attempt --hypothesis h1 --action a1 --result fail >/dev/null
esc "$D8" packet --question "Same question?" >/dev/null 2>&1
check "pending duplicate suppressed" 10 "$(escrc "$D8" packet --question 'Same question?')"

echo "=== 13. cooldown works ==="
esc "$D8" answer esc-001 --kind advisory --text hint >/dev/null
check "immediate re-escalation of answered question is in cooldown" 11 "$(escrc "$D8" packet --question 'Same question?')"
esc "$D8" attempt --hypothesis h2 --action a2 --result fail >/dev/null
check "after one full re-attempt cycle the same question may re-escalate" 0 "$(escrc "$D8" packet --question 'Same question?')"

echo "=== 14. depth > 1 is blocked (no reviewer -> reviewer fan-out) ==="
D9="$TMP/p14"; fresh "$D9" "goal14"
esc "$D9" attempt --hypothesis h1 --action a1 --result fail >/dev/null
check "depth-1 reviewer asking for another reviewer blocked" 12 "$(escrc "$D9" packet --question 'd?' --depth 1)"
check "depth-1 reviewer may still go HUMAN" 0 "$(escrc "$D9" packet --question 'd?' --depth 1 --class HUMAN)"

echo "=== 15. budget ceiling works ==="
D10="$TMP/p15"; fresh "$D10" "goal15" --set max_escalations_per_goal=2
esc "$D10" attempt --hypothesis h1 --action a1 --result fail >/dev/null
esc "$D10" packet --question q1 >/dev/null 2>&1
esc "$D10" answer esc-001 --kind advisory --text x >/dev/null
esc "$D10" attempt --hypothesis h2 --action a2 --result fail >/dev/null
esc "$D10" packet --question q2 >/dev/null 2>&1
esc "$D10" attempt --hypothesis h3 --action a3 --result fail >/dev/null
check "third escalation exhausts budget" 13 "$(escrc "$D10" packet --question q3)"
assert "state HUMAN_FALLBACK" "$(esc "$D10" status)" "state: HUMAN_FALLBACK"

echo "=== 16. stale response detected after state hash changes ==="
D11="$TMP/p16"; fresh "$D11" "goal16"
esc "$D11" attempt --hypothesis h1 --action a1 --result fail >/dev/null
esc "$D11" packet --question "q16?" >/dev/null 2>&1
echo "frozen design v2 (changed after the packet)" >> design.md
check "answer after baseline drift is STALE" 40 "$(escrc "$D11" answer esc-001 --kind advisory --text late)"
assert "record flags STALE" "$(cat "$D11/.pi/escalations/esc-001.md")" "STALE: baseline changed since packet"

echo "=== 17. advisory reviewer response does not become architecture authority ==="
D12="$TMP/p17"; fresh "$D12" "goal17"
before="$(esc "$D12" status | grep baseline_ref)"
esc "$D12" attempt --hypothesis h1 --action a1 --result fail >/dev/null
esc "$D12" packet --question "q17?" >/dev/null 2>&1
esc "$D12" answer esc-001 --kind advisory --text "just a hint" >/dev/null
after="$(esc "$D12" status | grep baseline_ref)"
[ "$before" = "$after" ] && ok "advisory answer leaves baseline untouched" || bad "advisory answer changed baseline"
esc "$D12" event --kind deviation --note n >/dev/null 2>&1
esc "$D12" attempt --hypothesis h3 --action a3 --result fail >/dev/null
esc "$D12" packet --question q17b >/dev/null 2>&1
check "advisory kind rejected for an ARCHITECTURE escalation" 2 "$(escrc "$D12" answer esc-002 --kind advisory --text no)"

echo "=== 18. ratified panel result CAN become the new authoritative baseline ==="
D13="$TMP/p18"; fresh "$D13" "goal18"
esc "$D13" event --kind deviation --note n >/dev/null 2>&1
esc "$D13" attempt --hypothesis h1 --action a1 --result fail >/dev/null
esc "$D13" packet --question "q18?" >/dev/null 2>&1
mkdir -p "$TMP/sess18"; printf '# Consensus\nNew baseline text.\n' > "$TMP/sess18/consensus.md"
SHA18="$(sha256_of "$TMP/sess18/consensus.md")"
check "authoritative panel answer recorded" 0 "$(escrc "$D13" answer esc-001 --kind authoritative --panel-session "$TMP/sess18" --panel-snapshot-sha "$SHA18" --panel-outcome CONSENSUS)"
st="$(esc "$D13" status)"
assert "baseline_ref is now the snapshot sha" "$st" "baseline_ref: $SHA18"
assert "state RESUMED under new baseline" "$st" "state: RESUMED"
assert "superseded pointer kept" "$(esc "$D13" status)" "baseline"

echo "=== 19. worker resume state points back to the original goal ==="
D14="$TMP/p19"; fresh "$D14" "the ORIGINAL long-run goal"
esc "$D14" attempt --hypothesis h1 --action a1 --result fail >/dev/null
esc "$D14" packet --question "q19?" >/dev/null 2>&1
esc "$D14" answer esc-001 --kind advisory --text hint >/dev/null
res="$(esc "$D14" resume)"
assert "resume names the original goal" "$res" "Original goal: the ORIGINAL long-run goal"
st="$(esc "$D14" status)"
assert "back to NORMAL after resume" "$st" "state: NORMAL"
assert "goal-state.md still carries the goal" "$(cat "$D14/.pi/goal-state.md")" "GOAL: the ORIGINAL long-run goal"

echo "=== 20. install/symlink/discovery ==="
FH="$TMP/fakehome"; mkdir -p "$FH/.pi/agent/skills"
out="$(HOME="$FH" bash "$REPO/install.sh" --check 2>&1)"
assert "--check discovers the skill" "$out" "autonomous-escalation"
out="$(HOME="$FH" bash "$REPO/install.sh" 2>&1)"; rc=$?
check "installer completes" 0 "$rc"
ln -sf "$REPO/skills/autonomous-escalation" "$TMP/canonical-resolve"
[ -L "$FH/.pi/agent/skills/autonomous-escalation" ] && ok "pi skill dir has the symlink" || bad "pi skill dir missing symlink"
got="$(readlink -f "$FH/.pi/agent/skills/autonomous-escalation" 2>/dev/null || true)"
want="$(readlink -f "$REPO/skills/autonomous-escalation")"
[ "$got" = "$want" ] && ok "symlink resolves to canonical source" || bad "symlink resolves to: $got (want $want)"
[ -f "$FH/.pi/agent/skills/autonomous-escalation/SKILL.md" ] && ok "SKILL.md reachable through the link" || bad "SKILL.md not reachable through link"

echo "=== extras ==="
# oscillation: identical attempt 4x = 2+ edit/revert loops
D15="$TMP/px"; fresh "$D15" "goalx"
esc "$D15" attempt --hypothesis h --action a --result fail >/dev/null
esc "$D15" attempt --hypothesis h --action a --result fail >/dev/null
esc "$D15" attempt --hypothesis h --action a --result fail >/dev/null
out="$(esc "$D15" attempt --hypothesis h --action a --result fail 2>&1)"; rc=$?
check "edit/revert loop oscillates into a trigger" 30 "$rc"
assert "trigger is oscillation" "$out" "TRIGGER=oscillation"
# helpful marking: progress after an answered escalation clears the unhelpful flag
D16="$TMP/ph"; fresh "$D16" "goalph"
esc "$D16" attempt --hypothesis h1 --action a1 --result fail >/dev/null
esc "$D16" packet --question "qh?" >/dev/null 2>&1
esc "$D16" answer esc-001 --kind advisory --text "fix the clamp" >/dev/null
esc "$D16" attempt --hypothesis h2 --action a2 --result fail --progress "failures 4 -> 1" >/dev/null
h="$(ESCALATE_ROOT="$D16" jq -r '.escalations[0].helpful' "$D16/.pi/escalations/state.json")"
[ "$h" = true ] && ok "progress after answer marks escalation helpful" || bad "helpful not marked (got $h)"
# wall-clock is explicitly not a trigger in the protocol
assert "wall-clock is never a trigger (SKILL.md)" "$skillmd" "NEVER a trigger"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
