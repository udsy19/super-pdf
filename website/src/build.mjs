// Builds website/index.html (+ content-hashed style.css / app.js URLs) and src/og.html from this folder.
//   node website/src/build.mjs            then   node website/src/render-assets.mjs   for og.png and the PNG favicons
import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { readTools, SECTIONS } from "./tools.mjs";

const here = (p) => new URL(p, import.meta.url);
const out = (p) => new URL("../" + p, import.meta.url);
const SITE = "https://udsy19.github.io/super-pdf/";
const DMG = "https://github.com/udsy19/super-pdf/releases/latest/download/SuperPDF.dmg";
const REPO = "https://github.com/udsy19/super-pdf";
const INSTALL = "curl -fsSL https://udsy19.github.io/super-pdf/install.sh | bash";
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

const tools = readTools();
const byId = Object.fromEntries(tools.map((t) => [t.id, t]));
const SEC = Object.fromEntries(SECTIONS.map(([k, title, pill]) => [k, { title, pill }]));

// ---------- glyphs: one per Tools section (the app's section symbols, drawn), plus the few the page needs ----------
const GLYPH = {
  pages: '<rect x="4" y="7" width="11" height="14" rx="2"/><path d="M9 7V5a2 2 0 012-2h5l4 4v10a2 2 0 01-2 2h-3"/>',
  convert: '<path d="M19.5 10A8 8 0 005.6 7.1L4 9M4 4.5V9h4.5M4.5 14a8 8 0 0013.9 2.9L20 15m0 4.5V15h-4.5"/>',
  edit: '<path d="M4 20l1.2-4.4L15.8 5a2 2 0 012.8 0l.4.4a2 2 0 010 2.8L8.4 18.8z"/>',
  markUp: '<path d="M14.5 4.5l5 5-7.5 7.5H7V12zM4 20h9"/>',
  signAndFill: '<path d="M3 17c3-8 5-9 6-6s-2 7 1 6 3-5 5-4 2 3 6 1"/>',
  protect: '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 018 0v3"/>',
  fixAndCheck: '<path d="M14.8 6.2a4 4 0 00-5.3 5.3L4 17l3 3 5.5-5.5a4 4 0 005.3-5.3l-2.6 2.6-2.3-.7-.7-2.3z"/>',
  scan: '<path d="M4 8V5a1 1 0 011-1h3M16 4h3a1 1 0 011 1v3M20 16v3a1 1 0 01-1 1h-3M8 20H5a1 1 0 01-1-1v-3M7 12h10"/>',
  download: '<path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/>',
  arrow: '<path d="M5 12h14M13 6l6 6-6 6"/>',
  sidebar: '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="M9 5v14"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  undo: '<path d="M9 14L4 9l5-5M4 9h10a6 6 0 010 12h-3"/>',
  trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
  files: '<rect x="4" y="7" width="11" height="14" rx="2"/><path d="M9 7V5a2 2 0 012-2h5l4 4v10a2 2 0 01-2 2h-3"/>',
  grid: '<rect x="4" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.5"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4 4"/>',
  check: '<path d="M6 12.5l4 4 8-9"/>',
};
const icon = (k, cls = "") => `<svg class="g${cls ? " " + cls : ""}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${GLYPH[k]}</svg>`;
const badge = (section) => `<span class="badge" style="--s:var(--s-${SEC[section].pill})">${icon(section)}</span>`;

