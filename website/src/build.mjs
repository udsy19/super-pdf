// Builds website/index.html (+ hashed style.css / app.js URLs) from this folder.   node website/src/build.mjs
import { readFileSync, writeFileSync, copyFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { readTools, SECTIONS } from "./tools.mjs";

const here = (p) => new URL(p, import.meta.url);
const out = (p) => new URL("../" + p, import.meta.url);
const SITE = "https://udsy19.github.io/super-pdf/";
const DMG = "https://github.com/udsy19/super-pdf/releases/latest/download/SuperPDF.dmg";
const REPO = "https://github.com/udsy19/super-pdf";
const INSTALL = "curl -fsSL https://udsy19.github.io/super-pdf/install.sh | bash";
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

const GLYPH = {
  pages: '<rect x="5" y="3" width="14" height="18" rx="2"/><path d="M9 8h6M9 12h6"/>',
  convert: '<path d="M4 8h14l-3-3M20 16H6l3 3"/>',
  edit: '<path d="M4 20l1-4L16 5l3 3L8 19z"/>',
  markUp: '<path d="M5 19h6M14 4l6 6-8 8-6-6z"/>',
  signAndFill: '<path d="M3 17c3-8 5-9 6-6s-2 7 1 6 3-5 5-4 2 3 6 1"/>',
  protect: '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 018 0v3"/>',
  fixAndCheck: '<circle cx="12" cy="12" r="8"/><path d="M8.5 12.5l2.5 2.5 4.5-5"/>',
  scan: '<path d="M4 8V5h3M17 5h3v3M20 16v3h-3M7 19H4v-3M4 12h16"/>',
};
const svg = (key, extra = "") => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"${extra}>${GLYPH[key]}</svg>`;
const SEC = Object.fromEntries(SECTIONS.map(([k, t, c]) => [k, { t, c }]));
const tools = readTools();
const byId = Object.fromEntries(tools.map((t) => [t.id, t]));

// ---------- tools grid ----------
const grid = SECTIONS.map(([k, title, color]) => `
        <div class="group" style="--c:${color}" data-section="${k}">
          <h3><i></i>${esc(title)}</h3>
          <ul class="tiles">${tools.filter((t) => t.section === k).map((t, i) => `
            <li class="tile" style="--c:${color};--i:${i}" data-section="${k}" data-syn="${esc(t.synonyms.join(" "))}"><div class="ico">${svg(k)}</div><b>${esc(t.name)}</b><span>${esc(t.hint)}</span></li>`).join("")}
          </ul>
        </div>`).join("");
const chips = [`<button class="chip" data-section="all" aria-pressed="true">All</button>`, ...SECTIONS.map(([k, t, c]) => `<button class="chip" data-section="${k}" aria-pressed="false" style="--c:${c}"><i></i>${esc(t)}</button>`)].join("");
const quick = ["makeSmaller", "combineFiles", "sign", "blackOut", "toWord", "recogniseText", "rearrangePages", "addPassword", "fillForm", "watermark"].map((id) => {
  const t = byId[id]; return `<li><span class="dot" style="background:color-mix(in srgb, ${SEC[t.section].c} 16%, transparent);color:${SEC[t.section].c}">${svg(t.section)}</span>${esc(t.name)}</li>`;
}).join("");

// ---------- mockup parts ----------
const I = {
  tools: '<svg viewBox="0 0 24 24"><rect x="4" y="4" width="6.5" height="6.5" rx="1.6"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.6"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.6"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.6"/></svg>',
  pencil: '<svg class="m-ico" viewBox="0 0 24 24"><path d="M4 20l1-4L16 5l3 3L8 19z"/></svg>',
  undo: '<svg class="m-ico" viewBox="0 0 24 24"><path d="M4 12a8 8 0 108-8H8M8 1L4 4l4 3"/></svg>',
  share: '<svg class="m-ico" viewBox="0 0 24 24"><path d="M12 15V3M8 7l4-4 4 4M5 12v8h14v-8"/></svg>',
  mag: '<svg class="m-ico" style="width:1.1em;height:1.1em;color:rgba(0,0,0,.35)" viewBox="0 0 24 24"><circle cx="11" cy="11" r="6"/><path d="M16 16l4 4"/></svg>',
  side: '<svg class="m-ico" viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="14" rx="3"/><path d="M9 5v14"/></svg>',
};
const titlebar = (name) => `<div class="m-title"><div class="m-lights"><i></i><i></i><i></i></div><div class="m-name"><span class="m-doc"></span>${name}</div><div class="m-right m-hide-s">${I.pencil}${I.undo}<span class="m-tools">${I.tools}Tools</span>${I.share}<span class="m-search">${I.mag}Search</span></div></div>`;
const thumbs = `<div class="m-side">${[1, 2, 3].map((n) => `<div class="m-th${n === 1 ? " sel" : ""}"><div class="pg"><b class="t" style="top:12%"></b><b style="top:26%"></b><b style="top:32%"></b><b style="top:42%"></b><b style="top:48%"></b>${n === 3 ? '<b class="img" style="top:58%"></b>' : '<b style="top:60%"></b>'}</div><small>${n}</small></div>`).join("")}</div>`;
const lease1 = `<h4>Residential Lease Agreement</h4><p class="sub">Prepared 14 September 2026 · 12 pages</p>
<h5>1. Parties</h5><p>This Residential Lease Agreement (the “Agreement”) is entered into on 14 September 2026 between <b>Margaret Ellison</b> (“Landlord”), of 48 Orchard Lane, Bath, and <b>Priya Natarajan</b> (“Tenant”). The Landlord agrees to let, and the Tenant agrees to take, the premises described below.</p>
<h5>2. Premises</h5><p>The premises are the two-bedroom flat known as Flat 3, 112 Walcot Street, Bath, together with the storage locker numbered 3 in the basement and one allocated parking space.</p>
<h5>3. Term</h5><p>The tenancy begins on 1 October 2026 and continues for a fixed term of twelve months, ending on 30 September 2027.</p>
<h5>4. Rent</h5><p>The Tenant shall pay rent of £1,450 per calendar month in advance on the first day of each month, by standing order.</p>`;
const lease3 = (marks) => {
  const r = (s) => (marks ? `<span class="r">${s}</span>` : s);
  return `<h4>Residential Lease Agreement</h4><p class="sub">Page 3 of 12 — Schedule of payments</p>
<h5>6. Payment schedule</h5><table><tr><th>Due date</th><th>Description</th><th>Amount</th></tr><tr><td>1 Oct 2026</td><td>Rent — October</td><td>£1,450.00</td></tr><tr><td>1 Nov 2026</td><td>Rent — November</td><td>£1,450.00</td></tr></table>
<h5>7. Contact details</h5><p>Landlord: Margaret Ellison, 48 Orchard Lane, Bath. Telephone ${r("01225 448 912")}, email ${r("m.ellison@orchardlets.co.uk")}.</p>
<p>Tenant: Priya ${r("Natarajan")}. Telephone ${r("07700 900 417")}, email ${r("priya.natarajan@example.com")}. National Insurance number ${r("QQ 12 34 56 C")}.</p>`;
};
const win = (cls, inner, label) => `<div class="mockwrap" role="img" aria-label="${esc(label)}"><div class="mock ${cls}">${inner}</div></div>`;
const panel = (title, color, hint, content, foot) => `<div class="m-panel"><div class="m-ph"><div class="row"><span class="m-cat" style="background:color-mix(in srgb,${color} 16%,transparent);color:${color}">${svg(byId[title.key].section)}</span>${esc(title.name)}<span class="m-x">✕</span></div><p>${hint}</p></div><div class="m-pc">${content}</div><div class="m-pf">${foot}</div></div>`;
const T = (id) => ({ key: id, name: byId[id].name });
const fixedTitle = (n) => `<div class="m-title" style="grid-template-columns:1fr auto 1fr"><div class="m-lights"><i></i><i></i><i></i></div><div class="m-name"><span class="m-doc"></span>${n}</div><div></div></div>`;
const featWin = (name, panelHtml, page, label, extra = "") => win("f", `${fixedTitle(name)}<div class="m-body"><div class="m-well"><div class="m-page">${page}${extra}</div></div>${panelHtml}</div>`, label);

const heroThumbs = `<div class="m-side">${[1, 2, 3, 4].map((n) => `<div class="m-th${n === 1 ? " sel" : ""}"><div class="pg"><b class="t" style="top:12%"></b><b style="top:26%"></b><b style="top:32%"></b><b style="top:42%"></b><b style="top:48%"></b>${n === 3 ? '<b class="img" style="top:58%"></b>' : '<b style="top:60%"></b>'}</div><small>${n}</small></div>`).join("")}</div>`;
const rr = (x) => `<span class="rr">${x}</span>`;
const pill = (t) => `<span class="t"><b>${t[0]}</b><small>${t[1]}</small></span>`;
const heroMock = win("hero-demo", `${titlebar("Lease agreement.pdf")}<div class="m-body">${heroThumbs}<div class="m-well"><div class="m-page"><h4>Residential Lease Agreement</h4><p class="sub">Page 3 of 12 — Schedule of payments</p>
<h5>7. Contact details</h5><p>Landlord: Margaret Ellison, 48 Orchard Lane, Bath. Telephone ${rr("01225 448 912")}, email ${rr("m.ellison@orchardlets.co.uk")}.</p>
<p>Tenant: Priya ${rr("Natarajan")}. Telephone ${rr("07700 900 417")}, email ${rr("priya.natarajan@example.com")}. National Insurance number ${rr("QQ 12 34 56 C")}.</p>
<h5>8. Utilities</h5><p>The Tenant is responsible for arranging and paying for gas, electricity, broadband and council tax from the start date.</p>
<div class="m-signrow"><div>Landlord signature · Date</div><div>Tenant signature · Date<span class="m-sig">Priya Natarajan</span></div></div></div></div></div>
<div class="m-pill" style="--c:#007AFF"><span class="dot">${svg("pages")}</span><span class="slot">${pill(["Rearrange pages", "Drag pages into a new order"])}<span class="t"><b>Make smaller</b><small><s style="opacity:.6">6.1 MB</s> → <span data-size>6.1</span> MB</small></span>${pill(["Black out", "7 items hidden for good"])}${pill(["Sign", "Signed and saved as a new copy"])}</span><span class="bar"><i data-bar></i></span></div>`, "Super PDF's main window working on a lease agreement: pages shuffle into order, the file shrinks, private details are blacked out and a signature is written");

const smallerMock = featWin("Lease agreement.pdf", panel(T("makeSmaller"), "#30B0C7", "Shrinks the file so it’s easier to send. The pages stay the same.",
  `<div class="m-now"><span>Now</span><span><b>6.1 MB</b> · 12 pages · 9 pictures</span></div><div class="m-opts" role="radiogroup" aria-label="Quality" style="display:flex;flex-direction:column;gap:.7em">
  <button class="m-opt" role="radio" aria-checked="true"><div class="h"><em>Good <small style="display:inline;margin:0;font-weight:400">(recommended)</small></em><span>≈ 2.8 MB</span></div><small>Pictures stay sharp on screen and in print</small></button>
  <button class="m-opt" role="radio" aria-checked="false"><div class="h"><em>Email</em><span>≈ 1.7 MB</span></div><small>Smallest. Fine for reading, pictures a little softer</small></button>
  <button class="m-opt" role="radio" aria-checked="false"><div class="h"><em>Best quality</em><span>≈ 5.1 MB</span></div><small>Only removes what nobody will see</small></button></div>
  <p style="font-size:.88em;color:var(--m-label2)">Comments, form entries and bookmarks are kept.</p>`,
  `<span>Saves <b>“Lease agreement (smaller).pdf”</b> next to the original</span><div class="m-go">Make smaller</div><span>Cancel</span>`), lease1, "Super PDF's Make smaller panel with three presets: Good, Email and Best quality, each with its resulting size");

const blackMock = featWin("Lease agreement.pdf", panel(T("blackOut"), "#FF3B30", "Permanently hides names, numbers or anything private. Your original file stays as it is.",
  `<div class="m-seg"><span>Mark by hand</span><span class="on">Find and mark</span></div><div class="m-field">Natarajan</div>
  <div class="m-pills"><span class="on">Phone numbers 2</span><span class="on">Emails 2</span><span>Card numbers</span><span class="on">National Insurance 1</span><span>Dates</span></div>
  <b style="font-size:.95em">7 found on 2 pages</b><div class="m-list"><div><span>“Natarajan”</span><small>p. 1, 3</small></div><div><span>07700 900 417</span><small>p. 3</small></div><div><span>priya.natarajan@example.com</span><small>p. 3</small></div></div>
  <div class="m-chk">Also remove hidden information (metadata, comments)</div>`,
  `<span>Saves <b>“Lease agreement (blacked out).pdf”</b> · the original is untouched</span><div class="m-go red">Black out 7 items</div><span>Cancel</span>`), lease3(true), "Super PDF's Black out panel finding every occurrence of a name, phone number and email, with the matches outlined on the page");

const signMock = featWin("Lease agreement.pdf", panel(T("sign"), "#AF52DE", "Put your signature on the page. Click a signature, then click where it goes.",
  `<div class="m-seg"><span class="on">My signature</span><span>With a certificate</span></div><div class="m-sigcard on">Priya Natarajan<small>Saved on this Mac</small></div><div class="m-sigcard" style="font-size:1.5em">PN<small>Initials</small></div>
  <div class="m-field" style="width:max-content;padding:.4em .9em">+ Create signature…</div><div class="m-chk">Add today’s date next to it</div>`,
  `<span>Saves <b>“Lease agreement (signed).pdf”</b> · the original is untouched</span><div class="m-go">Sign and save…</div><span>Cancel</span>`),
  `<h4>Residential Lease Agreement</h4><p class="sub">Page 3 of 12 — Schedule of payments</p><h5>8. Utilities</h5><p>The Tenant is responsible for arranging and paying for gas, electricity, broadband and council tax from the start date, and for notifying the suppliers of the meter readings taken at check-in.</p>`,
  "Super PDF's Sign panel with a saved signature, placed on the tenant's signature line", `<div class="m-sigline" style="left:2.6em;top:21em">Landlord signature · Date</div><div class="m-sigline" style="left:15.4em;top:21em">Tenant signature · Date</div><div class="m-sig" style="left:14.4em;top:17.2em">Priya Natarajan</div>`);

const orgPages = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((n) => `<div class="c${n === 3 ? " sel" : ""}${n === 7 ? " ghost" : ""}"><div class="pg"><b class="t" style="top:12%"></b><b style="top:24%"></b><b style="top:29%"></b><b style="top:38%"></b>${n === 3 || n === 9 ? '<b class="img" style="top:48%"></b>' : '<b style="top:48%"></b>'}<b style="top:58%"></b><b style="top:64%"></b></div><small>${n}</small></div>`).join("");
const orgMock = win("o", `<div class="m-title" style="grid-template-columns:1fr auto 1fr"><div class="m-lights"><i></i><i></i><i></i></div><div class="m-name"><b>Rearrange pages</b> <span style="font-weight:400;color:var(--m-label2)">— Lease agreement.pdf</span></div><div class="m-right"><span class="m-tools">Done</span></div></div>
<div class="m-body"><div class="m-org">${orgPages}<div class="add"><div style="font-size:2em;line-height:1">+</div>Add pages</div><div class="m-ins" style="left:36.5%;top:2em;height:21%"></div><div class="m-drag"><b class="t" style="top:12%"></b><b style="top:26%"></b><b style="top:32%"></b><b style="top:42%"></b></div></div></div>`, "Super PDF's page organiser: a grid of page thumbnails with one page being dragged to a new place and a blue insertion line");

// ---------- copy ----------
const faq = [
  ["Is Super PDF really free?", `Yes. It is free, with no pricing, no trial and no account, and the source is open under the MIT licence. Read it, build it or change it on <a href="${REPO}">GitHub</a>.`],
  ["Does it use AI, or send my files anywhere?", `No AI, no account, no server and no telemetry. Your files are opened, changed and saved on your Mac. Text recognition runs on Apple Vision. The only network traffic is the update check, and <a href="${REPO}/blob/main/PRIVACY.md">PRIVACY.md</a> lists all of it. You can turn that off in Settings › Privacy.`],
  ["Will it overwrite my original file?", "Never without asking. Tools save a copy next to the original, such as “Lease agreement (smaller).pdf”, and every change can be undone."],
  ["Why does macOS ask me to confirm the first time?", "The app is signed with its own certificate rather than notarised by Apple. The first time you open it, macOS asks you to confirm in System Settings › Privacy &amp; Security. The DMG’s release notes show the steps."],
  ["Which Macs does it run on?", "macOS 14 or later, on Apple silicon or Intel. The download is one universal app."],
  ["Can it turn a PDF into Word or Excel?", "Yes. Conversions run natively where macOS can do them, through LibreOffice if it is installed on your Mac, and through Word, Excel, PowerPoint, Pages, Numbers or Keynote when you have them. Nothing is uploaded."],
  ["How do I update or remove it?", `It keeps itself up to date from this repository’s releases, and Super PDF › Check for Updates… always works. To remove it, run <code>curl -fsSL https://udsy19.github.io/super-pdf/install.sh | bash -s -- --uninstall</code>.`],
];
const splitWords = (t, o) => t.split(" ").map((w, i) => `<span class="w" style="--i:${o + i}" aria-hidden="true"><span>${w}</span></span>`).join(" ");
const dl = (cls = "primary", label = "Download for Mac") => `<a class="btn ${cls}" href="${DMG}">${label}</a>`;
const gh = (label = "View on GitHub") => `<a class="btn ghost" href="${REPO}">${label}</a>`;
const installBox = `<div class="install"><code>${esc(INSTALL)}</code><button type="button" data-copy="${esc(INSTALL)}">Copy</button></div>`;

const css = readFileSync(here("style.css"));
const js = readFileSync(here("app.js"));
const sha = (b) => createHash("sha256").update(b).digest("hex").slice(0, 8);
writeFileSync(out("style.css"), css); writeFileSync(out("app.js"), js);

const title = "Super PDF — every Acrobat tool, as simple as Preview";
const desc = "A free, open-source PDF app for Mac. Combine, make smaller, black out, sign, convert and 40 more tools, all on your Mac. No AI, no account.";
const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(desc)}">
<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)"><meta name="theme-color" content="#1c1c1e" media="(prefers-color-scheme: dark)">
<link rel="canonical" href="${SITE}">
<link rel="icon" href="favicon.svg" type="image/svg+xml"><link rel="icon" href="favicon-32.png" sizes="32x32" type="image/png"><link rel="apple-touch-icon" href="apple-touch-icon.png">
<meta property="og:type" content="website"><meta property="og:site_name" content="Super PDF"><meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(desc)}">
<meta property="og:url" content="${SITE}"><meta property="og:image" content="${SITE}og.png"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630"><meta property="og:image:alt" content="Super PDF, a free PDF app for Mac, showing its window and Tools button">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="${esc(title)}"><meta name="twitter:description" content="${esc(desc)}"><meta name="twitter:image" content="${SITE}og.png">
<script>document.documentElement.classList.add("js")</script>
<link rel="stylesheet" href="style.css?v=${sha(css)}">
<script type="application/ld+json">${JSON.stringify({ "@context": "https://schema.org", "@type": "SoftwareApplication", name: "Super PDF", operatingSystem: "macOS 14+", applicationCategory: "UtilitiesApplication", offers: { "@type": "Offer", price: "0", priceCurrency: "USD" }, downloadUrl: DMG, license: "https://opensource.org/license/mit" })}</script>
</head>
<body>
<a class="skip" href="#tools">Skip to the tools</a>
<header class="nav"><div class="wrap"><a class="brand" href="./"><img src="favicon.svg" alt="" width="28" height="28">Super PDF</a>
<nav aria-label="Main"><ul><li><a href="#tools">Tools</a></li><li><a href="#features">Features</a></li><li><a href="#open-source">Free &amp; open source</a></li><li><a href="#faq">FAQ</a></li></ul></nav>
<a class="btn primary sm" href="${DMG}">Download</a></div></header>
<main>
<section class="hero"><i class="orb a"></i><i class="orb b"></i><i class="orb c"></i><div class="wrap center">
  <span class="eyebrow fadeup">Free and open source · for Mac</span>
  <h1 class="split" aria-label="Every Acrobat tool. As simple as Preview.">${splitWords("Every Acrobat tool.", 0)}<br>${splitWords("As simple as Preview.", 3)}</h1>
  <p class="lede fadeup" style="--d:300">Open a PDF, press <b>Tools</b>, pick a tile. Combine, make smaller, black out, sign, convert and more, all on your Mac. No AI, no account.</p>
  <div class="cta fadeup" style="--d:450"><a class="btn primary big" data-magnet href="${DMG}"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 4v11M7 11l5 5 5-5M5 20h14"/></svg>Download for Mac</a><a class="btn ghost big" data-magnet href="${REPO}">View on GitHub</a></div>
  <div class="metas fadeup" style="--d:550"><span>Free</span><span>macOS 14+</span><span>Apple silicon &amp; Intel</span><span>MIT licence</span></div>
  <div class="fadeup" style="--d:650">${installBox}</div>
  <div class="hero-shot"><div class="hero-tilt">${heroMock}</div></div>
