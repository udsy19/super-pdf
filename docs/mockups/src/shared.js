/* Super PDF mockups — shared components. Each screen calls SP.render({...}). */
(function () {
  const svg = (d, extra = "") => `<svg viewBox="0 0 24 24" ${extra}>${d}</svg>`;
  const I = {
    sidebar: svg('<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M9 4v16"/>'),
    chev: svg('<path d="M6 9l6 6 6-6"/>'),
    chevL: svg('<path d="M15 6l-6 6 6 6"/>'),
    chevR: svg('<path d="M9 6l6 6-6 6"/>'),
    minus: svg('<path d="M5 12h14"/>'),
    plus: svg('<path d="M12 5v14M5 12h14"/>'),
    one: svg('<path d="M10 7l3-2v14M9 19h8"/>'),
    markup: svg('<path d="M4 20l4-1 10-10-3-3L5 16z"/><path d="M13 7l3 3"/>'),
    rotate: svg('<path d="M3 12a9 9 0 1 0 3-6.7"/><path d="M3 4v5h5"/>'),
    rotateR: svg('<path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 4v5h-5"/>'),
    tools: svg('<rect x="4" y="4" width="6" height="6" rx="1.5"/><rect x="14" y="4" width="6" height="6" rx="1.5"/><rect x="4" y="14" width="6" height="6" rx="1.5"/><rect x="14" y="14" width="6" height="6" rx="1.5"/>'),
    share: svg('<path d="M12 3v12"/><path d="M8 7l4-4 4 4"/><path d="M5 12v7a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-7"/>'),
    search: svg('<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>'),
    x: svg('<path d="M6 6l12 12M18 6L6 18"/>'),
    check: svg('<path d="M5 12l5 5 9-10"/>'),
    form: svg('<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 10h6M7 14h4"/>'),
    doc: svg('<path d="M6 3h8l5 5v13H6z"/><path d="M14 3v5h5"/>'),
    docs: svg('<path d="M8 3h7l4 4v10H8z"/><path d="M15 3v4h4"/><path d="M5 7v13h11"/>'),
    shrink: svg('<path d="M4 14v6h6M20 10V4h-6"/><path d="M4 20l7-7M20 4l-7 7"/>'),
    ocr: svg('<path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3"/><path d="M8 12h8M12 9v6"/>'),
    redact: svg('<rect x="3" y="7" width="18" height="10" rx="1.5"/><path d="M7 12h4"/>'),
    lock: svg('<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>'),
    unlock: svg('<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 7.5-2"/>'),
    sig: svg('<path d="M4 17c3-6 5-8 6-8s0 8 2 8 3-6 4-6 1 4 3 4 2-2 2-2"/><path d="M3 21h18"/>'),
    people: svg('<circle cx="9" cy="8" r="3.5"/><path d="M3 20a6 6 0 0 1 12 0"/><circle cx="17" cy="9" r="2.5"/><path d="M15.5 14.5A5 5 0 0 1 21 19"/>'),
    compare: svg('<rect x="3" y="4" width="8" height="16" rx="1.5"/><rect x="13" y="4" width="8" height="16" rx="1.5"/><path d="M6 9h2M16 9h2M6 13h2M16 13h2"/>'),
    seal: svg('<circle cx="12" cy="12" r="8"/><path d="M9 12l2 2 4-4"/>'),
    globe: svg('<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3.5 3 14.5 0 18M12 3c-3 3.5-3 14.5 0 18"/>'),
    speaker: svg('<path d="M4 9v6h4l5 4V5L8 9z"/><path d="M16 9a4 4 0 0 1 0 6M18.5 6.5a7.5 7.5 0 0 1 0 11"/>'),
    camera: svg('<path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/>'),
    scanner: svg('<path d="M4 14h16v5H4z"/><path d="M6 14V5h12v9"/><path d="M8 9h8"/>'),
    photo: svg('<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="8.5" cy="10" r="1.5"/><path d="M21 16l-5-5-8 8"/>'),
    text: svg('<path d="M5 6h14M12 6v13M9 19h6"/>'),
    header: svg('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M3 15h18"/>'),
    drop: svg('<path d="M12 3s6 7 6 11a6 6 0 0 1-12 0c0-4 6-11 6-11z"/>'),
    hash: svg('<path d="M5 9h14M5 15h14M10 4l-2 16M16 4l-2 16"/>'),
    stamp: svg('<path d="M9 10V6a3 3 0 0 1 6 0v4"/><path d="M5 14h14v3H5z"/><path d="M7 20h10"/>'),
    link: svg('<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>'),
    list: svg('<path d="M9 6h11M9 12h11M9 18h11"/><path d="M4 6h.01M4 12h.01M4 18h.01"/>'),
    batch: svg('<path d="M4 7h7l2 2h7v10H4z"/><path d="M4 7V4h5l2 3"/>'),
    highlight: svg('<path d="M4 20h6"/><path d="M8 16l8-8 3 3-8 8H8z"/><path d="M14 10l3 3"/>'),
    pen: svg('<path d="M4 20c4-1 6-4 9-9"/><path d="M13 11l4-4 2 2-4 4z"/>'),
    comment: svg('<path d="M4 5h16v11H10l-4 3v-3H4z"/><path d="M8 9h8M8 12h5"/>'),
    paperclip: svg('<path d="M20 11l-8 8a5 5 0 0 1-7-7l8-8a3.5 3.5 0 0 1 5 5l-8 8a2 2 0 0 1-3-3l7-7"/>'),
    ruler: svg('<path d="M3 17l14-14 4 4L7 21z"/><path d="M7 13l2 2M10 10l2 2M13 7l2 2"/>'),
    formfill: svg('<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 10h4M7 14h7"/><path d="M15 9l2 2"/>'),
    formmake: svg('<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 10h4M7 14h4"/><path d="M16 9v6M13 12h6"/>'),
    cert: svg('<circle cx="12" cy="9" r="5"/><path d="M9 13l-1 8 4-2 4 2-1-8"/>'),
    eye: svg('<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>'),
    broom: svg('<path d="M14 3l7 7"/><path d="M11 6l7 7-6 6-7-7z"/><path d="M5 12l-2 9 9-2"/>'),
    printer: svg('<path d="M6 9V3h12v6"/><rect x="3" y="9" width="18" height="8" rx="2"/><path d="M6 14h12v7H6z"/>'),
    wrench: svg('<path d="M14 6a4 4 0 0 0 5 5l-9 9a2 2 0 0 1-3-3l9-9z"/><path d="M14 6l4 4"/>'),
    summ: svg('<path d="M5 6h14M5 10h14M5 14h9M5 18h6"/>'),
    split: svg('<path d="M12 3v18"/><rect x="3" y="6" width="6" height="12" rx="1"/><rect x="15" y="6" width="6" height="12" rx="1"/>'),
    extract: svg('<path d="M6 3h8l5 5v4"/><path d="M14 3v5h5"/><path d="M6 3v18h7"/><path d="M17 15v6M14 18l3 3 3-3"/>'),
    trash: svg('<path d="M4 7h16M9 7V4h6v3M6 7l1 14h10l1-14"/>'),
    crop: svg('<path d="M6 2v16h16"/><path d="M2 6h16v16"/>'),
    insert: svg('<path d="M6 3h8l5 5v13H6z"/><path d="M14 3v5h5"/><path d="M12 11v6M9 14h6"/>'),
    booklet: svg('<path d="M12 5c-2-1.5-5-1.5-8 0v14c3-1.5 6-1.5 8 0 2-1.5 5-1.5 8 0V5c-3-1.5-6-1.5-8 0z"/><path d="M12 5v14"/>'),
    resize: svg('<rect x="4" y="4" width="16" height="16" rx="2"/><path d="M9 15l6-6M15 12V9h-3"/>'),
    word: svg('<path d="M6 3h8l5 5v13H6z"/><path d="M14 3v5h5"/><path d="M8 12l1.5 6 2-5 2 5L15 12"/>'),
    excel: svg('<path d="M6 3h8l5 5v13H6z"/><path d="M14 3v5h5"/><path d="M8 12h8M8 15h8M8 18h8M12 12v6"/>'),
    ppt: svg('<path d="M6 3h8l5 5v13H6z"/><path d="M14 3v5h5"/><rect x="8.5" y="12" width="7" height="5" rx="1"/>'),
    archive: svg('<rect x="3" y="4" width="18" height="5" rx="1"/><path d="M5 9v11h14V9"/><path d="M10 13h4"/>'),
    html: svg('<path d="M8 8l-4 4 4 4M16 8l4 4-4 4M13 6l-2 12"/>'),
    img2pdf: svg('<rect x="3" y="4" width="12" height="10" rx="1.5"/><path d="M6 11l2-2 2 2 2-3 3 3"/><path d="M15 10h3l3 3v8h-9v-4"/>'),
    any: svg('<path d="M6 3h8l5 5v13H6z"/><path d="M14 3v5h5"/><path d="M9 15l3-3 3 3"/>'),
    send: svg('<path d="M12 19V6"/><path d="M6 12l6-6 6 6"/>'),
    dots: svg('<circle cx="6" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="18" cy="12" r="1.5"/>'),
    updown: svg('<path d="M8 10l4-4 4 4M8 14l4 4 4-4"/>'),
    folder: svg('<path d="M3 7h6l2 2h10v10H3z"/>'),
    mail: svg('<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 6 9-6"/>'),
    airdrop: svg('<circle cx="12" cy="12" r="3"/><path d="M7 7a7 7 0 0 0 0 10M17 7a7 7 0 0 1 0 10"/>'),
    msg: svg('<path d="M12 4c-5 0-8 3-8 6.5S7 17 12 17c.7 0 1.3 0 2-.2L18 19l-1-3c1.9-1.2 3-3 3-5.5S17 4 12 4z"/>'),
    bars: svg('<path d="M4 6h16M4 12h16M4 18h16"/>'),
    grid: svg('<rect x="3" y="3" width="8" height="8"/><rect x="13" y="3" width="8" height="8"/><rect x="3" y="13" width="8" height="8"/><rect x="13" y="13" width="8" height="8"/>'),
    expand: svg('<path d="M4 10V4h6M20 14v6h-6"/><path d="M4 4l6 6M20 20l-6-6"/>'),
  };

  const lease = [
    { h1: "Residential Lease Agreement", sub: "Prepared 14 September 2026 · 12 pages", body: `
<h2>1. Parties</h2>
<p>This Residential Lease Agreement (the "Agreement") is entered into on 14 September 2026 between <b>Margaret Ellison</b> ("Landlord"), of 48 Orchard Lane, Bath, and <b>Priya Natarajan</b> ("Tenant"). The Landlord agrees to let, and the Tenant agrees to take, the premises described below on the terms set out in this Agreement.</p>
<h2>2. Premises</h2>
<p>The premises are the two-bedroom flat known as Flat 3, 112 Walcot Street, Bath BA1 5BG, together with the storage locker numbered 3 in the basement and one allocated parking space. The premises are let furnished according to the inventory attached as Schedule A.</p>
<h2>3. Term</h2>
<p>The tenancy begins on 1 October 2026 and continues for a fixed term of twelve months, ending on 30 September 2027. Either party may give two months' written notice to end the tenancy after the fixed term has expired. Notice must be given in writing and delivered by hand, by post or by email to the addresses in clause 14.</p>
<h2>4. Rent</h2>
<p>The Tenant shall pay rent of £1,450 per calendar month in advance on the first day of each month, by standing order to the Landlord's nominated bank account. The first payment is due on or before the start date. Rent includes water rates but excludes gas, electricity, broadband and council tax.</p>
<h2>5. Deposit</h2>
<p>A deposit of £1,670 is payable on signing and will be protected with an approved tenancy deposit scheme within thirty days. The deposit will be returned within ten working days of the end of the tenancy, less any agreed deductions.</p>` },
    { h1: "Residential Lease Agreement", sub: "Page 3 of 12 — Schedule of payments", body: `
<h2>6. Payment schedule</h2>
<p>The following table sets out the payments due during the fixed term. Dates falling on a weekend or bank holiday are payable on the next working day.</p>
<table><tr><th>Due date</th><th>Description</th><th>Amount</th><th>Paid</th></tr>
<tr><td>14 Sep 2026</td><td>Deposit</td><td>£1,670.00</td><td>Yes</td></tr>
<tr><td>1 Oct 2026</td><td>Rent — October</td><td>£1,450.00</td><td>Yes</td></tr>
<tr><td>1 Nov 2026</td><td>Rent — November</td><td>£1,450.00</td><td>—</td></tr>
<tr><td>1 Dec 2026</td><td>Rent — December</td><td>£1,450.00</td><td>—</td></tr>
<tr><td>1 Jan 2027</td><td>Rent — January</td><td>£1,450.00</td><td>—</td></tr></table>
<h2>7. Contact details</h2>
<p class="contact">Landlord: Margaret Ellison, 48 Orchard Lane, Bath BA2 4QS. Telephone <span class="ph-land nb">01225 448 912</span>, email <span class="em-land nb">m.ellison@orchardlets.co.uk</span>.</p>
<p class="contact">Tenant: Priya Natarajan. Telephone <span class="ph-ten nb">07700 900 417</span>, email <span class="em-ten nb">priya.natarajan@example.com</span>. National Insurance number <span class="ni nb">QQ 12 34 56 C</span>.</p>
<h2>8. Utilities</h2>
<p>The Tenant is responsible for arranging and paying for gas, electricity, broadband and council tax from the start date, and for notifying the suppliers of the meter readings taken at check-in, which are recorded in Schedule B.</p>
<div class="sigline"><div>Landlord signature · Date</div><div>Tenant signature · Date</div></div>` },
  ];

  function pageHTML(n, opts = {}) {
    const d = lease[n === 3 ? 1 : 0];
    return `<div class="page" data-page="${n}" ${opts.id ? `id="${opts.id}"` : ""}>
      <h1>${d.h1}</h1><div class="sub">${d.sub}</div>${d.body}
      <div class="foot"><span>Flat 3, 112 Walcot Street</span><span>Page ${n} of 12</span></div>${opts.extra || ""}</div>`;
  }

  function thumbHTML(n, sel) {
    const lines = n === 3
      ? `<div class="l t" style="top:14%"></div><div class="l" style="top:26%"></div><div class="l" style="top:31%"></div><div class="l" style="top:40%;height:22%;background:#e2e2e2"></div><div class="l" style="top:68%"></div><div class="l" style="top:73%"></div><div class="l" style="top:78%"></div>`
      : `<div class="l t" style="top:14%"></div><div class="l" style="top:26%"></div><div class="l" style="top:31%"></div><div class="l" style="top:36%"></div><div class="l" style="top:44%"></div><div class="l" style="top:49%"></div><div class="l" style="top:54%"></div><div class="l" style="top:62%"></div><div class="l" style="top:67%"></div><div class="l" style="top:72%"></div>`;
    return `<div class="thumb ${sel ? "sel" : ""}"><div class="pg">${lines}</div><div class="num">${n}</div></div>`;
  }

  function toolbar(o) {
    const c = o.toolbar || {};
    return `<div class="titlebar">
      <div class="tb-left">
        <div class="lights"><i class="r"></i><i class="y"></i><i class="g"></i></div>
        <div class="tbtn icon-only view-pop">${I.sidebar}<span class="chev">${I.chev}</span></div>
        <div class="tb-sep"></div>
        <div class="seg"><div class="tbtn icon-only">${I.minus}</div><div class="tbtn icon-only">${I.one}</div><div class="tbtn icon-only">${I.plus}</div></div>
      </div>
      <div class="title"><span class="proxy"></span>${o.title || "Lease agreement.pdf"}${o.edited ? ' <span class="edited">— Edited</span>' : ""}</div>
      <div class="tb-right">
        <div class="tbtn icon-only" title="Markup">${I.markup}</div>
        <div class="tbtn icon-only" title="Rotate">${I.rotate}</div>
        ${c.formFilling ? `<div class="tbtn icon-only" title="Form Filling">${I.form}</div>` : ""}
        <div style="width:8px"></div>
        <div class="tbtn prominent">${I.tools}Tools</div>
        <div class="tbtn icon-only" title="Share">${I.share}</div>
        <div class="search">${I.search}<span>Search</span></div>
      </div>
    </div>`;
  }

  function sidebar(o) {
    const sel = o.selected || [];
    const n = o.thumbCount || 4;
    let t = "";
    for (let i = 1; i <= n; i++) t += thumbHTML(i, sel.includes(i));
    return `<div class="sidebar"><div class="thumbs">${t}</div><div class="sb-bottom"><span>12 pages</span><span class="plus">${I.plus}</span></div></div>`;
  }

  function panelHeader(o) {
    return `<div class="ph"><div class="row"><span class="back">${I.chevL}</span><span class="ttl"><span class="cat ${o.cat}">${I[o.icon]}</span>${o.title}</span><span class="close">${I.x}</span></div><div class="hint">${o.hint}</div>${o.after || ""}</div>`;
  }

  function render(o) {
    document.body.insertAdjacentHTML("beforeend", `<div class="win ${o.small ? "small" : ""}">
      ${o.titlebarHTML !== undefined ? o.titlebarHTML : toolbar(o)}
      ${o.bannerHTML || ""}
      <div class="body">
        ${o.full ? o.full : `${o.noSidebar ? "" : sidebar(o)}<div class="well">${o.wellHTML || pageHTML(1) + pageHTML(2)}</div>${o.panelHTML || ""}`}
        ${o.overlayHTML || ""}
      </div>
      ${o.sheetHTML ? `<div class="dim"></div>${o.sheetHTML}` : ""}
    </div>`);
  }

  window.SP = { I, pageHTML, thumbHTML, toolbar, sidebar, panelHeader, render };
})();
