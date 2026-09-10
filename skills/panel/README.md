# panel — advisor-panel skill for Herdr workspaces

A cross-agent skill: any coding agent (Claude Code, Codex, OpenCode, Antigravity, Hermes, Pi) that sits in a Herdr pane can act as **orchestrator** for a panel of read-only advisor agents living in panes labelled `panel-<name>`. The orchestrator turns the human's ask into a charter, fans it out, collects every panel's written answer, runs cross-review rounds until the panels' own votes agree, has them ratify the compiled text, and reports. It never decides the outcome.

## Quickstart on a new host

```bash
# 1. wire the skills into your agents (symlinks; skips agents you don't have)
./install.sh

# 2. site config — copy the template OUT of the repo and edit it
mkdir -p ~/.config/agent-skills
cp skills/panel/panel.env.example ~/.config/agent-skills/panel.env
#    edit: sessions/manifest/state dir, report repo (owner/name), tuning

# 3. in a Herdr workspace, open one pane per advisor, label them panel-<name>
#    (herdr pane rename <pane> panel-<name>) and start each agent however you like

# 4. capture the manifest (kinds, launch args, models, cwd per pane)
skills/panel/bin/panel-manifest capture
#    hand-edit panels.json for timeout_s / reading_cap / context / provider

# 5. heal + roster (all panes should be READY)
skills/panel/bin/panel-heal
skills/panel/bin/panel-roster --table

# 6. optional: a layout snapshot so pane recovery lands back in its grid slot
#    (see herdr-pane-restore / panel-restore)

# 7. run a session (SKILL.md Procedure, P1-P6)
```

Panel publishing (P6) additionally needs `PANEL_REPORT_REPO=owner/name` in your
panel.env and `gh` authenticated.

- Skill text: `SKILL.md` (Agent Skills format; symlinked into every agent's skills dir by `install.sh`)
- Scripts: `bin/` (bash 4 + jq + herdr; no agent-specific tooling)
  - `panel-manifest` capture/show/validate — per-workspace panel manifest (kind, launch args, cwd, model/effort/thinking, provider, timeout, usage probe)
  - `panel-heal` — recreate missing panes, restart exited agents from the manifest; never interrupts working panels
  - `panel-budget` — linear-pace usage gate for subscription panels (reactive from usage-limit banners, proactive with `--probe`)
  - `panel-roster` — discovery + readiness (agent state, budget gate, per-panel timeout), slow-first ordering
  - `panel-new` · `panel-dispatch` (blind | cross | focus | ratify; D6-A verbatim gate, D1-A context, queued briefs) · `panel-collect` (D4-A: timeout-only closing) · `panel-status` · `panel-next` (one-line next command) · `panel-nudge` · `panel-note` (audit line)
  - `panel-matrix` — mechanical parsing and tallying (aliases, voter-declared equivalence, ≤ 2 new conflicts per panel, corrections)
  - `panel-draft` — `--auto` draft from vote/claim files (verdicts verbatim per question), `--verify` quotability gate, `--changelog` objection-span check
  - `panel-report` — REPORT.md with outcome label (CONSENSUS | CONSENSUS-PARTIAL | SPLIT-WITH-RECORD | SPLIT | INCOMPLETE), participation with reasons, latency/bytes, corrections, change log
- Templates: `templates/` (charter with ordered reading set, answer schema, round briefs, disagreements example)
- Sessions: `$PANEL_SESSIONS_ROOT/<ts>-<slug>/` · Manifest: `$PANEL_MANIFEST` · State: `$PANEL_STATE_DIR` — defaults under `$HOME/.local/state/agent-skills/panel/`, all overridable via `~/.config/agent-skills/panel.env` (see `panel.env.example`)

Install / update symlinks: run this repo’s `install.sh` (or `skills/panel/install.sh`). History: the skill evolved through 18 ratified iterations of a panel-review meta-loop (SKILL.md rules 20–27 record each one).