</div></section>

<div class="quick"><div class="wrap"><ul aria-label="A few of the tools">${quick}<li><b>and 42 more</b></li></ul></div></div>


<section class="showcase" id="watch" aria-labelledby="sc-h"><div class="wrap sc-head center"><span class="eyebrow">Watch it work</span><h2 id="sc-h">From a pile of files to done.</h2><p class="lede" style="margin-top:16px">Scroll to see five of the 52 tools do their job.</p></div>
<div class="sc-track" id="sc-track"><div class="sc-pin"><div class="wrap sc-grid">
  <ol class="sc-steps">
    <li class="sc-step" data-i="0"><span class="n">1</span><h3>Combine files</h3><p>Drop several files in. Get one PDF.</p><div class="bar"><i></i></div></li>
    <li class="sc-step" data-i="1"><span class="n">2</span><h3>Make smaller</h3><p>Shrink it so it is easy to send.</p><div class="bar"><i></i></div></li>
    <li class="sc-step" data-i="2"><span class="n">3</span><h3>Black out</h3><p>Hide names and numbers for good.</p><div class="bar"><i></i></div></li>
    <li class="sc-step" data-i="3"><span class="n">4</span><h3>Sign</h3><p>Put your signature on the line.</p><div class="bar"><i></i></div></li>
    <li class="sc-step" data-i="4"><span class="n">5</span><h3>Convert</h3><p>Turn it into Word, Excel or slides.</p><div class="bar"><i></i></div></li>
  </ol>
  <div class="sc-stage" role="img" aria-label="An animation of Super PDF's Combine files, Make smaller, Black out, Sign and Convert tools at work">
    <div class="sc"><div class="cb"><div class="file f1"><b>Lease.pdf</b><i>4 pages</i><span class="ln"></span><span class="ln"></span></div><div class="file f2"><b>Schedule.pdf</b><i>6 pages</i><span class="ln"></span><span class="ln"></span></div><div class="file f3"><b>Photos.pdf</b><i>2 pages</i><span class="ln"></span><span class="ln"></span></div><span class="out">Combined.pdf · <span data-from="0" data-to="12" data-dec="0">12</span> pages</span></div></div>
    <div class="sc sm"><div><div class="doc-wrap"><div class="doc"><span class="ln" style="width:60%;background:#8f95a3"></span><span class="ln"></span><span class="ln"></span><span class="ln" style="height:3em"></span><span class="ln"></span></div></div><div class="sz"><span data-from="6.1" data-to="2.8" data-dec="1">2.8</span> MB</div><div class="track"><i></i></div><span class="save">54% smaller</span></div></div>
    <div class="sc bo"><div class="doc"><h5>7. Contact details</h5><p>Tenant: Priya <span class="k k1">Natarajan</span>, telephone <span class="k k2">07700 900 417</span>, email <span class="k k3">priya@example.com</span>.</p><p>The tenancy begins on 1 October and continues for twelve months.</p></div><div class="cap"><b><span data-from="0" data-to="7" data-dec="0">7</span> items</b> hidden for good</div></div>
    <div class="sc sg"><div class="doc"><span class="ln" style="width:55%;background:#8f95a3"></span><span class="ln"></span><span class="ln"></span><span class="line"></span><span class="ink">Priya Natarajan</span><span class="date">20 Oct 2026</span></div></div>
    <div class="sc s-cv"><div class="cv"><div class="out w"><span>Word</span><i></i><i></i><i></i></div><div class="out x"><span>Excel</span><i></i><i></i><i></i></div><div class="out p"><span>Slides</span><i></i><i></i><i></i></div><div class="doc"><span class="ln" style="width:60%;background:#8f95a3"></span><span class="ln"></span><span class="ln"></span><span class="ln"></span></div></div></div>
  </div>
