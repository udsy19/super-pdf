// Renders og.png (1200x630) and the PNG favicons with headless Chrome.   node website/src/render-assets.mjs
import { execFileSync } from "node:child_process";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
const CH = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const here = (p) => new URL(p, import.meta.url).pathname;
const shot = (url, out, w, h, extra = []) => execFileSync(CH, ["--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1", `--window-size=${w},${h}`, ...extra, `--screenshot=${out}`, url], { stdio: "ignore", timeout: 60000 });
shot("file://" + here("og.html"), here("../og.png"), 1200, 630, ["--virtual-time-budget=3000"]);
const dir = mkdtempSync(join(tmpdir(), "spdf-"));
for (const [size, name] of [[32, "favicon-32.png"], [180, "apple-touch-icon.png"]]) {
  const page = join(dir, `${size}.html`);
  writeFileSync(page, `<!doctype html><style>html,body{margin:0;background:${size === 180 ? "#fff" : "transparent"}}img{width:${size}px;height:${size}px;display:block}</style><img src="file://${here("../favicon.svg")}">`);
  shot("file://" + page, here("../" + name), size, size, size === 32 ? ["--default-background-color=00000000"] : []);
}
