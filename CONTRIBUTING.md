# Contributing to Purge

Thanks for taking the time to contribute. Purge is a solo, free, open-source
project, so outside help genuinely matters. This document covers how to
report bugs, suggest features, and submit changes.

## Before you start

- **Security or data-loss issues** (a path that could be deleted when it
  shouldn't be, a way around the safety allowlist, etc.) should **not** be
  filed as a public issue. See [SECURITY.md](SECURITY.md) for how to report
  those privately.
- For everything else — bugs, crashes, UI glitches, feature ideas — a normal
  issue is the right place to start.

## Reporting a bug

Open a [bug report](../../issues/new?template=bug_report.yml) and include:

- What you did, what you expected, and what happened instead
- Your macOS version and Purge version (About screen)
- Screenshots or a screen recording if the issue is visual
- Console/crash logs if Purge crashed

Search [existing issues](../../issues) first to avoid duplicates. If you find
a match, a 👍 or a comment with your details is more useful than a new issue.

## Suggesting a feature

Open a [feature request](../../issues/new?template=feature_request.yml) and
describe the problem you're trying to solve, not just the solution. Purge is
intentionally scoped — trash-by-default, allowlist-based cleanup, no
destructive shortcuts — so features that fit that model are more likely to
land.

## Contributing code

1. **Open an issue first** for anything beyond a small fix (typos, docs,
   obvious bugs). For larger changes, discuss the approach before writing
   code so you don't spend time on something that won't be merged.
2. **Fork the repo** and create a branch off `main`.
3. **Build and test locally** — see [Build from source](README.md#build-from-source)
   in the README.
4. **Keep changes focused.** One fix or feature per pull request. Avoid
   bundling unrelated refactors with a bug fix.
5. **Follow the existing style.** Match the surrounding Swift/SwiftUI
   conventions already in the file you're editing rather than introducing a
   new pattern.
6. **Run the test suite** before opening a PR:

   ```bash
   xcodebuild -project purge.xcodeproj -scheme purge -destination 'platform=macOS' test
   ```

7. **Open a pull request** against `main`. Describe what changed and why, and
   link the issue it addresses if there is one. Screenshots are appreciated
   for UI changes.

### A note on the deletion logic

Purge's core promise is that it never deletes something it shouldn't. Any
change touching the safety allowlist, never-delete protections, or scanning
logic will get extra scrutiny, and may take longer to review. That's by
design — please don't take it personally.

## Code of conduct

Be respectful and constructive. Disagreements about code or design are fine;
personal attacks, harassment, or bad-faith arguing are not. Issues or PRs
that don't meet this bar may be closed without further discussion.

## Questions

If something in this guide is unclear, or you're not sure whether an idea
fits, open an issue and ask. That's a valid use of an issue too.