// ---------- page thumbnails (documents stay white in both appearances, as in the app) ----------
const ln = (y, w, c = "#CDD2DC", h = 3, x = 11) => `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="1.5" fill="${c}"/>`;
const body = (ys, ws) => ys.map((y, i) => ln(y, ws[i % ws.length])).join("");
const page = (inner, cls = "") => `<svg class="pg${cls ? " " + cls : ""}" viewBox="0 0 85 110" aria-hidden="true"><rect width="85" height="110" fill="#fff"/>${inner}</svg>`;
const leaseLines = ln(12, 42, "#394055", 5) + ln(21, 26, "#9AA1B2", 2.5) + body([31, 37, 43, 53, 59, 65, 75, 81, 87, 97], [63, 60, 46, 63, 57, 40, 63, 59, 34, 50]);
const P = {
  lease: page(leaseLines),
  letter: page(ln(12, 30, "#394055", 5) + body([24, 30, 36, 42], [63, 58, 61, 30]) + `<rect x="11" y="52" width="63" height="22" rx="2" fill="#EEF1F6"/>` + body([82, 88, 94], [60, 63, 41])),
  table: page(ln(12, 36, "#394055", 5) + `<rect x="11" y="24" width="63" height="9" fill="#1FAF68"/>` + [33, 42, 51, 60, 69, 78].map((y) => `<rect x="11" y="${y}" width="63" height="9" fill="${y % 18 === 15 ? "#F3F5F8" : "#fff"}" stroke="#DDE1E8" stroke-width=".6"/>`).join("") + [32, 53].map((x) => `<rect x="${x}" y="24" width=".6" height="63" fill="#DDE1E8"/>`).join("") + ln(95, 30, "#9AA1B2", 2.5)),
  blacked: page(ln(12, 42, "#394055", 5) + ln(21, 26, "#9AA1B2", 2.5) + ln(31, 63) + `<rect x="40" y="36" width="25" height="5" rx="1" fill="#111"/>` + ln(37, 27) + ln(47, 18) + `<rect x="31" y="46" width="34" height="5" rx="1" fill="#111"/>` + ln(57, 63) + ln(63, 12) + `<rect x="25" y="62" width="40" height="5" rx="1" fill="#111"/>` + body([73, 79, 85], [63, 57, 40])),
  signed: page(leaseLines.replace(ln(87, 34) + ln(97, 50), "") + `<rect x="11" y="96" width="30" height=".8" fill="#9AA1B2"/><rect x="46" y="96" width="28" height=".8" fill="#9AA1B2"/><path d="M45 93c2-10 5-12 6-7s-3 8 1 7 4-7 6-6 2 4 5 1c1-1 2-4 4-1 1 1 3 1 5-2" fill="none" stroke="#2A44B8" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>`),
  scan: page(`<rect width="85" height="110" fill="#F2F1EC"/>` + `<g transform="rotate(-1.2 42 55)">${ln(13, 40, "#55575E", 5)}${body([26, 32, 38, 48, 54, 60, 70, 76, 82, 92], [62, 59, 45, 62, 56, 41, 62, 58, 33, 49]).replace(/#CDD2DC/g, "#A9AAAE")}</g>`),
  ocr: page(`<rect width="85" height="110" fill="#F2F1EC"/>` + `<rect x="9" y="46" width="67" height="17" rx="1.5" fill="#5B8CFF" opacity=".28"/><rect x="30" y="35.5" width="20" height="5" rx="1" fill="#FFD60A" opacity=".75"/>` + `<g transform="rotate(-1.2 42 55)">${ln(13, 40, "#55575E", 5)}${body([26, 32, 38, 48, 54, 60, 70, 76, 82, 92], [62, 59, 45, 62, 56, 41, 62, 58, 33, 49]).replace(/#CDD2DC/g, "#A9AAAE")}</g>`),
};
const plan = `<svg class="pg wide" viewBox="0 0 120 84" aria-hidden="true"><rect width="120" height="84" fill="#FBF7FF"/><g fill="none" stroke="#7C5BD6" stroke-width="1.6"><rect x="10" y="10" width="100" height="64" rx="1"/><path d="M52 10v34H10M52 30h22v44M74 44h36M30 44v30"/></g><g fill="#F0A8C8" opacity=".55"><rect x="12" y="12" width="38" height="30"/></g><g fill="#B9E4F7" opacity=".6"><rect x="76" y="46" width="32" height="26"/></g><path d="M52 22a8 8 0 018 8" fill="none" stroke="#7C5BD6" stroke-width=".9"/></svg>`;

// A file card as the Combine workspace draws it (ux §6.2): page stack, pastel name pill, caption.
const card = ({ k, name, pill, cap, thumb, stack = true, extra = "", attrs = "" }) => `<div class="fc${stack ? " stack" : ""}" data-k="${k}" style="--f:var(--f-${pill});--i:var(--i-${pill})"${attrs}>
      <div class="fc-thumb">${thumb}${extra}</div><span class="fc-pill">${esc(name)}</span><span class="fc-cap"${k === "budget" ? " data-cap" : ""}>${cap}</span></div>`;

