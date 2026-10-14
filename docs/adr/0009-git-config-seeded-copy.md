# 9. Git config: seeded copy, mounted read-write

Status: Accepted

## Context
Agents commit, so they need the user's git identity and settings. Mounting the host config read-only stops changing settings inside the container. Mounting it read-write lets a container change the host's config. A host config can also contain host-only entries, such as Windows paths to credential helpers and editors.

## Decision
On first launch the launcher copies the host's global git config to `shared/git/config`. It is mounted read-write as the container's XDG git dir (`~/.config/git`). It's a directory mount, because `git config` writes via rename, which fails on a single-file bind mount. On Windows hosts, values containing Windows paths are removed from the copy. Linux configs are copied as is. The copy is never overwritten. Deleting it re-seeds it.

## Consequences
- Identity and settings work immediately, and changes made in a container persist without touching the host.
- Later changes to the host config don't propagate until the copy is deleted.
- Linux host entries that point at host-only binaries may need editing inside the container.
