# Contributing

Small tool, small process.

- Bug reports: include your OS, the target host's OS, and the exact `run-on` invocation.
- Scripts are plain `bash` + `jq` on purpose — no new runtime dependency for a feature that could
  be a few lines of bash.
- CI runs `shellcheck` on every push — fix warnings before opening a PR, or explain inline why a
  specific one doesn't apply (`# shellcheck disable=SCxxxx — reason`).
- New host OS support (beyond macOS/Linux/Windows targets): welcome, needs a matching branch in
  `exec_remote()` in `run-on` plus a note in the README's install/limitations sections.
