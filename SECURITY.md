# Security Policy

Purge is an open-source macOS app that deletes files, so security and safety
are the whole point. This document explains how the app protects you and how
to report a problem.

## Reporting a vulnerability

If you find a security issue, a safety gap in the deletion logic, or a path
that could be deleted when it shouldn't be, please report it.

- Open a [private security advisory](https://github.com/jithin-sabu/purge-app/security/advisories/new), or
- Email the maintainer at the address listed on the GitHub profile.

Please do not open a public issue for a security or data-loss vulnerability
until it has been addressed. For non-security bugs, a normal issue is fine.

I aim to respond within a few days. This is a solo, free project, so please be
patient, but safety reports get priority over everything else.

## How Purge protects you

- **Trash by default.** Nothing is permanently deleted. Items are moved to the
  macOS Trash, so anything removed can be restored until you empty it yourself.
- **Allowlist-based deletion.** Only paths that match an explicit safety
  allowlist are ever eligible for cleanup. Anything not on the list is never
  touched.
- **Never-delete protections.** Critical locations are blocked outright, and
  certain protected folders are only ever cleaned by their contents, never
  removed themselves.
- **You choose what goes.** The app surfaces what is reclaimable and you select
  what to clear. It does not auto-delete without your action.
- **Open source.** The full deletion logic, including the allowlist, is in this
  repo for you to read or build from source yourself.

## Verifying your download

Each release ships with a `.sha256` checksum file. After downloading the DMG:

```
shasum -a 256 -c Purge.dmg.sha256
```

This confirms the file you downloaded matches the published release. Note that
the app is currently unsigned, so on first launch macOS will block it. To open
it, go to System Settings > Privacy & Security, scroll to the Security section,
and click Open Anyway next to Purge. See the README for the full step-by-step.

## Supported versions

Security and safety fixes are applied to the latest release. Please update to
the most recent version before reporting an issue.