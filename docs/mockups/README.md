# Mockups

High-fidelity HTML/CSS mockups of the screens in `../specs/ux.md`, rendered to PNG at 2× with headless Chrome. Light
appearance is the reference; two screens are also rendered in dark appearance.

| PNG | Screen | ux.md |
|---|---|---|
| `welcome.png` | Welcome window: four big targets, recents | §6.1 |
| `main-window.png` (+ `-dark`) | Document window with thumbnail sidebar, Tools button, page context menu | §2, §6.3 |
| `main-window-result.png` | Result banner after "Make smaller" | §7.3 |
| `tools-sheet.png` (+ `-dark`) | The Tools sheet: search, recently used, categorised tiles | §4 |
| `panel-make-smaller.png` | Preset + more archetype (B) | §5.3 |
| `panel-black-out.png` | Mode archetype (D) with find-and-mark and live marks on the page | §5.3 |
| `panel-watermark.png` | Live-preview editor archetype (C) | §5.3 |
| `panel-to-word.png` | Convert archetype (E) | §5.3 |
| `panel-sign.png` | Sign: signature library and placement | §5.3 |
| `panel-request-signatures.png` | Flow archetype (G), step 2 of 3 | §5.3 |
| `organizer.png` | Page organiser: drag in progress, insertion line, pages from a second file | §6.2 |

## Rendering

`src/shared.css` holds the design tokens (ux.md §2.3) and components; `src/shared.js` builds the window chrome, the
fake lease document and the thumbnails; each `src/*.html` declares one screen. `src/render.js` renders every screen
through a minimal CDP driver that launches Google Chrome headless (any `cdp.js`-style driver that exposes
`viewport/goto/media/eval/shot` works):

```sh
node path/to/cdp.js docs/mockups/src/render.js
```

The mockups use the system font, so they must be rendered on a Mac to look right.
