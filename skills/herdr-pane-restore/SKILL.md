---
name: herdr-pane-restore
description: "Use when HerdR panes are lost, closed, or crashed and the exact LAYOUT must come back — split-tree rebuild with per-pane geometry, verified live 3x (2026-09-09)."
version: 1.0.0
author: Hermes Agent (panel-skill maintenance)
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [herdr, panes, layout, restore, recovery, split-tree, tmux-like]
    related_skills: [herdr-team-layout, panel]
---

# HerdR Pane Restore — layout-preserving pane-grid recovery (host-wide, project-agnostic)

Rebuild a pane grid in a HerdR workspace/tab after pane loss, preserving **layout
positions, not just pane counts** — e.g. an N×M agent grid beside an orchestrator
column, 4 above / 4 below, same tab. Proven in three full kill-and-rebuild drills
on a live 8-panel grid (2026-09-09), each restored pixel-identical.

This skill is the general engine; the panel skill's `panel-restore` is one
consumer (it points its snapshot + manifest at this recipe). It works for any
project that keeps labeled panes in a HerdR workspace.

## Workflows

**Capture a healthy layout** (run from any pane INSIDE the target workspace — `herdr pane layout` reports the caller's workspace):
```bash
# 1. manifest: which panes are the grid, their agent kind + full-parameter start command
#    (write it by hand, or adapt the panel skill's panel-manifest capture + test-startup flow)
$PANE/pane-capture <manifest.json> <state/layout-snapshot.json>          # from a pane in that workspace
#    every manifest label that has a live pane is recorded at its exact x/y/w/h;
#    every OTHER pane in the workspace is recorded as the orchestrator column (sorted by y).
```

**Restore after loss** (from any pane in that workspace):
```bash
$PANE/pane-restore <state/layout-snapshot.json> <manifest.json> --dry-run   # plan
$PANE/pane-restore <state/layout-snapshot.json> <manifest.json>             # rebuild + verify
#    idempotent (all present -> no-op), --force to rebuild anyway
```

**Complementary tool — herdrctl layout** (herdr-team-layout skill): host-wide,
captures agent specs (model/effort/resume/session) for EVERY workspace in one
command (`herdrctl layout capture-all` / `restore-all`) but does NOT pin exact
grid geometry. Use herdrctl for agent/session state, pane-restore for exact
layout positions; they compose — herdrctl can re-create the workspace and panes,
pane-restore re-places them at their slots.

## When to Use

- Panel/agent panes were closed, crashed, or the workspace layout was wrecked
- Panes must return to EXACT positions (split-tree geometry), not just exist
- Agents in those panes must be restarted with full-parameter CLI commands

## herdr split-tree semantics (empirically verified — the whole game)

1. **`herdr pane split --pane P --direction right --ratio R`**: **P KEEPS R** of
   the width; the NEW pane gets the remaining `1-R`, placed to P's right. Same
   for `down` (P keeps R of the height, new pane below P). To give P exactly `W`
   of a container `C`: `R = W/C`.
2. **Closing panes collapses the split tree** into the surviving neighbor. Kill
   an entire grid and the tab degenerates to stacked full-width bands (one per
   surviving pane). You rebuild the ORIGINAL tree from scratch — you cannot
   "patch" a collapsed tree.
3. **Never split from a pane that sits in a band you don't want the grid in.**
   Splits nest INTO the pane you target. Anchor = the top-left pane (x=0,y=0),
   NOT `$HERDR_PANE_ID` (the running pane may be anywhere).
4. **Order matters: column first, then rows, then columns per row.** Split the
   anchor RIGHT (left-column width / tab width) → split the anchor DOWN (its
   column partner) → split the grid area DOWN 0.5 (rows) → RIGHT splits per row
   at the snapshot's column boundaries (`ratio = col_width / remaining_width`).
5. **A leftover full-width band keeps every row in the top band at half height.**
   Swapping a band pane UP puts it in the grid and drops a grid pane to the band;
   closing the FALLEN pane stretches the grid to full height. That close is a
   required step, not cleanup.
6. **`pane swap --direction <d>` moves a pane ONE neighbor at a time**; the
   terminal (and its running agent) moves with the pane. To send the running
   orchestrator pane home: recompute its live rect after every step.
7. **Renaming must follow FINAL slot geometry** (sort grid panes y-then-x from a
   fresh `pane layout`), never the order you split them in — the swap dance
   moves panes between slots.
8. **Agent restart is not idempotent by label.** A pane whose terminal moved may
   have lost its agent; one that already runs the right kind must be SKIPPED
   (starting a second CLI into a working terminal stacks processes). Stop a
   mismatched agent (C-c, `/quit`, Enter) before starting the right one.

## The recipe (verified 3x live)

```bash
# state after a full kill: two stacked full-width bands (anchor top, me bottom)
# 0. snapshot: per-pane x/y/w/h (grid panes by label) + left-column panes + tab size
anchor=$(herdr pane layout | jq -r '[.result.layout.panes[]|select(.rect.x==0 and .rect.y==0)]|sort_by(.rect.width)|last|.pane_id')

# 1. column: anchor keeps left_w/tab_w of the width (grid area is born right of it)
grid=$(herdr pane split --pane "$anchor" --direction right --ratio $left_w/$tab_w ...)

# 2. anchor's column partner (only if anchor currently spans the tab height)
spare=$(herdr pane split --pane "$anchor" --direction down --ratio $top_h/$tab_h ...)

# 3. rows
bottom=$(herdr pane split --pane "$grid" --direction down --ratio 0.5 ...)

# 4. per row: right splits at snapshot column boundaries
#    ratio_i = col_width_i / current_pane_width   (the pane keeps that column)

# 5. ENDGAME (deterministic):
#    a. band pane (not me) below the grid: swap it UP; close the pane that fell
#       to the band; repeat until no band remains (grid stretches full height)
#    b. if ME holds the whole left column (y==0): split me DOWN top_h/tab_h,
#       swap me DOWN, then walk the anchor UP + LEFT back to (0,0)
#    c. structural check: 2 left-column panes + expected grid count, else abort

# 6. rename grid panes by final slot geometry (fresh layout, sorted y,x)

# 7. start agents from a manifest's full-parameter start[] commands (see
#    panel skill rule 24); skip panes already running the right kind

# 8. verify: every pane's rect == snapshot rect; non-zero exit on any diff
```

## Idempotency & safety

- If every expected label is already present → exit 0, touch nothing
  (`--force` rebuilds anyway; `--dry-run` prints the plan).
- Every swap is verified by rect before/after; a no-op swap aborts the step.
- A wrong structural count is a hard abort ("inspect layout"), never a guess.
- Never close the pane you are running in; never close a band pane that is YOU.

## Reference implementation

`panel-restore` in the panel skill (symlinked as `panel` in each agent's skills dir,
canonical `<agent-skills repo>/skills/panel/bin/panel-restore`) is
the complete, live-proven implementation of this recipe: snapshot-driven targets,
the split order, the endgame, rename-by-geometry, manifest-driven agent start,
rect verification. Read it before reimplementing; parameterize the snapshot
(`PANEL_LAYOUT_SNAPSHOT`) and the manifest (labels/kinds/start[]) to reuse it
for a different grid.

## Pitfalls (each found the hard way, 2026-09-09)

- Ratio semantics inverted in the first draft → 13-column slivers. P KEEPS R.
- Splitting from `$HERDR_PANE_ID` (bottom band) nested the whole grid inside the
  bottom band with 17/16-high rows. Anchor at (0,0).
- The band-collapse close is what restores full-height rows — skipping it leaves
  every row at half height.
- The agent in a moved terminal can vanish (its process died with the closed
  pane). After ANY pane-moving dance, re-check every pane's agent, not just
  labels.
- Verify against the snapshot at the END, not during — intermediate states
  legitimately differ (half-height rows are correct mid-endgame).
