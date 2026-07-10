# Contributing to MongrelDB PowerShell

Thanks for taking the time to help the MongrelDB PowerShell client. This
document describes how to propose a change, what we expect from a pull request,
and the coding standards that apply to the codebase.

If anything here is unclear or out of date, open an issue or a PR.

## Code of conduct

Be kind, be specific, assume good faith. Disagree about the technical details,
not the person. Public reviews stay focused on the diff.

## How to propose a change

The MongrelDB PowerShell client uses a standard **fork -> branch -> pull
request** workflow on GitHub.

1. **Fork** [`visorcraft/MongrelDB-PowerShell`](https://github.com/visorcraft/MongrelDB-PowerShell)
   to your GitHub account.
2. **Clone** your fork and add the upstream remote.
3. **Branch** from `master`. Pick a descriptive, kebab-case branch name:
   `fix-query-decode`, `feature/vector-search`, `docs/auth-guide`.
4. **Make focused commits.** One logical change per commit. Run the preflight
   (see below) before pushing.
5. **Open a pull request** against `master` on `visorcraft/MongrelDB-PowerShell`.

## Before you push: preflight

Run the full CI preflight locally:

```sh
# Validate the manifest
pwsh -Command "Test-ModuleManifest -Path src/MongrelDB.psd1"

# Offline wire-shape unit tests (no daemon needed)
pwsh -File tests/wire_shape_test.ps1

# Live integration tests (requires a running mongreldb-server; self-skips)
pwsh -File tests/live_test.ps1
```

If a check fails, fix the root cause - don't silence errors or skip the test.

## What we look for in a review

- The change does one thing and does it well.
- Behavior changes ship with tests. New client behavior: a unit test alongside
  the code. Wire-format changes: cover the exact outgoing JSON keys.
  Daemon-dependent coverage: a live test that skips cleanly when no server is
  available.
- The change keeps this repo a thin client over `mongreldb-server`. Don't
  re-implement storage, indexing, WAL, or SQL planning logic here.
- Documentation is updated alongside the code (`docs/`, `README.md`) if the
  change affects users.
- Commits have clear messages (see below).

## Coding standards

### PowerShell

- **Version.** Compatible with Windows PowerShell 5.1 and PowerShell 7+ (Core).
  Avoid 7-only syntax in the module (e.g. ternary operators) unless guarded.
- **Dependencies.** None beyond built-in cmdlets. Do not pull in a third-party
  HTTP or JSON module.
- **Naming.** Use approved Verb-Noun verbs for every exported function. Run
  `Get-Verb` to check. Function names use the `MongrelDB` noun suffix
  (`Get-MongrelDBHealth`).
- **Errors.** Throw via the internal `New-MongrelDBException` helper so callers
  can catch by category. Set `$ErrorActionPreference = 'Stop'` in tests.
- **Style.** Follow the existing style: PascalCase parameters, camelCase
  variables, here-strings for long SQL, `[CmdletBinding()]` on every function.

### Commit messages

- Subject line: imperative mood, <= 72 characters, no trailing period.
- Body: wrap at 72 characters. Explain *why*, not *what*.
- Reference issues with `Fixes #123` / `Refs #123` when applicable.
- **Never** add AI/assistant attribution (no `Co-Authored-By`, no `Generated
  with`, no tool names).

## Security

If you find a vulnerability, **do not** open a public GitHub issue. Report it
privately through GitHub's private vulnerability reporting - the repository's
**Security** tab -> **Report a vulnerability**. The full policy is in
[`SECURITY.md`](SECURITY.md).

## Licensing

The MongrelDB PowerShell client is dual-licensed under MIT OR Apache-2.0. By
contributing, you agree that your changes are made available under the same
license.

Thanks again - looking forward to your PR.