// ---------- hero: the Combine workspace ----------
const heroCards = [
  card({ k: "lease", name: "Lease agreement.pdf", pill: "sky", cap: "12 pages", thumb: P.lease, attrs: ' data-pages="12"' }),
  card({ k: "plan", name: "Floor plan.png", pill: "pink", cap: "1 page", thumb: plan, stack: false, attrs: ' data-pages="1"' }),
  card({ k: "budget", name: "Budget 2026.xlsx", pill: "peach", cap: "1 page", thumb: P.table, stack: false, attrs: ' data-pages="1"', extra: '<span class="conv" aria-hidden="true"><i class="spin"></i><b><i></i></b></span>' }),
  card({ k: "inventory", name: "Inventory.docx", pill: "mint", cap: "3 pages", thumb: P.letter, attrs: ' data-pages="3"' }),
];
const fmt = [["PDF", "#EF4444"], ["JPG", "#EC4899"], ["DOC", "#2F80ED"], ["XLS", "#1FAF68"], ["PPT", "#FF8A1F"]].map(([t, c]) => `<b style="background:${c}">${t}</b>`).join("");
const workspace = (id = "") => `<div class="win ws"${id} role="img" aria-label="Super PDF's Combine window: a lease agreement PDF, a floor plan picture, a budget spreadsheet and a Word inventory, dropped in together and lined up in order as one 17-page PDF">
  <div class="win-bar">
    <span class="lights" aria-hidden="true"><i></i><i></i><i></i></span><span class="tb-ico hide-s">${icon("sidebar")}</span>
    <span class="seg hide-s"><b class="on">${icon("files")}Files</b><b>${icon("grid")}Pages</b></span>
    <span class="win-title"><b>Combined</b><small data-sub>4 files · 17 pages</small></span>
    <span class="tb-ico hide-m">${icon("plus")}</span><span class="tb-ico hide-m">${icon("undo")}</span><span class="tb-ico hide-m">${icon("trash")}</span>
    <span class="finish" data-finish>Finish${icon("arrow")}</span>
  </div>
  <div class="win-canvas"><div class="ws-grid">
    ${heroCards.join("\n    ")}
    <div class="fc drop" data-drop><span class="drop-plus">${icon("plus")}</span><b>Add PDF, image, Word, Excel and PowerPoint files</b><small>or drop them anywhere</small><span class="fmt">${fmt}</span></div>
  </div></div>
  <div class="win-status"><span data-status><b>4 files</b> · 17 pages</span><span class="hide-s">Drag to reorder · Space to preview · Drop more files anywhere</span></div>
</div>`;

// ---------- tools catalog ----------
// Columns balanced by height; on phones the sections fall back into the sheet's order (style.css: .col display: contents).
const COLS = [["pages", "scan"], ["convert", "markUp"], ["edit", "signAndFill"], ["protect", "fixAndCheck"]];
const catSection = (k) => {
  const { title, pill } = SEC[k], list = tools.filter((t) => t.section === k);
  return `
    <section class="cat" data-section="${k}" style="--f:var(--f-${pill});--i:var(--i-${pill});--s:var(--s-${pill});order:${SECTIONS.findIndex((x) => x[0] === k)}" aria-labelledby="cat-${k}">
      <h3 id="cat-${k}">${badge(k)}${esc(title)}<span class="n">${list.length}</span></h3>
      <ul>${list.map((t) => `
        <li data-q="${esc([t.name, t.hint, ...t.synonyms].join(" ").toLowerCase())}"><b>${esc(t.name)}</b><span>${esc(t.hint)}</span></li>`).join("")}
      </ul>
    </section>`;
};
if (COLS.flat().sort().join() !== SECTIONS.map((x) => x[0]).sort().join()) throw new Error("COLS must hold every section once");
const catalog = COLS.map((col) => `
    <div class="col">${col.map(catSection).join("")}
    </div>`).join("");

