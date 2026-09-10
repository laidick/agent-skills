---
name: autonomous-escalation
description: "Escalate stuck autonomous work via 4 bounded classes. Trigger: long-running implementation worker that is GENUINELY stuck or crosses a governance boundary; never for first failures, trivial coding, or because a clock passed. Classes: implementation/debug (one advisory reviewer), architecture (visible HerdR PANEL only), external-current-fact (research), human (terminal authorization). Bounded redacted help packet; .pi/goal-state.md + .pi/help/ + .pi/escalations/ persistence; stale-advice detection; depth/cooldown/dedup/budget guards. Alias: escalate. NOT a scheduler - Hermes owns scheduling, budget, and panel execution."
license: MIT
metadata:
  version: "1.0.0"
  requires: [bash, jq, git]
  scripts: <this-skill>/bin
  aliases: [escalate, bounded-escalation, autonomous-help]
---

# autonomous-escalation — ask for help only when the evidence says you are stuck

Ratified by a panel review session (2026-09-07, Workstream B;
snapshot sha256 `d94b5244b7ba5a37d387e6b344dfdc5ae5fca2e599bfe1df48fa19eee9622530`).
Canonical name `autonomous-escalation`; alias `escalate`.

**First principles.** Local autonomy is the DEFAULT. A long-running Pi/Hermes
implementation worker attempts ordinary debugging first; this skill only decides
*when the evidence says it is genuinely stuck or has crossed a governance
boundary*, *what class of help it needs*, and *how to record and resume*.
Elapsed time is NEVER a trigger by itself.

**This skill is NOT a scheduler.** It never picks agents/panels, never manages
subscriptions or burn-down, and never fans itself out. It emits a class request;
the **Hermes orchestrator remains the sole agent/subscription scheduler** and the
**`panel` skill is the sole architecture pipeline**. See "Hermes boundary".

## CLI

```bash
E="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../bin" 2>/dev/null || echo "$HOME/.pi/agent/skills/autonomous-escalation/bin")/escalate"
export ESCALATE_ROOT="<project root>"     # defaults to $PWD; .pi/ lives here
$E init --goal "<durable goal>" [--set key=value ...]   # once per project/goal
$E attempt --hypothesis H --action A --result fail|pass [--progress "what improved"]
$E event --kind <kind> --note "..."        # governance/authorization event (below)
$E classify                                # print current escalation class
$E packet --question "one precise question" [--class C] [--decision-type T] [--depth N]
$E answer <id> --kind <kind> [--panel-session DIR --panel-snapshot-sha SHA --panel-outcome LABEL] [--text "..."]
$E baseline --file <frozen-design-file>    # pin the frozen baseline for stale detection
$E resume                                  # resume directive; state -> NORMAL
$E status
```

Exit codes: `0` ok · `2` usage/rejected-answer · `10` duplicate-suppressed ·
`11` cooldown · `12` max-depth · `13` budget exhausted (→ `HUMAN_FALLBACK`) ·
`40` answer recorded but STALE.

## Trigger state machine (event-driven)

States: `NORMAL → STALLED → ESCALATING → AWAITING → RESUMED → NORMAL`, plus
terminal `HUMAN_FALLBACK` and terminal `RESOLVED` (goal done).

`NORMAL → STALLED` (any of; **wall-clock alone never qualifies**):
1. **distinct-attempts**: `fail_streak ≥ min_distinct_attempts` (default **3**)
2. **no-progress**: `no_progress_streak ≥ no_progress_cycles` (default **2**)
3. **oscillation**: ≥2 edit/revert loops on the same (hypothesis, action) —
   i.e. the same attempt signature seen 3+ times
4. a **governance event** (`$E event`): architecture deviation, external-spec
   conflict, or authorization barrier — immediate, no attempt-count threshold

`STALLED → ESCALATING`: build the bounded redacted packet (`packet`).
`ESCALATING → AWAITING`: hand the packet to the class channel (Hermes schedules
who answers; the skill does not).
`AWAITING → RESUMED`: answer recorded (`answer`) with its authority class.
`RESUMED → NORMAL`: `resume`; triggers re-evaluate on the next attempt.
Any state → `HUMAN_FALLBACK` when the budget/depth/repeated-failure caps hit or
the class is HUMAN. Present the full packet to a human; **no further fan-out**.

### Distinct attempt (counts) vs repeat (never counts)

A **distinct attempt** changes at least one of: (a) the hypothesized root cause,
(b) the fix/code/config region changed, (c) the verification method. The CLI
keys attempts on `sha256(goal | hypothesis | action)`.

