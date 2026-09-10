#!/usr/bin/env bash
# test-panel-fixes.sh — regression suite for the panel-intent-routing + charter-self-trigger + status-evidence fixes.
# Run: bash tests/test-panel-fixes.sh (from this skill’s tests/ dir)
set -uo pipefail
PANEL_BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
check(){ # check <desc> <expected_rc> <actual_rc> [cmd...] already run by caller via $rc
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "any" ] || [ "$got" -eq "$want" ]; then ok "$desc (rc=$got)"; else bad "$desc: wanted rc=$want got rc=$got"; fi
}

TMP="$(mktemp -d /tmp/panel-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
echo "=== 1. Charter validator fix ==="
source "$PANEL_BIN/panel-lib.sh"

# 1a: template charter (has <<FILL>> in an HTML comment AND real markers) -> unfilled
cat > "$TMP/c_unfilled.md" <<'EOF'
<!-- Orchestrator fills every <<FILL>> before dispatch. -->
## Problem
<<FILL: what is being decided>>
EOF
if charter_unfilled "$TMP/c_unfilled.md"; then ok "unfilled content detected (real marker present)"; else bad "should detect unfilled content"; fi

# 1b: fully-filled charter whose template comment still mentions <<FILL>> -> NOT unfilled
cat > "$TMP/c_filled.md" <<'EOF'
<!-- Orchestrator fills every <<FILL>> before dispatch. panel-dispatch refuses while any remain. -->
## Problem
We are reviewing the LLM gateway design for cost isolation.
## Questions
Q1. Should we shard by tenant?
EOF
if charter_unfilled "$TMP/c_filled.md"; then bad "comment-only mention should NOT count as unfilled"; else ok "comment-only <<FILL>> ignored; filled charter passes"; fi

# 1c: multi-line comment containing the marker, content clean -> not unfilled
cat > "$TMP/c_ml.md" <<'EOF'
<!-- line one of a long instructional comment
     mentioning every <<FILL>> token and how to replace them. -->
## Problem
Real problem text here.
EOF
if charter_unfilled "$TMP/c_ml.md"; then bad "multi-line comment with marker should be ignored"; else ok "multi-line HTML comment ignored"; fi

# 1d: real unfilled marker OUTSIDE any comment -> still fails closed
cat > "$TMP/c_real.md" <<'EOF'
<!-- instructions -->
## Problem
<<FILL>>
EOF
if charter_unfilled "$TMP/c_real.md"; then ok "real marker outside comment still detected (fail closed)"; else bad "must fail closed on real unfilled marker"; fi

# 1e: strip_html_comments removes a mid-line comment correctly
printf 'before <!-- hidden <<FILL>> here --> after\n' > "$TMP/inline.md"
out="$(strip_html_comments "$TMP/inline.md")"
if printf '%s' "$out" | grep -q '<<FILL'; then bad "inline comment not stripped"; else ok "inline HTML comment stripped (before  after)"; fi

# --- Mandated charter cases A-F (spec contract for strip_comments.py) -------
chk_charter() { # chk_charter <label> <expect: unfilled|filled> <file>
  local label="$1" want="$2" f="$3" got
  if charter_unfilled "$f"; then got=unfilled; else got=filled; fi
  [ "$got" = "$want" ] && ok "charter $label -> $got" || bad "charter $label: wanted $want got $got"
}

printf '<!-- every <<FILL>> marker must be replaced -->\n## Problem\nReal content.\n' > "$TMP/A.md"
chk_charter "A single-line comment marker ignored" filled "$TMP/A.md"

printf '<!-- multiline\n     <<FILL>>\n     comment -->\n## Problem\nReal content.\n' > "$TMP/B.md"
chk_charter "B multiline comment marker ignored" filled "$TMP/B.md"

printf '## Question\n<<FILL: question>>\n' > "$TMP/C.md"
chk_charter "C real content marker detected" unfilled "$TMP/C.md"

printf 'text before <!-- <<FILL>> --> text after\n' > "$TMP/D.md"
chk_charter "D inline comment, surrounding text kept" filled "$TMP/D.md"
dout="$(strip_html_comments "$TMP/D.md")"
case "$dout" in *"text before"*"text after"*) ok "D preserves text before and after comment";; *) bad "D lost surrounding text: [$dout]";; esac

