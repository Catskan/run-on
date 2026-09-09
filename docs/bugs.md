# Two real bugs this project ran into

Kept out of the main README so it stays short — this is the deep-dive version.

## A wrong SSH identity silently authenticates as the wrong GitHub account

An automation key without a passphrase was registered on a second personal GitHub account. SSH
offers it first for _every_ connection; it gets accepted before any other key is tried, so
`git push` authenticated as the wrong identity and GitHub replied "Repository not found" — which
reads as "the repo doesn't exist" when the real problem is "you're not you."

Plain `ssh -T git@host` looked fine (agent forwarding kicked in, right identity). `git ls-remote`
on the same alias failed. Same alias, same key list, different outcome — because a plain `ssh`
exec and a `git` invocation over SSH don't necessarily negotiate keys in the same order once a
config forces one via `IdentitiesOnly`.

**Fix**: only inject `GIT_SSH_COMMAND` with that automation key when the current repo's remote
actually points at the machine that key belongs to — never globally. `run-on` checks the repo's
`git remote -v` output for that machine's address before deciding whether to export the override.

## Argument quoting across a `bash → base64 → ssh → remote shell` pipeline

A command with a quoted string (`git commit -m "fix: two words"`) or a glob
(`git log 'TAG-1*'`) would arrive truncated or glob-expanded on the wrong side — either the
container's local shell ate the glob before `run-on` ever saw it, or the remote shell re-split a
naively-forwarded string and lost the quoting.

**Fix**: a strict argv contract.

- A single argument is passed through as a verbatim shell string, so pipes/`&&`/globs are
  interpreted on the _remote_ side, as intended (`run-on auto 'cd sub && pnpm build | tee log'`).
- Two or more arguments are treated as literal argv: each token is individually re-quoted with
  `printf %q` before transport, which re-parses into an _identical_ argv on the other end
  regardless of whether the remote shell is bash or zsh.
- The whole payload — `cd`, the optional `GIT_SSH_COMMAND` guard, the command — is base64-encoded
  before hitting `ssh`, so nothing gets re-interpolated by an intermediate shell. `ssh` sees only
  `[A-Za-z0-9+/=]`, so there is nothing left to escape at that layer.
- The one residual rule: a glob you want passed _literally_ but that happens to match a file in
  the _local_ shell's current directory still needs quoting at the call site
  (`run-on auto git log 'TAG-1*'`) — that shell expands it before `run-on` ever sees argv.