// ---------- results: original → tool → new file ----------
const mini = (name, pill, cap, thumb, stack = true) => `<div class="fc mini${stack ? " stack" : ""}" style="--f:var(--f-${pill});--i:var(--i-${pill})"><div class="fc-thumb">${thumb}</div><span class="fc-pill">${esc(name)}</span><span class="fc-cap">${cap}</span></div>`;
const RESULTS = [
  { id: "makeSmaller", copy: "Pick Good, Email or Best quality. Each one shows the size you’ll get before you press the button.",
    from: mini("Lease agreement.pdf", "sky", "6.1 MB · 12 pages", P.lease), to: mini("Lease agreement (smaller).pdf", "sky", "<b>1.7 MB</b> · 12 pages", P.lease),
    done: "Done. The file is 72% smaller (6.1 MB → 1.7 MB)." },
  { id: "blackOut", copy: "Type a name, or tap Phone numbers, Emails or Card numbers. The text under each box is removed from the file, not just covered, so nobody can copy or search it.",
    from: mini("Lease agreement.pdf", "sky", "12 pages", P.lease), to: mini("Lease agreement (blacked out).pdf", "sky", "12 pages", P.blacked),
    done: "Blacked out 7 items on 2 pages." },
  { id: "sign", copy: "Draw on the trackpad, hold a signed sheet up to the camera, sign on your iPhone or type it. Then click where it goes.",
    from: mini("Lease agreement.pdf", "sky", "12 pages", P.lease), to: mini("Lease agreement (signed).pdf", "sky", "12 pages", P.signed),
    done: "Saved “Lease agreement (signed).pdf”." },
  { id: "toWord", copy: "Or Excel, PowerPoint, pictures, text, EPUB and PDF/A. Converts on your Mac: natively where macOS can, or with LibreOffice, Office or iWork when they’re installed.",
    from: mini("Lease agreement.pdf", "sky", "12 pages", P.lease), to: mini("Lease agreement.docx", "mint", "Word document", P.lease.replace('fill="#394055"', 'fill="#2F80ED"'), false),
    done: "Saved “Lease agreement.docx”." },
  { id: "recogniseText", copy: "Turns a scan into text you can search, select and copy. It runs on Apple Vision, on your Mac, in more than 20 languages.",
    from: mini("Tax return 2025.pdf", "lemon", "44 pages · scanned", P.scan), to: mini("Tax return 2025.pdf", "lemon", "44 pages · searchable", P.ocr),
    done: "Recognised 44 pages. You can now search and copy the text." },
];
const results = RESULTS.map((r) => {
  const t = byId[r.id];
  return `
    <li class="res" style="--s:var(--s-${SEC[t.section].pill})">
      <div class="res-copy"><h3>${esc(t.name)}</h3><p>${r.copy}</p><p class="res-done">${icon("check")}<span>${esc(r.done)}</span></p></div>
      <div class="res-files">${r.from}<span class="res-arrow" aria-hidden="true">${icon("arrow")}</span>${r.to}</div>
    </li>`;
}).join("");

// ---------- Settings › Privacy (features §3.5, PRIVACY.md) ----------
const tabs = [["General", '<circle cx="12" cy="12" r="3"/><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1"/>'], ["Tools", GLYPH.grid], ["Converters", GLYPH.convert], ["Signatures", GLYPH.signAndFill], ["Scanning", GLYPH.scan], ["Privacy", '<path d="M12 3l7 3v6c0 4.5-3 7.6-7 9-4-1.4-7-4.5-7-9V6z"/>']];
const settings = `<div class="win set" role="img" aria-label="Super PDF's Settings, Privacy tab: check for updates automatically is on, and the only connections listed are GitHub for updates and a timestamp server you choose for certificate signatures">
  <div class="win-bar"><span class="lights" aria-hidden="true"><i></i><i></i><i></i></span><span class="win-title"><b>Privacy</b></span></div>
  <div class="set-tabs">${tabs.map(([n, d]) => `<span${n === "Privacy" ? ' class="on"' : ""}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>${n}</span>`).join("")}</div>
  <div class="set-body">
    <div class="set-group"><div class="set-row"><div><b>Check for updates automatically</b><small>A minute after launch and every few hours. Sends only the app’s version.</small></div><span class="toggle on"></span></div></div>
    <p class="set-h">Super PDF connects to</p>
    <div class="set-group">
      <div class="set-row"><div><b>github.com</b><small>Update checks and downloads</small></div></div>
      <div class="set-row"><div><b>A timestamp server you name</b><small>Only if you turn on trusted timestamps and sign with a certificate. Sends a fingerprint of the file, never the file.</small></div></div>
    </div>
    <p class="set-foot">Everything else works with Wi-Fi off.</p>
  </div>
</div>`;

// ---------- copy ----------
const faq = [
  ["Is it really free?", `Yes. There’s no price, no trial and no account, and every tool is included. The code is open under the MIT licence, so you can read it, build it or change it on <a href="${REPO}">GitHub</a>.`],
  ["Does it upload my files or use AI?", `No. Files are opened, changed and saved on your Mac. Super PDF has no AI, no server and no analytics. The only network traffic is the update check, and <a href="${REPO}/blob/main/PRIVACY.md">the privacy statement</a> lists all of it.`],
  ["Will it change my original file?", "Not without asking. Tools save a new copy next to the original, such as “Lease agreement (smaller).pdf”, and every change can be undone."],
  ["Can it turn a PDF into Word or Excel?", "Yes, and into PowerPoint, pictures, text, EPUB and PDF/A. It converts natively where macOS can, and uses LibreOffice, Word, Excel, PowerPoint, Pages, Numbers or Keynote when they’re on your Mac. Nothing is uploaded."],
  ["How do I update or remove it?", `It keeps itself up to date from GitHub Releases, and Super PDF › Check for Updates… always works. To remove it, run <code>curl -fsSL https://udsy19.github.io/super-pdf/install.sh | bash -s -- --uninstall</code>.`],
];
const dl = (cls = "") => `<a class="btn${cls ? " " + cls : ""}" href="${DMG}">${icon("download")}Download for Mac</a>`;
const installBox = `<div class="install"><code>${esc(INSTALL)}</code><button type="button" data-copy="${esc(INSTALL)}" aria-live="polite">Copy</button></div>`;