printf 'actual <<FILL>> plus comment <!-- <<FILL>> -->\n' > "$TMP/E.md"
chk_charter "E real marker beside commented marker" unfilled "$TMP/E.md"

printf '<!-- malformed comment\n<<FILL>>\n' > "$TMP/F.md"
chk_charter "F malformed comment must not bypass validation" unfilled "$TMP/F.md"

printf 'a <!-- one --> b <!-- two <<FILL>> --> c\n' > "$TMP/G.md"
chk_charter "G multiple comments on one line" filled "$TMP/G.md"

# ---------------------------------------------------------------------------
echo "=== 2. panel-verify: no dispatch artifacts => never RUNNING ==="
mk_session() { # mk_session <name>
  local d="$TMP/$1"; mkdir -p "$d/rounds"
  jq -n --arg id "$1" '{session_id:$id, state:"intake", max_rounds:3}' > "$d/session.json"
  printf '# Charter\n## Problem\ntest\n' > "$d/charter.md"
  echo "$d"
}

# 2a: fresh session, no rounds at all -> NOT DISPATCHED (rc=2), never RUNNING
d="$(mk_session s1)"
out="$("$PANEL_BIN/panel-verify" "$d" 2>&1)"; rc=$?
check "no artifacts => not running" 2 $rc
if printf '%s' "$out" | grep -qi 'NOT DISPATCHED'; then ok "verdict says NOT DISPATCHED"; else bad "expected NOT DISPATCHED, got: $out"; fi

# 2b: round.json exists but zero meta (dispatch died mid-way) -> NOT DISPATCHED rc=2
d="$(mk_session s2)"
mkdir -p "$d/rounds/r1"
jq -n '{round:1,type:"blind",dispatched_at:"t"}' > "$d/rounds/r1/round.json"
out="$("$PANEL_BIN/panel-verify" "$d" 2>&1)"; rc=$?
check "round recorded, no meta => not running" 2 $rc
if printf '%s' "$out" | grep -qi 'NOT DISPATCHED'; then ok "verdict NOT DISPATCHED (no per-panel meta)"; else bad "expected NOT DISPATCHED: $out"; fi

# ---------------------------------------------------------------------------
echo "=== 3. panel-verify: failed dispatch => FAILED / not running ==="
d="$(mk_session s3)"
mkdir -p "$d/rounds/r1/meta"
jq -n '{round:1,type:"blind",dispatched_at:"t"}' > "$d/rounds/r1/round.json"
for p in panel-a panel-b; do jq -n --arg p "$p" '{panel:$p,state:"failed",reason:"agent_prompt_stalled",delivered:false}' > "$d/rounds/r1/meta/$p.json"; done
out="$("$PANEL_BIN/panel-verify" "$d" 2>&1)"; rc=$?
check "all-failed dispatch => FAILED (rc=3)" 3 $rc
if printf '%s' "$out" | grep -qi 'FAILED DISPATCH'; then ok "verdict FAILED DISPATCH"; else bad "expected FAILED DISPATCH: $out"; fi

# ---------------------------------------------------------------------------
echo "=== 4. panel-verify: valid dispatched round => RUNNING only with evidence ==="
d="$(mk_session s4)"
mkdir -p "$d/rounds/r1/meta" "$d/rounds/r1/dispatch"
jq -n '{round:1,type:"blind",dispatched_at:"t"}' > "$d/rounds/r1/round.json"
for p in panel-a panel-b; do
  jq -n --arg p "$p" '{panel:$p,state:"dispatched",delivered:true}' > "$d/rounds/r1/meta/$p.json"
  printf 'brief for %s\n' "$p" > "$d/rounds/r1/dispatch/$p.md"
done
out="$("$PANEL_BIN/panel-verify" "$d" 2>&1)"; rc=$?
check "dispatched round => RUNNING (rc=0)" 0 $rc
if printf '%s\n' "$out" | grep -q '^VERDICT RUNNING'; then ok "verdict token VERDICT RUNNING with disk evidence"; else bad "expected 'VERDICT RUNNING': $out"; fi