- ✅ different root-cause hypothesis tested
- ✅ different subsystem isolated / materially different fix
- ✅ new evidence gathered (`--progress "fewer failures: 12→5"`)
- ❌ rerunning the same command unchanged
- ❌ re-applying the same patch (edit/revert loop)
- ❌ restating the same hypothesis
- Repeats are logged (`repeat:true`) for the record but do NOT advance any
  counter; ≥3 occurrences of one signature is an oscillation (trigger 3).

### Measurable progress (resets the counters)

A defined observable improving toward the stated goal:
- failing-test count down / previously-failing check now passes
- smaller reproducer
- hypothesis confirmed or refuted with evidence
- new relevant evidence obtained
- independent milestone completed
- ✅ code is simply not failing yet

NOT progress: elapsed time, code churn (edits made), a proxy metric that does
not move the stated goal. Pass `--progress "..."` (or `--result pass`) to reset
`fail_streak` and `no_progress_streak`. Progress after an answered escalation
marks that escalation `helpful=true` (feeds the step-up guard).

### Defaults (all configurable via `init --set`, no magic values)

| key | default | meaning |
|---|---|---|
| `min_distinct_attempts` | 3 | distinct failed attempts before trigger 1 |
| `no_progress_cycles` | 2 | consecutive no-progress cycles before trigger 2 |
| `cooldown_attempts` | 1 | new distinct attempts needed before re-escalating the same question |
| `max_depth` | 1 | worker→reviewer is one hop; a reviewer never spawns another non-human path |
| `max_escalations_per_goal` | 5 | per-goal escalation budget; exhaustion → `HUMAN_FALLBACK` |
| `repeated_unhelpful` | 2 | same-class escalations w/o measurable progress before the ladder steps up |
| `packet_max_bytes` | 16384 | hard byte cap on the outgoing packet (truncation is annotated, never silent) |

## The four escalation classes (ordered; first match wins)

1. **HUMAN** — credentials missing; destructive action needing approval;
   irreversible external action; security-sensitive authorization.
   `event --kind credentials|destructive|irreversible|security-auth|human-required`.
   Terminal for the blocked action until a human authorizes (`answer --kind
   human-authorization`). The skill **never invents credentials or approves
   destructive changes itself**.
2. **ARCHITECTURE/PANEL** — implementation contradicts the frozen design; the
   required change would alter a ratified architecture decision; a deviation was
   discovered; two authoritative requirements conflict; the decision is beyond
   one reviewer's authority. `event --kind deviation|design-conflict`.
   **Hard rule: a single implementation/debug reviewer may NOT override a
   ratified baseline — any such decision routes here.**
3. **EXTERNAL/RESEARCH** — current external fact/policy/provider behavior
   contradicts remembered documentation and cannot be verified locally.
   `event --kind external-conflict|current-fact`. NOT the class for "the coding
   is difficult".
4. **IMPLEMENTATION/DEBUG** — default: repeated failing test, repeated
   unsuccessful root-cause attempts, local implementation uncertainty. One
   reviewer/advisor; **ADVISORY ONLY** — the worker keeps the implementation
   decision.

When no event is recorded, `packet` defaults to class 4 and the class ladder
for repeated-unhelpful help is `IMPLEMENTATION/DEBUG → ARCHITECTURE/PANEL →
HUMAN` (external research is off-ladder: unhelpful research goes to HUMAN).
Escalation only moves UP the ladder, never down or sideways.

## Help packet (bounded, redacted)

`packet` writes `.pi/help/<id>.md` (and mirrors it into the durable record
`.pi/escalations/<id>.md`). Fields: goal · exact question · escalation class ·
requested decision type (`advisory-hint` / `authoritative-architecture` /
`external-fact` / `yes-no-authorization`) · question hash · baseline ref ·
failure signature · goal-state excerpt (bounded) · frozen-design pointer ·
bounded `git status` / `diff --stat` · failing signal & logs (bounded, supplied
via the goal-state Notes section) · attempt history (hypothesis/action/result)
· requested decision.

**Never dumped:** the entire repository, the conversation transcript, huge
logs, full payloads. **Redaction** (applied to every text field) replaces:
AWS key IDs, GitHub tokens, Slack tokens, OpenAI-style `sk-…`, private-key
headers, `Bearer <token>`, and `password|secret|token|api_key|auth … =|: value`
patterns with `[REDACTED]`. The byte cap truncates with an explicit
`[TRUNCATED]` note.

## Persistence layout (files only — no DB, no server)

