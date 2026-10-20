// Renders every mockup in this folder to ../<name>.png with headless Chrome through the CDP helper.
// Usage: node <path-to-cdp.js> render.js   (cdp.js spawns Chrome and passes a page driver)
const fs = require("fs");
const path = require("path");
const SRC = __dirname;
const OUT = path.join(SRC, "..");
const files = fs.readdirSync(SRC).filter((f) => f.endsWith(".html")).sort();
const darkToo = new Set(["main-window.html", "tools-sheet.html"]);
module.exports = async (page) => {
  await page.viewport(1240, 900, 2);
  for (const f of files) {
    await page.media([{ name: "prefers-color-scheme", value: "light" }]);
    await page.goto("file://" + path.join(SRC, f));
    await page.sleep(300);
    await page.shot(path.join(OUT, f.replace(/\.html$/, ".png")));
    if (darkToo.has(f)) {
      await page.media([{ name: "prefers-color-scheme", value: "dark" }]);
      await page.eval("document.body.classList.add('dark-wall')");
      await page.sleep(200);
      await page.shot(path.join(OUT, f.replace(/\.html$/, "-dark.png")));
    }
    console.log("rendered", f);
  }
};