</div></div></div></section>

<section id="tools"><div class="wrap">
  <div class="tools-head center">
    <div><span class="eyebrow">Tools</span><h2>52 tools. One window.</h2><p class="lede" style="margin-top:16px">Every tool is a tile with a plain name that opens one small panel with one big button. This is the same list as the Tools sheet in the app. Try searching “smaller”, “sign” or “Word”.</p></div>
    <div class="searchbar"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="6.5"/><path d="M16 16l4 4"/></svg>
      <input id="tool-search" type="search" placeholder="Search tools — try “smaller”, “sign”, “Word”, “black out”" aria-label="Search tools" autocomplete="off" spellcheck="false"><kbd aria-hidden="true">/</kbd></div>
    <div class="chips" role="group" aria-label="Filter by section">${chips}</div>
    <p class="count" id="tool-count" aria-live="polite">All 52 tools</p>
  </div>
  <div id="tool-grid">${grid}</div>
  <p class="empty" id="tool-empty" hidden>No tool matches that. Try a simpler word, such as “merge” or “compress”.</p>
</div></section>

<section class="alt"><div class="wrap">
  <div class="center"><span class="eyebrow reveal">How it works</span><h2 class="reveal" data-d="1">Three steps. That is the whole app.</h2></div>
  <div class="steps">
    <div class="step reveal"><h3>Open a PDF</h3><p>One document, one thumbnail sidebar, in the window you already know from Preview.</p></div>
    <div class="step reveal" data-d="1"><h3>Press Tools</h3><p>Search or pick a tile. “Make smaller”, not “Optimize PDF”. ⌘T opens it from the keyboard.</p></div>
    <div class="step reveal" data-d="2"><h3>Press the big button</h3><p>The page itself is the live preview. Your original is never overwritten without asking, and every change can be undone.</p></div>
  </div>
