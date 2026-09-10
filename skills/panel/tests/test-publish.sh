#!/usr/bin/env bash
# test-publish.sh — regression suite for the v1.13.0 auto-publish step (owner rule 2026-09-09:
# a finished panel session ALWAYS produces a GitHub report + console URL/summary).
#
# The real `git` runs against a LOCAL bare repo standing in for GitHub (no network; a fake `gh`
# is prepended to PATH). The real panel-report and panel-publish run end-to-end on synthetic
# terminal sessions:
#   CONSENSUS          → published: README row, files, verified rev, URL, idempotent re-run (no new commit)
#   CONSENSUS-PARTIAL  → published, console names the unsigned members
#   SPLIT (cap)        → published
#   INCOMPLETE         → deferred with reason, exit 0, nothing written to the repo
#   publish-failure    → panel-report still exits 0 with REPORT.md written, failure loud + transcripted
#
# Run: bash tests/test-publish.sh
set -uo pipefail
PANEL_BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
eq()  { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: wanted [$3] got [$2]"; }

TMP="$(mktemp -d /tmp/panel-pub.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state/reset" "$TMP/sessions"
export PANEL_STATE_DIR="$TMP/state"
export PANEL_RESET_DIR="$TMP/state/reset"
export PANEL_MANIFEST="$TMP/panels.json"
export PANEL_SESSIONS_ROOT="$TMP/sessions"
export HERDR_ENV=1 HERDR_WORKSPACE_ID=wTEST HERDR_PANE_ID=p0

printf '{ "version": 1, "panels": {} }' > "$PANEL_MANIFEST"

# fake gh: repo view succeeds (repo "exists"); anything else fails loudly
printf '#!/usr/bin/env bash\ncase "$1 $2" in "repo view") printf "{\\"name\\":\\"x\\",\\"isPrivate\\":true}\\n"; exit 0;; *) exit 2;; esac\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# a local bare repo as the "GitHub remote", seeded with the README index skeleton
git init -q --bare "$TMP/remote.git" -b main
git init -q "$TMP/seed" -b main
{ printf '# Panel session reports\n\nOne report per finished panel session — REPORT.md + consensus + per-round vote tables, verbatim, auto-published by the panel skill.\n\n'
  printf '| published | session | outcome | panels | one-line verdict |\n|---|---|---|---|---|\n'; } > "$TMP/seed/README.md"
git -C "$TMP/seed" add README.md && git -C "$TMP/seed" -c user.name=t -c user.email=t@t commit -qm seed \
  && git -C "$TMP/seed" remote add origin "$TMP/remote.git" && git -C "$TMP/seed" push -q -u origin main

export PANEL_REPORT_REPO="local/panel-reports"
export PANEL_REPORT_REMOTE_URL="$TMP/remote.git"
export PANEL_REPORTS_CLONE="$TMP/clone"

mk_session() { # mk_session <name> <state> <outcome|-> <n_discussion_rounds> <max_rounds> [unsigned]
  local dd="$PANEL_SESSIONS_ROOT/$1"; local i=0
  while [ "$i" -lt "$4" ]; do i=$((i+1)); mkdir -p "$dd/rounds/r$i/in"; done
  jq -n --arg id "$1" --arg st "$2" --arg oc "$3" --argjson mr "$5" \
    '{session_id:$id, state:$st, max_rounds:$mr, outcome:(if $oc=="-" then null else $oc end), members:["claude","codex","agy"]}' > "$dd/session.json"
  if [ -n "${6:-}" ]; then jq --arg u "$6" '.unsigned = ($u|split(","))' "$dd/session.json" > "$dd/session.json.t" && mv "$dd/session.json.t" "$dd/session.json"; fi
  i=0; while [ "$i" -lt "$4" ]; do i=$((i+1)); jq -n --argjson r "$i" '{round:$r, type:"blind", dispatched_at:"2026-09-09T00:00:00Z"}' > "$dd/rounds/r$i/round.json"; done
  printf '# Intake\n\n## Request (verbatim from human)\n\nShould we ship it?\n' > "$dd/00-intake.md"
  printf '# Charter\n\n## Problem\nDecide.\n\n## Questions\nQ1. Ship?\n' > "$dd/charter.md"
  printf '# t\n' > "$dd/transcript.md"
  printf '{"conflicts":[]}' > "$dd/rounds/r1/disagreements.json"
  printf '# Consensus\n\nRatified 2026-09-09 — ship it, with the two guardrails.\n' > "$dd/consensus.md"
  printf 'Ship it. The panel agreed the evidence is measured and the guardrails cover the risk.\n' > "$dd/summary.md"
  jq -n '{panels:[{panel:"claude",pane_id:"p1",kind:"pi",provider:"local",timeout_s:60}],orchestrator_pane:"p0"}' > "$dd/roster.json"
  i=0; while [ "$i" -lt "$4" ]; do i=$((i+1))
    jq -n --argjson r "$i" '{at:"2026-09-09T00:10:00Z", round:$r, answered:["claude"], answered_unconfirmed:[], answered_late:[], no_response:[], timeout:[], blocked:[], budget_exhausted:[], failed:[], skipped:[], gone:[], answered_post_consensus:[], panels:{claude:{state:"answered", latency_s:10, dispatch_bytes:100, answer_bytes:100, nudges:0}}, round_latency_s:10, collect_seconds:5}' > "$dd/rounds/r$i/collect.json"
  done
  printf '## VERDICT\nship\n' > "$dd/rounds/r1/in/claude.md"
  echo "$dd"
}

echo "=== P1 — CONSENSUS session auto-publishes through panel-report ==="
d1="$(mk_session pub-consensus ratified 'CONSENSUS' 2 2)"
out="$("$PANEL_BIN/panel-report" "$d1" 2>&1)"; rc=$?
eq "panel-report with a terminal session exits 0" "$rc" 0
printf '%s' "$out" | grep -q "^published: https://github.com/local/panel-reports/blob/main/reports/pub-consensus/REPORT.md" && ok "console prints the full GitHub URL" || bad "no full URL in console: $(printf '%s' "$out" | tail -3)"
printf '%s' "$out" | grep -q "^verdict:" && ok "console prints the quick verdict line" || bad "no verdict line"
printf '%s' "$out" | grep -q "^verified:  remote local/panel-reports HEAD == local" && ok "console prints the verified push line" || bad "no verified line"
grep -q "pub-consensus/REPORT.md" "$TMP/clone/README.md" && ok "README index row added" || bad "no README row"
[ -s "$TMP/clone/reports/pub-consensus/REPORT.md" ] && ok "REPORT.md in repo" || bad "REPORT.md missing from repo"
[ -s "$TMP/clone/reports/pub-consensus/consensus.md" ] && ok "consensus.md in repo" || bad "consensus.md missing"
ncommits="$(git -C "$TMP/clone" rev-list --count origin/main)"

echo
echo "=== P2 — idempotent: re-publishing adds no new commit ==="
# NOTE: panel-report REGENERATES REPORT.md (its `generated:` timestamp is new content), so the
# idempotency contract is panel-publish's: same inputs → no new commit. P2 drives panel-publish.
out="$("$PANEL_BIN/panel-publish" "$d1" 2>&1)"; rc=$?
eq "re-run exits 0" "$rc" 0
eq "no new commit when nothing changed" "$(git -C "$TMP/clone" rev-list --count origin/main)" "$ncommits"
rows="$(grep -c "pub-consensus/REPORT.md" "$TMP/clone/README.md")"
eq "README row not duplicated (1 row)" "$rows" 1

echo
echo "=== P3 — a content change re-publishes in place (one row, new commit) ==="
printf 'Ship it. Stronger wording after reflection — the guardrails cover the risk.\n' > "$d1/summary.md"
out="$("$PANEL_BIN/panel-report" "$d1" 2>&1)"; rc=$?
eq "re-publish after change exits 0" "$rc" 0
[ "$(git -C "$TMP/clone" rev-list --count origin/main)" -gt "$ncommits" ] && ok "new commit on content change" || bad "content change did not commit"
rows="$(grep -c "pub-consensus/REPORT.md" "$TMP/clone/README.md")"
eq "still exactly one README row" "$rows" 1
grep -q "Stronger wording" "$TMP/clone/reports/pub-consensus/summary.md" && ok "updated summary in repo" || bad "repo summary stale"

echo
echo "=== P4 — CONSENSUS-PARTIAL publishes and names the unsigned ==="
d2="$(mk_session pub-partial ratified 'CONSENSUS-PARTIAL (2/3 members signed; unsigned: codex)' 2 2 codex)"
out="$("$PANEL_BIN/panel-report" "$d2" 2>&1)"; rc=$?
eq "partial session publishes, exit 0" "$rc" 0
printf '%s' "$out" | grep -q "^unsigned:  codex" && ok "console names the unsigned member" || bad "unsigned not named: $(printf '%s' "$out" | tail -4)"
grep -q "pub-partial/REPORT.md" "$TMP/clone/README.md" && ok "partial session in README index" || bad "no README row for partial"

echo
echo "=== P5 — SPLIT (cap reached) publishes ==="
d3="$(mk_session pub-split r2-blind-analysed '-' 2 2)"
out="$("$PANEL_BIN/panel-report" "$d3" 2>&1)"; rc=$?
eq "split (cap reached) publishes, exit 0" "$rc" 0
grep -q "pub-split/REPORT.md" "$TMP/clone/README.md" && ok "split session in README index" || bad "no README row for split: $(printf '%s' "$out" | tail -3)"

echo
echo "=== P6 — INCOMPLETE defers (exit 0, nothing published) ==="
d4="$(mk_session pub-open r1-blind-dispatched '-' 1 3)"
before="$(git -C "$TMP/clone" rev-list --count origin/main)"
out="$("$PANEL_BIN/panel-report" "$d4" 2>&1)"; rc=$?
eq "incomplete session: panel-report exits 0 (REPORT.md still written)" "$rc" 0
printf '%s' "$out" | grep -q "publish: deferred" && ok "deferred with the reason printed" || bad "no deferral message: $(printf '%s' "$out" | tail -3)"
eq "no new commit for an incomplete session" "$(git -C "$TMP/clone" rev-list --count origin/main)" "$before"
[ -s "$d4/REPORT.md" ] && ok "local REPORT.md still written" || bad "local REPORT.md missing"

echo
echo "=== P7 — publish failure is loud, local REPORT.md survives ==="
d5="$(mk_session pub-broken ratified 'CONSENSUS' 2 2)"
mv "$TMP/remote.git" "$TMP/remote.git.hidden"      # remote unreachable
out="$("$PANEL_BIN/panel-report" "$d5" 2>&1)"; rc=$?
mv "$TMP/remote.git.hidden" "$TMP/remote.git"
eq "panel-report still exits 0 (REPORT.md written, failure reported, not fatal)" "$rc" 0
printf '%s' "$out" | grep -q "publishing FAILED" && ok "failure printed loudly" || bad "failure swallowed: $(printf '%s' "$out" | tail -3)"
[ -s "$d5/REPORT.md" ] && ok "local REPORT.md safe" || bad "local REPORT.md lost"
grep -q "publish failed" "$d5/transcript.md" && ok "failure transcripted" || bad "failure not transcripted"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
