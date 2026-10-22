// Super PDF website: the Combine sequence in the hero, the Tools search, and the installer's Copy button.
(() => {
  const root = document.documentElement;

  // ---------- hero: four files land in a heap on the Combine canvas, then snap into order ----------
  const ws = document.getElementById("combine");
  if (ws && root.classList.contains("play")) {
    const cards = [...ws.querySelectorAll(".ws-grid > .fc:not(.drop)")];
    const drop = ws.querySelector("[data-drop]");
    const sub = ws.querySelector("[data-sub]");
    const status = ws.querySelector("[data-status]");
    const finish = ws.querySelector("[data-finish]");
    const budget = ws.querySelector('[data-k="budget"]');
    const cap = budget.querySelector("[data-cap]");
    const bar = budget.querySelector(".conv b i");
    const capDone = cap.textContent;

    const count = (files, pages) => {
      if (!files) { sub.textContent = "No files yet"; status.textContent = ""; return; }
      const f = `${files} ${files === 1 ? "file" : "files"}`, p = `${pages} ${pages === 1 ? "page" : "pages"}`;
      sub.textContent = `${f} · ${p}`;
      status.innerHTML = `<b>${f}</b> · ${p}`;
    };
    const at = (ms, fn) => setTimeout(fn, ms);

    // The files land in a heap in the middle of the canvas.
    const target = ws.querySelector(".ws-grid").getBoundingClientRect();
    const hx = target.left + target.width / 2, hy = target.top + target.height / 2;
    const tilt = [-8, 6, -3, 9], nudge = [[-22, -8], [18, -14], [-8, 10], [14, 6]];
    const STEP = 150, LAND = 420, REST = 480, SNAP = 760, SNAP_STEP = 70;
    const HEAP = (cards.length - 1) * STEP + LAND + REST; // the last card has landed and settled

    ws.classList.add("pre");
    finish.classList.add("idle");
    budget.classList.add("converting");
    cap.textContent = "Converting to PDF…";
    count(0, 0);

    cards.forEach((c, i) => {
      const r = c.getBoundingClientRect(), rest = getComputedStyle(c).boxShadow;
      const heap = `translate(${hx - (r.left + r.width / 2) + nudge[i][0]}px, ${hy - (r.top + r.height / 2) + nudge[i][1]}px) rotate(${tilt[i]}deg)`;
      const lifted = "0 14px 28px -8px rgba(22,26,51,.3)";
      const total = HEAP + i * SNAP_STEP + SNAP - i * STEP; // land STEP apart, leave the heap in order SNAP_STEP apart
      c.animate([
        { transform: `${heap} translateY(-48px) scale(1.14)`, opacity: 0, boxShadow: "0 34px 50px -12px rgba(22,26,51,.4)", easing: "cubic-bezier(.2,.7,.3,1)" },
        { transform: `${heap} scale(1)`, opacity: 1, boxShadow: lifted, offset: LAND / total },
        { transform: `${heap} scale(1)`, opacity: 1, boxShadow: lifted, offset: 1 - SNAP / total, easing: "cubic-bezier(.3,1.25,.5,1)" },
        { transform: "none", opacity: 1, boxShadow: rest },
      ], { duration: total, delay: i * STEP, fill: "backwards" });
    });
    root.classList.remove("play");

    // What the window says while it happens.
    drop.classList.add("hot");
    const pages = [12, 1, 0, 3];
    let files = 0, sum = 0;
    cards.forEach((c, i) => at(i * STEP + LAND, () => { files += 1; sum += pages[i]; count(files, sum); }));
    const landed = (cards.length - 1) * STEP + LAND;
    at(landed + 120, () => drop.classList.remove("hot"));
    const convStart = 2 * STEP + LAND, convLen = 1500;
    if (bar) bar.animate([{ width: "0%" }, { width: "100%" }], { duration: convLen, delay: convStart, easing: "cubic-bezier(.4,0,.2,1)", fill: "both" });
    at(convStart + convLen, () => { budget.classList.remove("converting"); cap.textContent = capDone; sum += 1; count(files, sum); });
    const settled = HEAP + (cards.length - 1) * SNAP_STEP + SNAP;
    at(Math.max(settled, convStart + convLen) + 80, () => { ws.classList.remove("pre"); finish.classList.remove("idle"); });
  }

  // ---------- Tools search: names, hints and the catalog's synonyms ----------
  const q = document.getElementById("q");
  if (q) {
    const items = [...document.querySelectorAll(".cat li")];
    const cats = [...document.querySelectorAll(".cat")];
    const box = document.getElementById("cats"), countEl = document.getElementById("count"), empty = document.getElementById("empty");
    const tries = [...document.querySelectorAll("[data-try]")];
    const total = items.length;
    const filter = () => {
      const raw = q.value.trim(), words = raw.toLowerCase().split(/\s+/).filter(Boolean);
      let n = 0;
      for (const li of items) { const ok = words.every((w) => li.dataset.q.includes(w)); li.hidden = !ok; if (ok) n += 1; }
      for (const c of cats) c.hidden = !c.querySelector("li:not([hidden])");
      countEl.textContent = !words.length ? `All ${total} tools` : n ? `${n} ${n === 1 ? "tool matches" : "tools match"} “${raw}”` : "";
      empty.hidden = n > 0;
      box.classList.toggle("q", words.length > 0);
      for (const b of tries) b.setAttribute("aria-pressed", String(b.dataset.try.toLowerCase() === raw.toLowerCase()));
    };
    q.addEventListener("input", filter);
    for (const b of tries) {
      b.setAttribute("aria-pressed", "false");
      b.addEventListener("click", () => { q.value = b.getAttribute("aria-pressed") === "true" ? "" : b.dataset.try; filter(); });
    }
    if (q.value) filter();
  }

  // ---------- Copy the installer ----------
  for (const b of document.querySelectorAll("[data-copy]")) {
    b.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(b.dataset.copy); }
      catch {
        const r = document.createRange(); r.selectNodeContents(b.previousElementSibling);
        const s = getSelection(); s.removeAllRanges(); s.addRange(r);
        return;
      }
      b.textContent = "Copied";
      setTimeout(() => { b.textContent = "Copy"; }, 1600);
    });
  }
})();