</div></section>

<section id="features"><div class="wrap" style="display:grid;gap:clamp(80px,12vw,150px)">
  <div class="feature"><div class="copy reveal"><span class="eyebrow">Make smaller</span><h2>Shrink a file so it’s easy to send.</h2><p class="lede">Pick Good, Email or Best quality. Each one shows the size you will get before you press the button.</p>
    <ul><li>The pages stay the same, with comments, form entries and bookmarks kept</li><li>A new copy is saved next to the original</li></ul></div><div class="reveal" data-d="1">${smallerMock}</div></div>
  <div class="feature flip"><div class="reveal">${blackMock}</div><div class="copy reveal" data-d="1"><span class="eyebrow">Black out</span><h2>Hide what’s private, for good.</h2><p class="lede">Type a name, or tap Phone numbers, Emails or Card numbers. Super PDF finds every match and marks it on the page for you to check.</p>
    <ul><li>The text under the black box is removed from the file, not just covered</li><li>Optionally strips metadata and hidden comments in the same step</li></ul></div></div>
  <div class="feature"><div class="copy reveal"><span class="eyebrow">Sign</span><h2>Sign it. Or ask others to.</h2><p class="lede">Draw on the trackpad, hold a signed sheet up to the camera, or sign on your iPhone. Click where it goes, and add today’s date next to it.</p>
    <ul><li>Sign with a certificate, and see who else signed</li><li>Request signatures and track who is done</li></ul></div><div class="reveal" data-d="1">${signMock}</div></div>
  <div class="feature flip"><div class="reveal">${orgMock}</div><div class="copy reveal" data-d="1"><span class="eyebrow">Rearrange pages</span><h2>Drag pages into a new order.</h2><p class="lede">See every page at once. Drag to move, rotate or delete, and drop in pages from a second file. Drop several files on the window to combine them.</p>
    <ul><li>Insert, extract, split, crop and number pages</li><li>Undo any step</li></ul></div></div>
