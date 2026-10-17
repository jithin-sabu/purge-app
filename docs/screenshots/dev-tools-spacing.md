# Dev Tools spacing, issue #163

Captured on macOS 27 with the actual `DevToolsView`, hosted at 720 × 560 points
with fixed sample scan results. Before uses the view from `9fc4c78`; after uses
the spacing fix. No real files were scanned or cleaned for these captures.

The single-runtime example reproduces the reported Check First filter case.

| Appearance | Before | After |
| --- | --- | --- |
| Light | [Before](dev-tools-spacing-before-light.png) | [After](dev-tools-spacing-after-light.png) |
| Dark | [Before](dev-tools-spacing-before-dark.png) | [After](dev-tools-spacing-after-dark.png) |

The matrices show All, Safe to Clean, and Check First from left to right.
Each row checks a different set of results: Developer Projects alone,
iOS Simulators alone, Simulator Runtimes alone, all three sections together,
and a standard tool row followed by all three sections. The sample project
contains both a safe artifact and a Check First artifact. Simulators and runtimes
are always Check First, so their isolated Safe to Clean examples are empty.

| Appearance | Before, all cases | After, all cases |
| --- | --- | --- |
| Light | [Before matrix](dev-tools-spacing-before-light-matrix.png) | [After matrix](dev-tools-spacing-after-light-matrix.png) |
| Dark | [Before matrix](dev-tools-spacing-before-dark-matrix.png) | [After matrix](dev-tools-spacing-after-dark-matrix.png) |

Headings and cards now share the Select All row's left edge. The first heading
has no extra top padding. Later headings use `Spacing.medium` above them, and
the heading's `Spacing.xxSmall` bottom padding plus the card's `Spacing.xxSmall`
top inset make an 8-point gap. The list scrolls to its first real row after a
scan, rather than reserving a separate invisible row.

## Shared spacing across scan tabs

The same card insets now apply to App Caches, Large Files and Dev Tools through
`ScanListRowInsets.standard`. App Caches and Large Files also start with real
results, removing the extra space their invisible top rows occupied.

These contact sheets compare all three tabs. App Caches covers All, Safe to
Clean and Check First. Large Files covers All, a single PDF, duplicate groups,
a matching search and an empty search. Its captures use the external-header
layout used by the app, including Select All, under a shared page header with
fixed sample totals. All captures use sample data without scanning or cleaning
real files.

| Appearance | Before | After |
| --- | --- | --- |
| Light | [Before](scan-tabs-spacing-before-light.png) | [After](scan-tabs-spacing-after-light.png) |
| Dark | [Before](scan-tabs-spacing-before-dark.png) | [After](scan-tabs-spacing-after-dark.png) |
