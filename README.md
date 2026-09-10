# agent-skills

Canonical source for **generic, cross-project, cross-agent** skills.

One source of truth. Many symlinks. No duplicate editable copies.

```
~/dev/agent-skills/skills/<skill>
        │
        ├── ~/.claude/skills/<skill>
        ├── ~/.pi/agent/skills/<skill>
        ├── ~/.hermes/skills/productivity/<skill>
        ├── ~/.codex/skills/<skill>
        ├── ~/.gemini/skills/<skill>
        ├── ~/.gemini/config/skills/<skill>
        └── ~/.config/opencode/skills/<skill>
```

## What belongs here

A skill belongs in this repo when **all** of the following hold:

- it is useful across more than one project
- it is useful to more than one agent (Claude, Codex, Hermes, Pi, Gemini, OpenCode …)
- it hardcodes no machine-specific absolute path, hostname, credential, or employer-specific process
- it needs nothing beyond commonly available tooling (`bash`, `jq`, `python3`, `git`)

**Project-specific skills do not belong here.** Anything encoding one repo's
conventions, one team's release process, or one host's infrastructure stays with
that project.

## Skills

| Skill | Purpose |
|-------|---------|
| `panel` | Run a multi-agent panel review/discussion through visible HerdR `panel-*` panes: blind → cross → focus → ratify, to a terminal verdict. |
| `autonomous-escalation` | Event-driven escalation for long-running implementation agents (alias `escalate`): detects genuine stuck-state, classifies (advisory review / architecture PANEL / external research / human authorization), builds a bounded redacted help packet, and resumes with loop guards. Ratified panel protocol; not a scheduler. |

## Install

```bash
git clone <this-repo> ~/dev/agent-skills
cd ~/dev/agent-skills
./install.sh --check     # preview every change, modify nothing
./install.sh             # apply
```

Then restart any long-running agent (e.g. the Hermes gateway) so it re-scans skills.

See [docs/installation.md](docs/installation.md) for details.

### Installer guarantees

- **Idempotent** — re-running is a no-op once correct.
- **Repairs** stale or wrong symlinks (e.g. ones left pointing at an older canonical path).
- **Never clobbers** a real directory or file that isn't one of our symlinks; it errors and tells you to move it aside.
- **Skips absent agents** rather than creating stray directories.
- **Explicit** — every target is printed; `--check` is a true dry run.

Selective install: `./install.sh panel`

## Adding a new generic skill

1. `mkdir -p skills/<name>` with a `SKILL.md` at its root.
2. Write YAML frontmatter — **the description is the routing signal**:

   ```yaml
   ---
   name: <name>
   description: "<trigger first, within 57 chars>. <detail follows>"
   ---
   ```

   > **Critical:** Hermes truncates descriptions to **60 characters**
   > (`SKILL_PROMPT_DESC_LIMIT`) when building `<available_skills>`. Anything past
   > ~57 chars is invisible at routing time. Put the trigger phrase FIRST —
   > `"Run a panel review/discussion via HerdR panel-* panes. …"` — not after a
   > long preamble. A skill whose triggers fall past the cut will never be selected.

3. Keep the description a valid YAML scalar. If it contains `:` followed by a
   space, **quote the whole value**, or the frontmatter fails to parse and the
   skill silently disappears.
4. Portability: no absolute paths outside `$HOME`, no secrets, no host names.
   Derive your own location, e.g. `SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`.
5. Put tests in `skills/<name>/tests/` and make them runnable with plain `bash`.
6. Optional `skills/<name>/install.sh` for hooks/plugins/systemd wiring — the
   top-level installer runs it automatically after linking.
7. Run `./install.sh --check`, then `./install.sh`.

## Testing

```bash
bash skills/panel/tests/test-panel-fixes.sh              # 39 assertions
bash skills/autonomous-escalation/tests/test-escalation.sh  # 68 assertions
./install.sh --check                                     # must report no surprises
```

Syntax-check everything:

```bash
find skills -name '*.sh' -exec bash -n {} \; && echo OK
```

## Recovery / restore

Skills and the wiki live in **two separate git repos with two separate backups**.
Restore them in this order:

1. **Restore `~/dev/agent-skills`** (this repo) — the canonical skill code.

   ```bash
   git clone <your-remote>/agent-skills.git ~/dev/agent-skills
   ```

2. **Recreate the agent symlinks.**

   ```bash
   cd ~/dev/agent-skills && ./install.sh
   ```

   This is idempotent and repairs stale/wrong links, so it is also the fix if an
   agent stops seeing a skill after a partial restore.

Verify a restore:

```bash
bash ~/dev/agent-skills/skills/panel/tests/test-panel-fixes.sh   # expect 35 passed
readlink -f ~/.claude/skills/panel                               # -> <repo>/skills/panel
```



## Conventions

- Canonical source is this repo; everything else is a symlink.
- Never edit a skill through an agent's symlinked path expecting it to be separate — it is the same file.
- No secrets, caches, session outputs, logs, or generated runtime state in git (see `.gitignore`).
- Skills should degrade gracefully when an optional dependency is missing.
