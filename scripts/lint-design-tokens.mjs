#!/usr/bin/env node
// Fails when a view steps around the design system: raw colours, SwiftUI's
// hierarchical greys, point sizes on text, or literal corner radii. The tokens
// live in purge/Theme/AppColors.swift and purge/Views/AppStyle.swift; see
// docs/design-system.md. Add `design-lint: allow` to a line to exempt it.
//
// Usage: node scripts/lint-design-tokens.mjs

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const sourceRoot = join(root, "purge");
const tokenFiles = new Set([
  "purge/Theme/AppColors.swift",
  "purge/Views/AppStyle.swift",
  "purge/Views/PurgeButtonStyle.swift",
]);

const rules = [
  {
    pattern: /Color\((red|green|blue|hue|white):|\b0x[0-9A-Fa-f]{6}\b/,
    message: "raw colour; use an AppColors token",
  },
  {
    pattern: /foreground(Style|Color)\(\.(primary|secondary|tertiary|quaternary)\)|\bColor\.(primary|secondary)\b/,
    message: "SwiftUI hierarchical grey; use AppColors.textPrimary/Secondary/Tertiary",
  },
  {
    pattern: /\.font\(\.(largeTitle|title|title2|title3|headline|body|callout|subheadline|footnote|caption|caption2)\b|\.system\(\.(largeTitle|title|title2|title3|headline|body|callout|subheadline|footnote|caption|caption2)\b/,
    message: "SwiftUI text style; use an AppStyle.Typography style",
    skipIcons: true,
  },
  {
    pattern: /\.system\(size:/,
    message: "point size on text; use an AppStyle.Typography style",
    skipIcons: true,
  },
  {
    pattern: /cornerRadius: *\d|\.cornerRadius\( *\d/,
    message: "literal corner radius; use AppStyle.Radius",
  },
  {
    pattern: /\b(AppButtonStyle|SolidDestructiveButtonStyle|OnboardingCapsuleButtonStyle|statusTextButton)\b/,
    message: "removed button style; use PurgeButtonStyle (.purge(...))",
  },
];

function swiftFiles(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return swiftFiles(path);
    return name.endsWith(".swift") ? [path] : [];
  });
}

// The view a modifier chain hangs off. SF Symbols size their glyph with a
// font, which is fine, so rules marked skipIcons ignore chains that start at an
// Image. When the receiver's initializer spans several lines, walk back to its
// opening parenthesis and return all of them, so `Image(` on the first line counts.
function chainStart(lines, index) {
  let i = index;
  while (i > 0 && lines[i].trimStart().startsWith(".")) i -= 1;
  let receiver = lines[i];
  let depth = parenBalance(lines[i]);
  while (depth < 0 && i > 0) {
    i -= 1;
    receiver = lines[i] + "\n" + receiver;
    depth += parenBalance(lines[i]);
  }
  return receiver;
}

function parenBalance(line) {
  let balance = 0;
  for (const char of line) {
    if (char === "(") balance += 1;
    else if (char === ")") balance -= 1;
  }
  return balance;
}

const problems = [];
for (const file of swiftFiles(sourceRoot)) {
  const rel = relative(root, file);
  if (tokenFiles.has(rel)) continue;
  const lines = readFileSync(file, "utf8").split("\n");
  lines.forEach((line, index) => {
    if (line.includes("design-lint: allow") || line.trimStart().startsWith("//")) return;
    for (const rule of rules) {
      if (!rule.pattern.test(line)) continue;
      if (rule.skipIcons && (line.includes("Image(") || chainStart(lines, index).includes("Image("))) continue;
      problems.push(`${rel}:${index + 1}: ${rule.message}\n    ${line.trim()}`);
    }
  });
}

if (problems.length > 0) {
  console.error(problems.join("\n"));
  console.error(`\n${problems.length} design token problem(s).`);
  process.exit(1);
}
console.log("Design tokens: no problems.");