</div></section>

<section class="alt"><div class="wrap">
  <div class="center"><span class="eyebrow reveal">On your Mac</span><h2 class="reveal" data-d="1">Nothing leaves the machine.</h2><p class="lede reveal" data-d="2" style="margin-top:16px">Your documents are yours. Super PDF has no cloud to send them to.</p></div>
  <div class="pillars">
    <div class="pillar reveal"><div class="big">0</div><h3>Accounts</h3><p>Open the app and start. There is nothing to sign up for.</p></div>
    <div class="pillar reveal" data-d="1"><div class="big">0</div><h3>AI</h3><p>No models, no prompts, no “smart” features that read your files.</p></div>
    <div class="pillar reveal" data-d="2"><div class="big">0</div><h3>Telemetry</h3><p>No analytics. The only network request is checking for updates.</p></div>
    <div class="pillar reveal" data-d="2"><div class="big">100%</div><h3>Local</h3><p>Text recognition runs on Apple Vision, right on your Mac.</p></div>
  </div>
  <div class="three">
    <div class="step reveal" style="counter-increment:none"><h3>Do this to many files</h3><p>Run tools on a whole folder in order, and save the steps as a routine.</p></div>
    <div class="step reveal" data-d="1" style="counter-increment:none"><h3>In Finder</h3><p>Quick Actions: Combine in Super PDF, Make Smaller, Convert to PDF and Recognise Text. Save to Super PDF from any print dialog.</p></div>
    <div class="step reveal" data-d="2" style="counter-increment:none"><h3>Links</h3><p>Open a file or a tool from anywhere with <code>superpdf://tool/make-smaller</code>.</p></div>
  </div>
