#!/usr/bin/env node
// Fails when a view steps around the design system: raw colours, SwiftUI's
// hierarchical greys, point sizes or tracking on text, literal corner radii, or
// raw gaps (padding, stack spacing, spacers), including radii and gaps kept in
// a named constant. The tokens live in purge/Theme/AppColors.swift and
// purge/Views/AppStyle.swift; see docs/design-system.md. Add
// `design-lint: allow` to a line to exempt it.
//
// Usage: node scripts/lint-design-tokens.mjs

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
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
    pattern: /\.(tracking|kerning)\(/,
    message: "literal tracking; the AppStyle.Typography style sets it",
  },
  {
    pattern: /\b(AppButtonStyle|SolidDestructiveButtonStyle|OnboardingCapsuleButtonStyle|statusTextButton)\b/,
    message: "removed button style; use PurgeButtonStyle (.purge(...))",
  },
];

// Gaps: a number inside padding, stack spacing or a spacer's length. 0 means no
// gap and passes, and so does a number that scales a token (`* 2`, `/ 2`).
// `String.padding(toLength:)` pads text, not a view.
const gapCalls = /\.(padding|safeAreaPadding|contentMargins)\((?!toLength:)|\bEdgeInsets\(/g;
const gapLabels = /\b(spacing|horizontalSpacing|verticalSpacing|minLength):/g;
const gapMessage = "raw gap; use AppStyle.Spacing";
// A frame on an empty view is a gap too: `Spacer().frame(height: 12)`.
const gapReceiver = /\bSpacer\(|\bColor\.clear\b/;
// Constants that hold a radius or a gap, stored or computed. A radius counts
// when its name says corner or when the same file passes it to `cornerRadius`,
// so a blur radius does not. A gap counts by its name.
const declaration = /\b(?:let|var)\s+(\w+)\s*(?::\s*[\w.?]+)?\s*=(?!=)\s*(.*)$/;
const computedProperty = /\bvar\s+(\w+)\s*:\s*CGFloat\s*\{/;
const parameterDefault = /\b(\w+)\s*:\s*CGFloat\s*=(?!=)\s*([^,)]*)/g;
const cornerName = /cornerRadius$/i;
const cornerUses = [
  /\bcornerRadius:\s*(?:[Ss]elf\.)?(\w+)\s*[,)]/g,
  /\.cornerRadius\(\s*(?:[Ss]elf\.)?(\w+)\s*[,)]/g,
];
const gapName = /(padding|spacing|inset|gap|margin)s?$/i;

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

// The line with its comment and the contents of its strings removed, so a
// number in a label or a note doesn't count.
function code(line) {
  return line.replace(/"(?:[^"\\]|\\.)*"/g, '""').replace(/\/\/.*$/, "");
}

// The text of a call's arguments from `start`, which sits just past the opening
// parenthesis, to the closing one. A labelled argument stops at its comma
// instead. Reads on into later lines when the call spans them.
function argumentText(lines, index, start, labelled) {
  let text = "";
  let depth = 0;
  let column = start;
  for (let i = index; i < lines.length && i < index + 8; i += 1) {
    const line = code(lines[i]);
    for (; column < line.length; column += 1) {
      const char = line[column];
      if (char === "(" || char === "[") depth += 1;
      else if (char === ")" || char === "]") {
        if (depth === 0) return text;
        depth -= 1;
      } else if (char === "," && depth === 0 && labelled) return text;
      text += char;
    }
    text += "\n";
    column = 0;
  }
  return text;
}

// The text with the condition of each `condition ? a : b` taken out, so the 1
// in `count > 1 ? small : 0` is not read as a gap. Both results stay.
function withoutConditions(text) {
  let result = text;
  for (let match = /\s\?\s/.exec(result); match; match = /\s\?\s/.exec(result)) {
    const head = result.slice(0, match.index);
    const start = Math.max(...["?", ":", ",", "(", "=", "\n"].map((char) => head.lastIndexOf(char))) + 1;
    result = result.slice(0, start) + " " + result.slice(match.index + match[0].length);
  }
  return result;
}

// A number that scales a token, as in `tileGap / 2`, passes. A number beside
// another number, as in `12 / 2`, does not.
function hasRawNumber(text) {
  const values = withoutConditions(text);
  for (const match of values.matchAll(/(?<![\w.])\d+(?:\.\d+)?(?![\w.])/g)) {
    if (parseFloat(match[0]) === 0) continue;
    const before = values.slice(0, match.index).trimEnd();
    const after = values.slice(match.index + match[0].length).trimStart();
    if (/[*/]$/.test(before) && !/(?<![\w.])\d+(?:\.\d+)?\s*[*/]$/.test(before)) continue;
    if (/^[*/]/.test(after) && !/^[*/]\s*\d/.test(after)) continue;
    return true;
  }
  return false;
}

// The values a computed property can return: each `return` expression, or the
// whole body when it is a single expression.
function computedValues(lines, index, start) {
  let body = "";
  let depth = 1;
  let column = start;
  for (let i = index; i < lines.length && i < index + 20 && depth > 0; i += 1) {
    const line = code(lines[i]);
    for (; column < line.length && depth > 0; column += 1) {
      const char = line[column];
      if (char === "{") depth += 1;
      else if (char === "}") depth -= 1;
      if (depth > 0) body += char;
    }
    body += "\n";
    column = 0;
  }
  const returns = [...body.matchAll(/\breturn\s+([^\n};]+)/g)].map((match) => match[1]);
  return returns.length > 0 ? returns.join("\n") : body;
}