```
.pi/goal-state.md          human-readable: goal, STATUS, counters, escalation log, ## Notes (worker-managed)
.pi/help/<id>.md           bounded outgoing help packet
.pi/escalations/<id>.md    append-only durable record: packet + class + answer + authority + panel evidence + stale flag
.pi/escalations/state.json machine state: triggers, guards, question hashes, budget
```

## Loop / recursion protection

- **Depth ≤ `max_depth` (1)**: worker→reviewer is the only hop; `packet --depth 1`
  (a reviewer asking for help) is refused for every non-HUMAN class
  (exit 12). No `worker → reviewer → reviewer → …`.
- **Same-question dedup**: `question_hash = sha256(goal | failure_signature |
  exact_question)`. A question with a pending escalation is never re-sent
  (exit 10).
- **Cooldown**: after an answered escalation, ≥`cooldown_attempts` new distinct
  attempts are required before re-escalating the same question (exit 11).
- **Budget**: per-goal escalation ceiling; exhaustion flips state to
  `HUMAN_FALLBACK` (exit 13) — present the packet to a human, do not fan out.
- **Repeated-unhelpful step-up**: `repeated_unhelpful` consecutive same-class
  escalations with no measurable progress force the next escalation one ladder
  step up (same-class re-ask is refused, exit 10).
- **Terminal**: `HUMAN_FALLBACK` accepts nothing but a human decision.

## Resume semantics (authority is recorded, not assumed)

`answer <id> --kind …` records the response in the escalation record and
re-associates it with the originating question hash:

| kind | valid class | authority | effect on baseline |
|---|---|---|---|
| `advisory` | IMPLEMENTATION/DEBUG | worker may follow or not; must verify independently | none |
| `external-evidence` | EXTERNAL/RESEARCH | sourced fact | none |
| `authoritative` | ARCHITECTURE/PANEL **only, with** `--panel-session` (dir containing `consensus.md`), `--panel-snapshot-sha`, `--panel-outcome` | ratified panel result; binds the worker | **new frozen baseline** (snapshot sha); old one superseded |
| `human-authorization` | HUMAN only | terminal authorization for the blocked action | none |

A reviewer's `authoritative` claim is **rejected** (exit 2) — an advisory
reviewer can never become architecture authority. A panel result without the
visible-panel evidence files is rejected.

**Stale detection**: the packet records `baseline_ref` (hash of the pinned
frozen-design file, else git HEAD). `answer` re-hashes the current baseline; a
mismatch records `stale=true`, prints a warning, and exits 40 — re-verify or
re-escalate, do not blindly apply. `resume` lists every stale/advisory record
as a constraint. `resume` always points back to the **original goal** and
resets the trigger counters; local autonomy resumes.

## Architecture class = the visible HerdR PANEL pipeline (no exceptions)

For class 2 the worker does NOT pick a reviewer and does NOT run hidden
`delegate_task`/background subagents "as a panel". It emits the request
("I need an architecture PANEL for: <question> + packet"), and the **existing
`panel` skill pipeline** (`panel-roster` → charter → `panel-dispatch`
blind/cross/focus/ratify → `consensus.md`) executes under Hermes. Only a
**terminal ratified panel result** (session dir with `consensus.md` + snapshot
sha) may be recorded `authoritative`. The session dir, snapshot sha, and outcome
label are stored verbatim in the escalation record as evidence.

## Hermes boundary (one scheduler)

- The **skill** owns: trigger detection, class classification, packet
  construction, loop guards, durable `.pi/` state, resume.
- **Hermes** owns: which agents/panel members to run, subscription
  usage/burn-down, cost accounting, the visible panel execution.
- The skill says "I need implementation review" or "I need an architecture
  PANEL"; Hermes decides the resources. No member lists, no budget logic, no
  competing scheduler lives in this skill — and it must not be added.

## Minimal worker loop

```bash
$E init --goal "ship the rate limiter" && $E baseline --file docs/design/ratelimit.md
while true; do
  # ... do real work: edit, run tests ...
  $E attempt --hypothesis "off-by-one in window math" --action "clamp window" \
             --result fail --progress "12 -> 5 failures" || true
  # rc 30 = STALLED: build packet, hand to the class channel via Hermes
  rc=$?; [ $rc -eq 30 ] || continue
  $E packet --question "Why do 5 window-edge cases still fail?"
  # ... Hermes delivers the answer; record it: ...
  $E answer esc-001 --kind advisory --text "use integer math, not float seconds"
  $E resume
done
```
