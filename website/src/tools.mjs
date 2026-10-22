// Reads the 52 Tools-sheet tiles straight from the app's catalog so the website never drifts from it.
import { readFileSync } from "node:fs";
const SRC = new URL("../../Sources/SuperPDFCore/Catalogs/ToolCatalog.swift", import.meta.url);
// [key, title, pill] in the sheet's order. The pill is the section's pastel pair in the app's brand palette
// (SPColor.pills / docs/mockups/src/shared.css); style.css defines --s-<pill>, --f-<pill> and --i-<pill>.
export const SECTIONS = [
  ["pages", "Pages", "sky"], ["convert", "Convert", "mint"], ["edit", "Edit", "peach"], ["markUp", "Mark up", "lemon"],
  ["signAndFill", "Sign & fill", "lavender"], ["protect", "Protect", "coral"], ["fixAndCheck", "Fix & check", "aqua"], ["scan", "Scan", "pink"],
];
export function readTools() {
  const re = /ToolTile\(\.(\w+),\s*\.(\w+),\s*"([^"]*)",\s*"([^"]*)",\s*synonyms:\s*\[([^\]]*)\]/g;
  const out = [];
  for (const m of readFileSync(SRC, "utf8").matchAll(re)) {
    out.push({ id: m[1], section: m[2], name: m[3], hint: m[4], synonyms: [...m[5].matchAll(/"([^"]*)"/g)].map((s) => s[1]) });
  }
  if (out.length !== 52) throw new Error(`expected 52 tiles, parsed ${out.length}`);
  return out;
}