# 4b: same but NO dispatch/ files on disk -> must NOT be RUNNING (evidence gate).
# NOTE: assert the real contract - exact rc, exact verdict token, and absence of a genuine
# "VERDICT RUNNING" line. Do NOT grep the bare substring "RUNNING": the correct output
# legitimately contains the prose "Do NOT report as running".
d="$(mk_session s5)"
mkdir -p "$d/rounds/r1/meta"   # note: no dispatch dir at all
jq -n '{round:1,type:"blind",dispatched_at:"t"}' > "$d/rounds/r1/round.json"
for p in panel-a; do jq -n --arg p "$p" '{panel:$p,state:"skipped",reason:"agent status: none",delivered:false}' > "$d/rounds/r1/meta/$p.json"; done
out="$("$PANEL_BIN/panel-verify" "$d" 2>&1)"; rc=$?
check "skipped-only round => rc=2" 2 $rc
if printf '%s\n' "$out" | grep -q '^VERDICT NO ACTIVE PANELS'; then ok "verdict token NO ACTIVE PANELS"; else bad "expected 'VERDICT NO ACTIVE PANELS': $out"; fi
if printf '%s\n' "$out" | grep -q '^VERDICT RUNNING'; then bad "skipped-only round must not emit VERDICT RUNNING: $out"; else ok "no real VERDICT RUNNING line emitted"; fi

# ---------------------------------------------------------------------------
echo "=== 5. Intent-routing logic (unit-level classification) ==="
# The routing rule lives in .hermes.md + skill description; here we unit-test the DECISION FUNCTION
# a fresh session must apply: classify(request) -> PANEL | DELEGATE | AMBIGUOUS
classify() {
  local q="$1"
  # clear panel intent (case-insensitive)
  if printf '%s' "$q" | grep -qiE '\bpanel (review|discussion|discuss|decide|decision|ratification)\b|\bautonomous panel\b|^/panel$|ask the panel'; then echo PANEL; return; fi
  # explicit non-panel delegation phrasing wins over loose "agents" wording
  if printf '%s' "$q" | grep -qiE 'delegate_task|subagent|background (task|job)'; then echo DELEGATE; return; fi
  if printf '%s' "$q" | grep -qiE '(few|some|a couple of) agents.*(research|independent)|parallel (tasks|agents)'; then echo DELEGATE; return; fi
  # loose "agents"/"review" without panel => ambiguous, never auto-PANEL
  if printf '%s' "$q" | grep -qiE 'agent|review'; then echo AMBIGUOUS; return; fi
  echo NONE
}
t_classify() { local desc="$1" want="$2" q="$3"; got="$(classify "$q")"; [ "$got" = "$want" ] && ok "classify: $desc -> $got" || bad "classify: $desc wanted=$want got=$got"; }

t_classify "explicit panel review"      PANEL     "Run an autonomous panel review of this design. No human loop."
t_classify "panel discussion"           PANEL     "Let's have a panel discussion on the gateway architecture."
t_classify "ask the panels"             PANEL     "Ask the panels whether we should shard by tenant."
t_classify "autonomous panel decide"    PANEL     "Autonomous panel: decide the retry policy, ratification included."
t_classify "ordinary delegation"        DELEGATE  "Get a few agents to research these independent things in parallel."
t_classify "explicit delegate_task"     DELEGATE  "Use delegate_task for three background jobs."
t_classify "ambiguous review+agents"    AMBIGUOUS "Have some agents review this doc and tell me what they think."
t_classify "no intent at all"           NONE      "What is the weather like in Singapore?"