</div></section>

<section id="open-source"><div class="wrap"><div class="oss reveal">
  <div><span class="eyebrow">Free &amp; open source</span><div class="price">$0</div><p class="lede" style="margin-top:20px">No trial, no tiers, no “Pro”. Every tool is in the one app, and the code is open under the MIT licence.</p>
    <div class="cta" style="justify-content:flex-start">${dl()}${gh("Read the source")}</div></div>
  <dl><div><dt>Price</dt><dd>Free</dd></div><div><dt>Licence</dt><dd>MIT</dd></div><div><dt>Tools</dt><dd>52, all included</dd></div><div><dt>Account</dt><dd>None</dd></div><div><dt>Requires</dt><dd>macOS 14 or later</dd></div></dl>
</div></div></section>

<section id="faq" class="alt"><div class="wrap">
  <div class="center"><span class="eyebrow">Questions</span><h2>Good to know</h2></div>
  <div class="faq">${faq.map(([q, a], i) => `<details${i === 0 ? " open" : ""}><summary>${q}</summary><div><p>${a}</p></div></details>`).join("")}</div>
</div></section>

<section class="final-cta" id="get"><i class="float f1"><i></i><i></i><i></i><i></i></i><i class="float f2"><i></i><i></i><i></i></i><i class="float f3"><i></i><i></i><i></i></i><i class="float f4"><i></i><i></i></i>
  <div class="wrap"><img class="appicon" src="favicon.svg" alt="" width="160" height="160"><h2 class="reveal">Get Super PDF.</h2><p class="lede reveal" data-d="1">Free, on your Mac, in about a minute.</p>
  <div class="cta reveal" data-d="2"><a class="btn primary big" data-magnet href="${DMG}"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 4v11M7 11l5 5 5-5M5 20h14"/></svg>Download for Mac</a><a class="btn ghost big" data-magnet href="${REPO}">View on GitHub</a></div>
  <div class="metas reveal" data-d="2"><span>Free</span><span>macOS 14+</span><span>Apple silicon &amp; Intel</span></div><div class="reveal" data-d="2">${installBox}</div></div></section>
