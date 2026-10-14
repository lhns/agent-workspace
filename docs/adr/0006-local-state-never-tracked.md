# 6. Local state is never tracked; updates are a plain `git pull`

Status: Accepted

## Context
Users update the setup by pulling. If their keys, configs or tweaks live in tracked files, every pull conflicts and `git status` invites them to commit secrets.

## Decision
- Templates are tracked and the real files are ignored: `.env.example` → `.env`. The launcher creates `.env` and refuses to run until it's been edited. After a pull, it warns about keys that are new in the template.
- All runtime state is ignored: harness state dirs, `shared/`, and the workspace contents.
- Local changes to the compose setup go in the ignored `compose.override.yaml`, which compose merges automatically.
- `.gitattributes` pins line endings so checkouts never look modified.

## Consequences
- `git pull` always applies cleanly and `git status` stays clean.
- New settings in `.env.example` must be copied into `.env` by hand. The warning points them out.
