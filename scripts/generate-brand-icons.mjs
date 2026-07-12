#!/usr/bin/env node
/**
 * Generates PNG brand icons from simple-icons for bundling in the macOS app.
 * Run: npm run generate:icons
 *
 * Uses simple-icons v14 for most brands and simple-icons-v16 for newer icons (e.g. cursor).
 * Slugs missing from simple-icons can ship SVG sources in scripts/brand-icon-sources/.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import * as simpleIcons from "simple-icons";
import * as simpleIconsV16 from "simple-icons-v16";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");
const manifestPath = path.join(repoRoot, "purge/Resources/brand-icon-manifest.json");
const outDir = path.join(repoRoot, "purge/Resources/BrandIcons");
const supplementalDir = path.join(repoRoot, "scripts/brand-icon-sources");
const size = 56;

const iconPackages = [simpleIcons, simpleIconsV16];

const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const slugs = manifest.slugs ?? [];

fs.mkdirSync(outDir, { recursive: true });

function iconForSlug(slug) {
  for (const pkg of iconPackages) {
    const bySlug = Object.values(pkg).find(
      (icon) => icon && typeof icon === "object" && icon.slug === slug
    );
    if (bySlug) return bySlug;
    const key = `si${slug.charAt(0).toUpperCase()}${slug.slice(1)}`;
    if (pkg[key]) return pkg[key];
  }
  return null;
}

function svgForIcon(icon, fillHex) {
  return `<svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="${icon.path}" fill="#${fillHex}"/></svg>`;
}

async function renderSupplementalSvg(slug, variant) {
  const suffix = variant === "dark" ? "-dark" : "";
  const preferred = path.join(supplementalDir, `${slug}${suffix}.svg`);
  const fallback = path.join(supplementalDir, `${slug}.svg`);
  const svgPath = fs.existsSync(preferred) ? preferred : fallback;
  if (!fs.existsSync(svgPath)) return false;

  const outName = variant === "dark" ? `${slug}-dark.png` : `${slug}.png`;
  await sharp(svgPath)
    .resize(size, size, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toFile(path.join(outDir, outName));
  return true;
}

let ok = 0;
let failed = [];

for (const slug of slugs) {
  const icon = iconForSlug(slug);
  if (!icon) {
    const lightOk = await renderSupplementalSvg(slug, "light");
    const darkOk = await renderSupplementalSvg(slug, "dark");
    if (lightOk && darkOk) {
      ok++;
      continue;
    }
    failed.push(slug);
    continue;
  }
  const lightSvg = svgForIcon(icon, icon.hex);
  const darkSvg = svgForIcon(icon, "FFFFFF");
  await sharp(Buffer.from(lightSvg)).resize(size, size).png().toFile(path.join(outDir, `${slug}.png`));
  await sharp(Buffer.from(darkSvg)).resize(size, size).png().toFile(path.join(outDir, `${slug}-dark.png`));
  ok++;
}

console.log(`Generated ${ok} brand icons in ${outDir}`);
if (failed.length) {
  console.warn(`No simple-icons entry for: ${failed.join(", ")}`);
  process.exitCode = failed.length === slugs.length ? 1 : 0;
}
