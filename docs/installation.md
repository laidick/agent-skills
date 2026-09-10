# Installation

## Requirements

- `bash` 4+
- `git`
- `jq` (panel)
- `python3` (panel — charter validation)

## Quick start

```bash
git clone <this-repo> ~/dev/agent-skills
cd ~/dev/agent-skills
./install.sh --check    # dry run
./install.sh            # apply
```

The repo may live anywhere; the installer resolves its own location. `~/dev/agent-skills` is the convention on this host.

## Supported agents

| Agent | Skill directory | Auto-created |
|-------|-----------------|--------------|
| Claude Code | `~/.claude/skills/` | no |
| Pi | `~/.pi/agent/skills/` | no |
| Hermes | `~/.hermes/skills/productivity/` | no |
| Codex | `~/.codex/skills/` | yes, if `~/.codex` exists |
| Gemini | `~/.gemini/skills/` | yes, if `~/.gemini` exists |
| Gemini (alt) | `~/.gemini/config/skills/` | no |
| OpenCode | `~/.config/opencode/skills/` | yes, if `~/.config/opencode` exists |
| Generic | `~/.agents/skills/` | no |

An agent whose directory is absent is skipped — the installer never creates a stray agent root.

## Commands

```bash
./install.sh              # install/repair every skill
./install.sh panel        # only the named skill(s)
./install.sh --check      # preview; changes nothing
./install.sh --list       # show discovered skills and live targets
```

## What the installer does

1. For each skill, symlink it into every present agent directory.
2. Repair any symlink pointing somewhere else (e.g. an older canonical path).
3. Leave correct symlinks untouched.
4. Refuse to replace a real directory/file that is not a symlink — it reports an error and continues, so one obstruction never blocks the rest.
5. Run the skill's own `install.sh`, if present, for hooks/plugins/systemd wiring. `AGENT_SKILLS_REPO` is exported to it.

## After installing

Restart long-running agents so they re-scan skills:

```bash
hermes gateway restart     # or however the gateway is managed
```

Hermes caches the rendered skill list in `~/.hermes/.skills_prompt_snapshot.json`.
It is keyed by a manifest of skill files and rebuilds automatically. To force it:

```bash
rm -f ~/.hermes/.skills_prompt_snapshot.json
```

## Verifying

```bash
# every agent target resolves to this repo
for a in ~/.claude/skills ~/.pi/agent/skills ~/.hermes/skills/productivity \
         ~/.codex/skills ~/.gemini/skills ~/.gemini/config/skills \
         ~/.config/opencode/skills; do
  for s in panel wiki; do
    [ -e "$a/$s" ] && printf '%-45s -> %s\n' "$a/$s" "$(readlink -f "$a/$s")"
  done
done

# panel regression suite
bash ~/dev/agent-skills/skills/panel/tests/test-panel-fixes.sh
```

Confirm the Hermes routing signal survives the 60-char truncation:

```bash
python3 -c "
import os,sys; sys.path.insert(0, os.path.expanduser('~/.hermes/hermes-agent'))
from agent.prompt_builder import build_skills_system_prompt
print([l.strip() for l in build_skills_system_prompt().splitlines()
       if l.strip().startswith('- panel:')])"
```

The trigger phrase must appear before the `...`.