# ---------------------------------------------------------------------------
echo "=== 6. Skill index routing signal (60-char truncation invariant) ==="
# ROOT CAUSE GUARD: Hermes renders <available_skills> with each description
# truncated to SKILL_PROMPT_DESC_LIMIT (60) chars minus 3 for "...". Routing
# signal past that point NEVER reaches a fresh session. The panel trigger must
# therefore survive inside the first 57 characters.
SKILL_MD="$(cd "$(dirname "$0")/.." && pwd)/SKILL.md"
py_desc() { python3 - "$SKILL_MD" <<'PY'
import sys, yaml
text = open(sys.argv[1]).read()
fm = yaml.safe_load(text.split('---')[1])
sys.stdout.write(str(fm.get('description', '')))
PY
}
if desc="$(py_desc 2>/dev/null)" && [ -n "$desc" ]; then
  ok "SKILL.md frontmatter parses as YAML"
  head57="$(printf '%s' "$desc" | cut -c1-57)"
  lower="$(printf '%s' "$head57" | tr 'A-Z' 'a-z')"
  case "$lower" in *panel*) ok "trigger word 'panel' survives 57-char truncation";; *) bad "'panel' missing from first 57 chars: [$head57]";; esac
  case "$lower" in *review*|*discussion*|*decid*) ok "panel action word survives truncation";; *) bad "no review/discussion/decide in first 57 chars: [$head57]";; esac
elif python3 -c "import yaml" 2>/dev/null; then
  bad "SKILL.md frontmatter failed to parse as YAML (routing signal would be lost entirely)"
else
  # PyYAML absent (e.g. stock macOS python3): parse the description with sed instead of failing —
  # the YAML-validity contract is still checked wherever PyYAML exists (CI, dev hosts).
  desc="$(awk '/^description:/{sub(/^description: */,""); print; exit}' "$SKILL_MD" | tr -d '"')"
  if [ -n "$desc" ]; then
    head57="$(printf '%s' "$desc" | cut -c1-57)"; lower="$(printf '%s' "$head57" | tr 'A-Z' 'a-z')"
    case "$lower" in *panel*) ok "trigger word 'panel' survives 57-char truncation (sed fallback; PyYAML absent)";; *) bad "'panel' missing from first 57 chars: [$head57]";; esac
    case "$lower" in *review*|*discussion*|*decid*) ok "panel action word survives truncation (sed fallback)";; *) bad "no review/discussion/decide in first 57 chars: [$head57]";; esac
  else
    bad "SKILL.md has no description line at all (routing signal would be lost entirely)"
  fi
fi

# ---------------------------------------------------------------------------
echo "=== 7. panel-draft --changelog: re-ratify of a hand-written draft (no generated snapshot) ==="
# Regression for iteration-10 defect: when consensus-draft.md was written by the orchestrator
# (not `--auto`), no rounds/rN/consensus-draft.generated.md exists. A removed line that is not
# mechanical and not orchestrator-shaped must clear via in_objs/sec_named (the objection quotes it
# or names its section) instead of hard-flagging D4-A "not found in the previous generated snapshot",
# which blocked a correct re-ratification even though claude/codex's objections named the exact span.
cd "$PANEL_BIN"   # source panel-lib.sh so `norm` is defined for this test (it lives only in that file)

mk_re_ratify() { # mk_re_ratify <name>: session with r1 cross + r4 ratify, dispatched snapshot carrying a prose line the objection quotes
  local d="$TMP/$1"
  mkdir -p "$d/rounds/r1/in" "$d/rounds/r2/meta" "$d/rounds/r2/dispatch" "$d/rounds/r4"
  jq -n --arg id "$1" '{session_id:$id, state:"ratify", max_rounds:6}' > "$d/session.json"
  printf '# Charter\n## Problem\ntest\nQ1. Should we shunt?\n' > "$d/charter.md"
  # r1 cross round + a panel answer file (corpus for --verify, and the quote source)
  jq -n '{round:1,type:"cross",dispatched_at:"2026-09-06T00:00:00Z"}' > "$d/rounds/r1/round.json"
  printf '## VERDICT\nQ1. Shunt by tenant.\n## KEY CLAIMS\nC1. The shunt gate must be atomic across tiers before broad fan-in is allowed, and released on disconnect.\n' > "$d/rounds/r1/in/panel-a.md"
  # r4 ratify: dispatched snapshot = the text the panels last read (carries a prose summary line)
  jq -n '{round:4,type:"ratify",dispatched_at:"2026-09-06T01:00:00Z"}' > "$d/rounds/r4/round.json"
  cat > "$d/rounds/r4/consensus-draft.dispatched.md" <<'SNAP'
# Consensus draft — s7

## Charter questions — the panels' verdicts, verbatim

### Q1. Should we shunt?

- **panel-a** (r1): “The shunt gate must be atomic across tiers before broad fan-in is allowed.”

Unanimous across all five panels; no conflict was minted. The ratified policy stands with wording tightened so the disconnect-release test gates rollout.
SNAP
  # r4 ratify.json: an objection that QUOTES the prose line and NAMES its section (so in_objs + sec_named both clear it)
  jq -n '{votes:[{panel:"claude",choice:"no",objections:["“Unanimous across all five panels; no conflict was minted. The ratified policy stands with wording tightened so the disconnect-release test gates rollout.” → retitle this section “## Resolved conflicts” and carry the concrete gate verbatim."]}]}' > "$d/rounds/r4/ratify.json"
  # current draft: same as dispatched, but the prose line removed (replaced by a proper ## Resolved conflicts heading) — a clean re-ratification edit
  cat > "$d/consensus-draft.md" <<'DRAFT'
# Consensus draft — s7

## Charter questions — the panels' verdicts, verbatim

### Q1. Should we shunt?

- **panel-a** (r1): “The shunt gate must be atomic across tiers before broad fan-in is allowed.”

## Resolved conflicts
DRAFT
  echo "$d"
}