// Names this file passes to `cornerRadius`, so a constant used as one counts as
// a radius whatever it is called.
function cornerRadiusNames(lines) {
  const text = lines.map(code).join("\n");
  return new Set(cornerUses.flatMap((pattern) => [...text.matchAll(pattern)].map((match) => match[1])));
}

function gapProblems(lines, index, cornerNames) {
  const line = code(lines[index]);
  const found = new Set();
  for (const match of line.matchAll(gapCalls)) {
    if (hasRawNumber(argumentText(lines, index, match.index + match[0].length, false))) found.add(gapMessage);
  }
  for (const match of line.matchAll(gapLabels)) {
    if (hasRawNumber(argumentText(lines, index, match.index + match[0].length, true))) found.add(gapMessage);
  }
  for (const match of line.matchAll(/\.frame\(/g)) {
    const before = line.slice(0, match.index);
    const receiver = before.trim() === "" ? chainStart(lines, index) : before;
    if (!gapReceiver.test(receiver)) continue;
    if (hasRawNumber(argumentText(lines, index, match.index + match[0].length, false))) found.add(gapMessage);
  }
  const named = [];
  const declared = line.match(declaration);
  if (declared) named.push([declared[1], declared[2]]);
  const computed = line.match(computedProperty);
  if (computed) named.push([computed[1], computedValues(lines, index, computed.index + computed[0].length)]);
  for (const match of line.matchAll(parameterDefault)) named.push([match[1], match[2]]);
  for (const [name, value] of named) {
    if (!hasRawNumber(value)) continue;
    if (cornerName.test(name) || cornerNames.has(name)) {
      found.add("corner radius in a constant; use AppStyle.Radius");
    } else if (gapName.test(name)) {
      found.add("raw gap in a constant; use AppStyle.Spacing");
    }
  }
  return [...found];
}

const problems = [];
for (const file of swiftFiles(sourceRoot)) {
  const rel = relative(root, file);
  if (tokenFiles.has(rel)) continue;
  const lines = readFileSync(file, "utf8").split("\n");
  const cornerNames = cornerRadiusNames(lines);
  lines.forEach((line, index) => {
    if (line.includes("design-lint: allow") || line.trimStart().startsWith("//")) return;
    const report = (message) => problems.push(`${rel}:${index + 1}: ${message}\n    ${line.trim()}`);
    for (const rule of rules) {
      if (!rule.pattern.test(line)) continue;
      if (rule.skipIcons && (line.includes("Image(") || chainStart(lines, index).includes("Image("))) continue;
      report(rule.message);
    }
    gapProblems(lines, index, cornerNames).forEach(report);
  });
}

if (problems.length > 0) {
  console.error(problems.join("\n"));
  console.error(`\n${problems.length} design token problem(s).`);
  process.exit(1);
}
console.log("Design tokens: no problems.");
