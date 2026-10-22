// Reads the 52 Tools-sheet tiles straight from the app's catalog so the website never drifts from it.
import { readFileSync } from "node:fs";
const SRC = new URL("../../Sources/SuperPDFCore/Catalogs/ToolCatalog.swift", import.meta.url);
export const SECTIONS = [
  ["pages", "Pages", "#007AFF"], ["convert", "Convert", "#34C759"], ["edit", "Edit", "#FF9500"], ["markUp", "Mark up", "#FFCC00"],
  ["signAndFill", "Sign & fill", "#AF52DE"], ["protect", "Protect", "#FF3B30"], ["fixAndCheck", "Fix & check", "#30B0C7"], ["scan", "Scan", "#A2845E"],
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