const css = readFileSync(here("style.css"));
const js = readFileSync(here("app.js"));
const sha = (b) => createHash("sha256").update(b).digest("hex").slice(0, 8);
writeFileSync(out("style.css"), css); writeFileSync(out("app.js"), js);

const title = "Super PDF — every Acrobat tool, as simple as Preview";
const desc = "A free, open-source PDF app for Mac with 52 tools: combine any files, make them smaller, black out, sign, convert and recognise text, all on your Mac. No AI, no account.";
const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(desc)}">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)"><meta name="theme-color" content="#11141b" media="(prefers-color-scheme: dark)">
<link rel="canonical" href="${SITE}">
<link rel="icon" href="favicon.svg" type="image/svg+xml"><link rel="icon" href="favicon-32.png" sizes="32x32" type="image/png"><link rel="apple-touch-icon" href="apple-touch-icon.png">
<meta property="og:type" content="website"><meta property="og:site_name" content="Super PDF"><meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(desc)}">
<meta property="og:url" content="${SITE}"><meta property="og:image" content="${SITE}og.png"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630"><meta property="og:image:alt" content="Super PDF: every Acrobat tool, as simple as Preview. Its Combine window lines up a PDF, a picture, a spreadsheet and a Word file as one PDF.">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="${esc(title)}"><meta name="twitter:description" content="${esc(desc)}"><meta name="twitter:image" content="${SITE}og.png">
<link rel="preload" href="fonts/funnel-display-800.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="style.css?v=${sha(css)}">
<script>(function(d){d.classList.add("js");if(!matchMedia("(prefers-reduced-motion: reduce)").matches){d.classList.add("play");setTimeout(function(){d.classList.remove("play")},5000)}})(document.documentElement)</script>
<script type="application/ld+json">${JSON.stringify({ "@context": "https://schema.org", "@type": "SoftwareApplication", name: "Super PDF", operatingSystem: "macOS 14+", applicationCategory: "UtilitiesApplication", offers: { "@type": "Offer", price: "0", priceCurrency: "USD" }, downloadUrl: DMG, license: "https://opensource.org/license/mit" })}</script>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="nav"><div class="wrap">
  <a class="brand" href="./"><img src="favicon.svg" alt="" width="30" height="30">Super PDF</a>
  <nav aria-label="Main"><ul><li><a href="#tools">Tools</a></li><li><a href="#privacy">Privacy</a></li><li><a href="#faq">Questions</a></li><li><a href="${REPO}">GitHub</a></li></ul></nav>
  <a class="btn sm" href="${DMG}">${icon("download")}Download</a>
</div></header>
<main id="main">
<section class="hero"><div class="wrap">
  <h1>Every Acrobat tool. <span>As simple as Preview.</span></h1>
  <div class="hero-row">
    <p class="lede">A free, open-source PDF app for Mac with 52 tools. Combine any files, make them smaller, black out what’s private, sign, convert and more. Everything happens on your Mac, with no account and no AI.</p>
    <div class="hero-act">
      <div class="cta">${dl("lg")}<p class="req">Free · macOS 14 or later<br>Apple silicon and Intel</p></div>
      <p class="or">Or install from Terminal</p>${installBox}
    </div>
  </div>
  <div class="hero-shot">${workspace(' id="combine"')}</div>
</div></section>

<section class="tools" id="tools" aria-labelledby="tools-h"><div class="wrap">
  <div class="sec-head">
    <h2 id="tools-h">What do you want to do?</h2>
    <p>All 52 tools, in the same eight groups as the Tools sheet in the app. Each has a plain name and opens one small panel with one button.</p>
  </div>
  <div class="finder">
    <label class="search">${icon("search")}<span class="vh">Search tools</span><input id="q" type="search" placeholder="Try “smaller” or “sign”" autocomplete="off" spellcheck="false"></label>
    <p class="aka">Know it by another name? ${["compress", "merge", "redact", "OCR"].map((w) => `<button type="button" data-try="${w}">${w}</button>`).join("")}</p>
  </div>
  <p class="count" id="count" aria-live="polite">All 52 tools</p>
  <div class="cats" id="cats">${catalog}
  </div>
  <p class="empty" id="empty" hidden>No tool matches that. Try a simpler word, such as “merge” or “compress”.</p>
