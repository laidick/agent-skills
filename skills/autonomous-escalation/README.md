# autonomous-escalation (alias: `escalate`)

Ratified by a panel review session (2026-09-07)
(Workstream B). Lets a long-running Pi/Hermes implementation agent: attempt
normal autonomous debugging first; detect when it is genuinely stuck or has
crossed a governance boundary; build a bounded, redacted help packet; select
the correct escalation class; record the answer with its authority; and resume
the original goal — without turning ordinary implementation into constant
delegation.

**Protocol of record:** `SKILL.md`. This directory is deliberately small:
one CLI (`bin/escalate` + `bin/escalate-lib.sh`), state in files, no server.

## Layout

```
skills/autonomous-escalation/
  SKILL.md              protocol (triggers, classes, packet, guards, resume, Hermes boundary)
  README.md             this file
  bin/escalate          CLI (init/attempt/event/classify/packet/answer/baseline/resume/status)
  bin/escalate-lib.sh   shared helpers (state, hashes, redaction, rendering)
  install.sh            symlinks this skill into every agent dir
  tests/test-escalation.sh   deterministic acceptance suite (the 20 ratified checks)
```

Runtime state (per project, never in git):

```
.pi/goal-state.md           durable goal/progress state (human-readable)
.pi/help/<id>.md            bounded outgoing help packet
.pi/escalations/<id>.md     append-only escalation record (packet + answer + evidence)
.pi/escalations/state.json  machine state for the trigger machine + loop guards
```

## Run the tests

```bash
bash skills/autonomous-escalation/tests/test-escalation.sh   # 20+ assertions
```

Install (from repo root): `./install.sh` — this skill is discovered
automatically (any `skills/<name>/SKILL.md`), or selectively: `./install.sh autonomous-escalation`.

## Dependencies

`bash`, `jq`, `sha256sum`/`shasum`, `git` (optional at runtime; packet degrades
gracefully outside a repo). The ARCHITECTURE class additionally requires the
existing `panel` skill + HerdR at the point it is used — this skill only
*requests* that pipeline, it never reimplements it.
