(() => {
  const root = document.documentElement;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Reveal on scroll (opacity/transform only, so nothing shifts layout).
  const targets = document.querySelectorAll(".reveal, .mock, .group");
  if ("IntersectionObserver" in window && !reduce) {
    const io = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } }), { threshold: 0.18 });
    targets.forEach((t) => io.observe(t));
  } else targets.forEach((t) => t.classList.add("in"));

  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const fine = matchMedia("(pointer: fine)").matches;

  // Hero: the app works on the document, scene by scene (rearrange, shrink, black out, sign).
  const demo = document.querySelector(".hero-demo");
  if (demo) {
    const size = demo.querySelector("[data-size]"), bar = demo.querySelector("[data-bar]");
    const SCENES = [3300, 3600, 3000, 3800]; let scene = 0, timer = 0, visible = true, raf = 0;
    const tween = (from, to, ms, fn) => { cancelAnimationFrame(raf); const t0 = performance.now(); const step = (n) => { const k = clamp((n - t0) / ms); fn(from + (to - from) * (1 - Math.pow(1 - k, 3))); if (k < 1) raf = requestAnimationFrame(step); }; raf = requestAnimationFrame(step); };
    const show = (i) => {
      scene = i; demo.dataset.scene = String(i);
      demo.dataset.shuffle = i === 0 ? "1" : "0";
      if (i === 0) { demo.dataset.shuffle = "0"; setTimeout(() => (demo.dataset.shuffle = "1"), 700); }
      if (i === 1) tween(6.1, 2.8, 2400, (v) => { size.textContent = v.toFixed(1); bar.style.setProperty("--w", ((v / 6.1) * 100).toFixed(0) + "%"); });
      else if (i === 0) { size.textContent = "6.1"; bar.style.setProperty("--w", "100%"); }
    };
    const loop = () => { clearTimeout(timer); if (!visible) return; timer = setTimeout(() => { show((scene + 1) % 4); loop(); }, SCENES[scene]); };
    if (reduce) { demo.dataset.static = ""; demo.dataset.scene = "3"; size.textContent = "2.8"; bar.style.setProperty("--w", "46%"); }
    else { setTimeout(() => { show(0); loop(); }, 2000); new IntersectionObserver((e) => { visible = e[0].isIntersecting; if (visible) loop(); else clearTimeout(timer); }).observe(demo); }
  }

  // Scroll-linked: hero tilt, pinned showcase, final CTA parallax, sticky download bar.
  const heroTilt = document.querySelector(".hero-tilt"), track = document.getElementById("sc-track");
  const scenes = [...document.querySelectorAll(".sc")], steps = [...document.querySelectorAll(".sc-step")];
  const finalCta = document.getElementById("get"), bar = document.getElementById("getbar"), heroCta = document.querySelector(".hero .cta");
  const setNum = (root, t) => root.querySelectorAll("[data-from]").forEach((n) => { const f = +n.dataset.from, e = +n.dataset.to; n.textContent = (f + (e - f) * t).toFixed(+n.dataset.dec); });
  let ticking = false;
  function frame() {
    ticking = false; const vh = innerHeight;
    if (heroTilt && !reduce) heroTilt.style.setProperty("--hp", clamp(scrollY / (vh * 0.9)).toFixed(3));
    if (track && !reduce && innerWidth > 0) {
      const r = track.getBoundingClientRect(); const p = clamp(-r.top / (r.height - vh * 0.9));
      const n = scenes.length, cur = Math.min(n - 1, Math.floor(p * n));
      scenes.forEach((s, i) => { const t = clamp((p * n - i) / 0.8); s.style.setProperty("--t", t.toFixed(3)); s.classList.toggle("on", i === cur); setNum(s, t); });
      steps.forEach((s, i) => { s.classList.toggle("on", i === cur); s.style.setProperty("--t", clamp((p * n - i) / 0.8).toFixed(3)); });
    }
    if (finalCta && !reduce) { const r = finalCta.getBoundingClientRect(); finalCta.style.setProperty("--fp", clamp(1 - r.bottom / (vh + r.height)).toFixed(3)); }
    if (bar) { const hc = heroCta.getBoundingClientRect(), fc = finalCta.getBoundingClientRect(); bar.classList.toggle("on", hc.bottom < 0 && fc.top > vh * 0.7); }
  }
  const tick = () => { if (!ticking) { ticking = true; requestAnimationFrame(frame); } };
  addEventListener("scroll", tick, { passive: true }); addEventListener("resize", tick); frame();
  if (reduce) { scenes.forEach((s) => setNum(s, 1)); }

  // Magnetic download buttons.
  if (fine && !reduce) document.querySelectorAll("[data-magnet]").forEach((b) => {
    let r = 0; b.addEventListener("pointermove", (e) => { const q = b.getBoundingClientRect(); const x = (e.clientX - q.left - q.width / 2) * 0.22, y = (e.clientY - q.top - q.height / 2) * 0.3; cancelAnimationFrame(r); r = requestAnimationFrame(() => (b.style.transform = `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px)`)); });
    b.addEventListener("pointerleave", () => { cancelAnimationFrame(r); b.style.transition = "transform .45s cubic-bezier(.2,.8,.2,1)"; b.style.transform = ""; setTimeout(() => (b.style.transition = ""), 460); });
  });

  // Tile spotlight follows the pointer.
  const gridEl = document.getElementById("tool-grid");
  if (gridEl && fine) gridEl.addEventListener("pointermove", (e) => { const t = e.target.closest(".tile"); if (!t) return; const q = t.getBoundingClientRect(); t.style.setProperty("--mx", e.clientX - q.left + "px"); t.style.setProperty("--my", e.clientY - q.top + "px"); });

  // Copy the installer line.
  document.querySelectorAll("[data-copy]").forEach((b) => b.addEventListener("click", async () => {
    try { await navigator.clipboard.writeText(b.dataset.copy); b.textContent = "Copied"; setTimeout(() => (b.textContent = "Copy"), 1600); } catch { b.textContent = "Select and copy"; }
  }));

  // Make smaller: the three presets are a radio group.
  document.querySelectorAll(".m-opts").forEach((g) => g.addEventListener("click", (e) => {
    const o = e.target.closest("[role=radio]"); if (!o) return;
    g.querySelectorAll("[role=radio]").forEach((x) => x.setAttribute("aria-checked", String(x === o)));
  }));

  // Tools grid: search name, hint and synonyms; filter by section.
  const input = document.getElementById("tool-search"); if (!input) return;
  const tiles = [...document.querySelectorAll(".tile")];
  const groups = [...document.querySelectorAll(".group")];
  const chips = [...document.querySelectorAll(".chip")];
  const count = document.getElementById("tool-count"); const empty = document.getElementById("tool-empty");
  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  let section = "all";
  tiles.forEach((t) => { t._n = t.querySelector("b"); t._h = t.querySelector("span"); t._nt = t._n.textContent; t._ht = t._h.textContent; });
  function mark(el, text, re) { el.replaceChildren(); if (!re) { el.textContent = text; return; } let last = 0; for (const m of text.matchAll(re)) { el.append(text.slice(last, m.index)); const k = document.createElement("mark"); k.textContent = m[0]; el.append(k); last = m.index + m[0].length; } el.append(text.slice(last)); }
  function apply() {
    const q = input.value.trim().toLowerCase(); const terms = q.split(/\s+/).filter(Boolean);
    const re = terms.length ? new RegExp(terms.map(esc).join("|"), "gi") : null; let n = 0;
    tiles.forEach((t) => {
      const hay = (t._nt + " " + t._ht + " " + t.dataset.syn).toLowerCase();
      const ok = (section === "all" || t.dataset.section === section) && terms.every((w) => hay.includes(w));
      t.hidden = !ok; if (ok) { n++; mark(t._n, t._nt, re); mark(t._h, t._ht, re); }
    });
    groups.forEach((g) => (g.hidden = !g.querySelector(".tile:not([hidden])")));
    count.textContent = n === tiles.length ? `All ${n} tools` : `${n} of ${tiles.length} tools`;
    empty.hidden = n !== 0;
  }
  input.addEventListener("input", apply);
  chips.forEach((c) => c.addEventListener("click", () => { section = c.dataset.section; chips.forEach((x) => x.setAttribute("aria-pressed", String(x === c))); apply(); }));
  addEventListener("keydown", (e) => { if (e.key === "/" && !/INPUT|TEXTAREA/.test(document.activeElement.tagName)) { e.preventDefault(); input.focus({ preventScroll: false }); } if (e.key === "Escape" && document.activeElement === input) { input.value = ""; apply(); } });
  apply();
})();
