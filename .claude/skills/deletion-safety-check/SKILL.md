---
name: deletion-safety-check
description: Safety review for any Purge change that can affect what gets deleted, such as the allowlist, safety levels, scan policies, explanations.json, FileDeleter, scheduled cleaning, or the root helper. Use before you open or merge such a PR, and when asked whether a deletion change is safe.
---

# Deletion safety check

Purge's promise is that it never deletes something it shouldn't. This check finds what a change could newly remove, and proves the change is safe with a test.

Before you start, read the newest entries in `docs/safety-notes.md`. They show the mistakes that already happened once.

## Answer each question

1. **What can be removed now that couldn't be before?** List real example paths on a real Mac, not only the pattern in the code.

2. **Is each new Safe item only rebuildable data?** `.safe` items go into Clean Safe Items and scheduled cleans without asking. Look inside each folder as a real app writes it. If it can hold settings, installed tools or plugins, keys, history, databases, projects, or offline downloads, it must be `.medium` (Check First) or not offered.
   Past examples: `~/.gem` held installed gems, and VS Code `workspaceStorage` held AI chat history.

3. **Does every removal still go through `DeletionSafetyPolicy.evaluate(_:)`?** Look for any new code that deletes, moves, or trashes files some other way.

4. **Can it be undone?** Files moved to the Trash can come back. Anything removed for good needs clear wording in the UI and the docs.

5. **What else reads this?**
   - `purge/Resources/explanations.json` and its zh-Hans text in `purge/zh-Hans.lproj/Explanations.strings`
   - the purgemac.com/safety page, which is built from `DeletionSafetyPolicy.swift`, `explanations.json`, and `ProjectArtifactCatalog.swift`
   - `PurgeTests/AllowlistAuditTests.swift` and `PurgeTests/DeletionSafetyPolicyTests.swift`
   - claims in `README.md` and `SECURITY.md`

6. **Does it run when nobody is watching?** Scheduled cleans and launch-time actions run without the user. Check that a half-finished or repeated run can't remove more than one careful run would.

## Prove it

Add or extend a test in `PurgeTests/` that fails if the key safety fact is wrong. Put it in `DeletionSafetyPolicyTests.swift` or `AllowlistAuditTests.swift`, or in the test file for the scan policy you changed. For example: "`~/.gem` is never `.safe`".

Run it with `xcodebuild -project purge.xcodeproj -scheme purge -destination 'platform=macOS' test`. If you can't run it (for example, in a Linux cloud session), write "not run here" and leave it to CI or a Mac.

## Report

Put this in your reply, and put the short version under `## Blast radius` in the PR:

- **What can now be removed:** example paths, and each one's safety level.
- **Why it is safe:** the one fact, and the test that proves it.
- **Risks:** anything not proven, with `file:line`.
- **Checked and fine:** what you looked at and ruled out.
