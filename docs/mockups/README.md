# Mockups

High-fidelity HTML/CSS mockups of the screens in `../specs/ux.md`, rendered to PNG at 2× with headless Chrome. Light
appearance is the reference; four screens are also rendered in dark appearance.

| PNG | Screen | ux.md |
|---|---|---|
| `welcome.png` (+ `-dark`) | Welcome window: the multicolour mark, four colourful targets, recents, the drop tip | §6.1 |
| `main-window.png` (+ `-dark`) | Document window with thumbnail sidebar, Tools button, page context menu | §2, §6.3 |
| `main-window-result.png` | Result banner after "Make smaller": the green wash and check | §7.3 |
| `tools-sheet.png` (+ `-dark`) | The Tools sheet: search, section chips, recently used, colourful tiles | §4 |
| `panel-make-smaller.png` | Preset + more archetype (B), with the section's header wash | §5.3 |
| `panel-black-out.png` | Mode archetype (D) with find-and-mark and live marks on the page | §5.3 |
| `panel-watermark.png` | Live-preview editor archetype (C) | §5.3 |
| `panel-to-word.png` | Convert archetype (E) | §5.3 |
| `panel-sign.png` | Sign: signature library and placement | §5.3 |
| `panel-request-signatures.png` | Flow archetype (G), step 2 of 3 | §5.3 |
| `workspace.png` (+ `-dark`) | The workspace, Files: four files as cards with pills, one selected, one hovered with its toolbar, one converting, the "+" between them and the add card | §6.2 |
| `workspace-pages.png` | The workspace, Pages: a page being dragged, the others sprung aside around the dashed hole | §6.2 |
| `workspace-preview.png` | The workspace's preview: the page large, its file's pill, ‹ 5 / 12 ›, rotate, delete | §6.2 |

## Rendering

`src/shared.css` holds the design tokens (ux.md §2.3: the system colours, the brand palette and the file pills) and
components; `src/shared.js` builds the window chrome, the fake lease document, the thumbnails and the workspace's cards;
each `src/*.html` declares one screen. `src/render.js` renders every screen
through a minimal CDP driver that launches Google Chrome headless (any `cdp.js`-style driver that exposes
`viewport/goto/media/eval/shot` works):

```sh
node path/to/cdp.js docs/mockups/src/render.js                                   # every screen
MOCKUP_ONLY=workspace.html node path/to/cdp.js docs/mockups/src/render.js        # just these
```

The mockups use the system font, so they must be rendered on a Mac to look right.