</div></section>

<section class="results" aria-labelledby="res-h"><div class="wrap">
  <div class="sec-head">
    <h2 id="res-h">A new file, next to the original.</h2>
    <p>Most tools save a copy beside your file, named for what changed, so the original stays as it was. Anything done in place can be undone with ⌘Z.</p>
  </div>
  <ol class="res-list">${results}
  </ol>
</div></section>

<section class="privacy" id="privacy" aria-labelledby="priv-h"><div class="wrap">
  <div class="priv-copy">
    <h2 id="priv-h">Works with Wi-Fi off.</h2>
    <p>Your files are opened, changed and saved on your Mac, never uploaded. There’s no account, no AI and no analytics. The one thing Super PDF connects to is GitHub, to check for updates, and you can turn that off.</p>
    <p><a class="more" href="${REPO}/blob/main/PRIVACY.md">Read the privacy statement${icon("arrow")}</a></p>
  </div>
  ${settings}
</div></section>

<section class="faq" id="faq" aria-labelledby="faq-h"><div class="wrap">
  <div><h2 id="faq-h">Questions</h2><p class="ask">Anything else? <a href="${REPO}/issues">Ask on GitHub</a>.</p></div>
  <div class="qa">${faq.map(([q, a]) => `<details><summary>${q}</summary><p>${a}</p></details>`).join("")}</div>
</div></section>

<section class="get" id="get" aria-labelledby="get-h"><div class="wrap">
  <div class="get-copy">
    <h2 id="get-h">Get Super PDF.</h2>
    <p class="lede">Free and open source, for macOS 14 or later on Apple silicon and Intel.</p>
    <div class="cta">${dl("lg")}</div>
    <p class="or">Or install from Terminal</p>${installBox}
    <p class="note">The app is signed with its own certificate rather than notarised by Apple, so the first time you open it, macOS asks you to confirm in System Settings › Privacy &amp; Security.</p>
  </div>
  <a class="fc dmg" href="${DMG}" tabindex="-1" aria-hidden="true" style="--f:var(--f-lavender);--i:var(--i-lavender)"><span class="fc-thumb"><img src="favicon.svg" alt="" width="150" height="150"></span><span class="fc-pill">SuperPDF.dmg</span><span class="fc-cap">One app for Apple silicon and Intel</span></a>
</div></section>
</main>
<footer class="foot"><div class="wrap">
  <a class="brand" href="./"><img src="favicon.svg" alt="" width="26" height="26">Super PDF</a>
  <ul><li><a href="${REPO}">Source code</a></li><li><a href="${REPO}/releases">Releases</a></li><li><a href="${REPO}/blob/main/CHANGELOG.md">Changelog</a></li><li><a href="${REPO}/blob/main/PRIVACY.md">Privacy</a></li><li><a href="${REPO}/blob/main/LICENSE">MIT licence</a></li><li><a href="${REPO}/blob/main/THIRD_PARTY_NOTICES.md">Third-party notices</a></li></ul>
  <p class="legal">Free software under the MIT licence. Mac is a trademark of Apple Inc. Super PDF is not affiliated with Apple or with any other PDF software maker.</p>
</div></footer>
<script src="app.js?v=${sha(js)}" defer></script>
</body>
</html>
`;
writeFileSync(out("index.html"), html);

// Social card source (rendered to og.png by src/render-assets.mjs): the hero at 1200x630, the workspace at rest.
writeFileSync(here("og.html"), `<!doctype html><html lang="en" data-theme="light"><head><meta charset="utf-8"><meta name="color-scheme" content="light"><link rel="stylesheet" href="../style.css"></head>
<body class="og"><div class="og-card">
  <span class="brand"><img src="../favicon.svg" alt="" width="40" height="40">Super PDF</span>
  <h1>Every Acrobat tool. <span>As simple as Preview.</span></h1>
  <p>Free and open source. 52 tools, all on your Mac. No AI, no account.</p>
  <div class="og-shot">${workspace()}</div>
</div></body></html>`);
console.log("built", { css: sha(css), js: sha(js), bytes: html.length });
