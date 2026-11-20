# 28. Host git settings and credentials for the containers

Status: Accepted

## Context
ADR 9 copies the host's git config once; ADR 10 keeps credentials in a store file that starts empty. On a Windows host the copy brings keys that exist only there: `http.sslBackend=schannel` (the Linux git fails on it), the Git Credential Manager (GCM) helper and its selector state. `run.sh` under Git Bash didn't even drop Windows paths, and an already seeded copy is never touched again. The store file needs one interactive git run to enter a token, and agents never have a terminal.

## Decision
- Every start (`agents/start.sh`, in the Linux and the Windows image, before `--exec` too) removes host-only keys from `shared/git/config`: `http.sslBackend`, `http.schannelCheckRevoke`, `http.schannelUseSSLCAInfo`, `credential.helperselector.*`, and `credential.helper` / `credential.<url>.helper` values `manager`, `manager-core`, `wincred`, `osxkeychain`. Each git then uses its own defaults. A failure prints one line and the start goes on. This refines ADR 9: the copy is no longer left alone for those keys.
- `run.sh` under Git Bash on a Windows host drops values with Windows paths when seeding, as `run.bat` does.
- Opt-in `AGENTS_GIT_CREDENTIALS=host`: at each launch the launcher asks the host's own credential helper, without prompting, for the login of the workspace's `https` `origin` and stores it in `shared/git/credentials`. It reads only the project's remote URL and never writes there. This refines ADR 10. Without a login nothing is written; ssh remotes are ignored.

## Consequences
- git works in Linux and Windows containers with a Windows host config, with no change to the image.
- The token is copied in plaintext to the ignored `shared/git/credentials`, only when the user asks for it.
- GCM often holds short-lived OAuth tokens (GitLab about 2 h). The copy is refreshed at each launch, and a 401 makes git erase the stale entry, so the next launch heals. A session longer than the token's life fails midway: restart, or use a personal access token (manual login, README).
- Without the opt-in the user logs in once by hand (`run-agent --exec git ls-remote <url>`); agents are told to stop and ask for that.