# 7a: the removed prose line clears via sec_named/in_objs -> changelog rc=0, zero ⚠ (the fix)
d="$(mk_re_ratify s7)"
"$PANEL_BIN/panel-draft" "$d" --changelog >/tmp/s7cl.out 2>&1; rc=$?
check "re-ratify hand-written draft: changelog clean" 0 $rc
nwarn=$(grep -c '^- .*⚠' "$d/consensus-draft.changelog.md" || true)
[ "${nwarn:-0}" -eq 0 ] && ok "no ⚠ on removed prose line the objection names (was D4-A before fix)" || bad "expected 0 ⚠, got $nwarn: $(grep '^- .*⚠' "$d/consensus-draft.changelog.md")"

# 7b: FAIL-CLOSED GUARD — a removed generated-looking line NOT named by any objection and with no
# generated snapshot to prove provenance must STILL ⚠ (the fix must not weaken D4-A generally).
cat >> "$d/consensus-draft.md" <<'XTRA'

## Unrelated section nobody objected to
Some stray prose that appears in the current draft but was never there and no objection mentions.
XTRA
# remove a line from the dispatched snapshot region that NO objection names: add an extra removed-only hunk by editing dispatch copy is complex; instead
# simulate by making the current draft REMOVE a line present in the snapshot that no objection quotes/names.
sed -i 's/- \*\*panel-a\*\* (r1): “The shunt gate must be atomic across tiers before broad fan-in is allowed.”//' "$d/consensus-draft.md" 2>/dev/null || true
# That line IS quoted by the objection though; craft a genuinely un-objectioned removal: delete a snapshot line no objection touches.
python3 - "$d" <<'PY'
import sys,re,os
d=sys.argv[1]
cur=open(f"{d}/consensus-draft.md").read()
# add a removed-only artifact: the dispatched snapshot has a line; ensure current draft lacks it AND no objection names its section.
extra="Stray generated-looking summary with no objection and no section named anywhere in the record.\n"
if extra.strip() not in cur:
    pass  # we want it ABSENT from current (removed) but PRESENT in snapshot -> append to snapshot only
open(f"{d}/rounds/r4/consensus-draft.dispatched.md","a").write("\n"+extra)
PY
"$PANEL_BIN/panel-draft" "$d" --changelog >/tmp/s7cl2.out 2>&1; rc=$?
[ "${rc:-0}" -ne 0 ] && ok "un-objectioned removed line still fails closed (rc!=0)" || bad "expected changelog to fail on un-named removal, got rc=0"
if grep -q '^- .*⚠' "$d/consensus-draft.changelog.md"; then ok "D4-A ⚠ preserved for a removal no objection names and no snapshot proves"; else bad "missing expected D4-A ⚠ on un-named removal"; fi

# ---------------------------------------------------------------------------
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