</main>
<footer class="footer"><div class="wrap">
  <div><a class="brand" href="./"><img src="favicon.svg" alt="" width="28" height="28">Super PDF</a><p style="margin-top:12px;max-width:26em">Every Acrobat tool, as simple as Preview, all on your Mac.</p></div>
  <div><h4>Product</h4><ul><li><a href="#tools">Tools</a></li><li><a href="#features">Features</a></li><li><a href="${DMG}">Download</a></li></ul></div>
  <div><h4>Project</h4><ul><li><a href="${REPO}">Source code</a></li><li><a href="${REPO}/releases">Releases</a></li><li><a href="${REPO}/blob/main/CHANGELOG.md">Changelog</a></li></ul></div>
  <div><h4>Legal</h4><ul><li><a href="${REPO}/blob/main/PRIVACY.md">Privacy</a></li><li><a href="${REPO}/blob/main/LICENSE">MIT licence</a></li><li><a href="${REPO}/blob/main/THIRD_PARTY_NOTICES.md">Third-party notices</a></li></ul></div>
  <p class="legal">© 2026 Super PDF. Free software under the MIT licence. Mac is a trademark of Apple Inc. Super PDF is not affiliated with Apple or with any other PDF software maker.</p>
</div></footer>
<div class="getbar" id="getbar"><img src="favicon.svg" alt="" width="30" height="30"><p><b>Super PDF</b><span>Free · macOS 14+</span></p><a class="btn primary" href="${DMG}">Download</a></div>
<script src="app.js?v=${sha(js)}" defer></script>
</body>
</html>
`;
writeFileSync(out("index.html"), html);
// Social card source (rendered to og.png by src/render-assets.mjs): the hero, 1200x630.
writeFileSync(here("og.html"), `<!doctype html><html lang="en"><head><meta charset="utf-8"><link rel="stylesheet" href="../style.css"><style>
html,body{margin:0;width:1200px;height:630px;overflow:hidden;background:linear-gradient(160deg,#f7faff,#e9f0ff 60%,#f3e9ff)}
.card{position:relative;width:1200px;height:630px;padding:70px 0 0 72px;color:#1d1d1f}
.card h1{font-size:76px;line-height:1.02;max-width:560px;margin:34px 0 0}.card .brand{font-size:26px;color:#1d1d1f}.card .brand img{width:46px;height:46px}
.card>p{font-size:26px;color:#6e6e73;margin-top:26px;max-width:520px;line-height:1.35}
.win{position:absolute;left:640px;top:150px;width:980px}
.pill{display:inline-block;margin-top:30px;background:#007AFF;color:#fff;font-weight:600;font-size:24px;padding:12px 28px;border-radius:14px}
</style></head><body><div class="card"><div class="brand"><img src="../favicon.svg" alt="">Super PDF</div><h1>Every Acrobat tool. As simple as Preview.</h1><p>Free, open source, all on your Mac. No AI, no account.</p><span class="pill">Free download</span>
<div class="win">${heroMock.replace('hero-demo', 'hero-demo" data-static="" data-scene="3')}</div></div></body></html>`);
console.log("built", { css: sha(css), js: sha(js), bytes: html.length });
