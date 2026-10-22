# UX design

Super PDF is Preview with one more button, and a cheerful face. This document is the contract for how the app looks and
behaves: the window, the Tools sheet, the tool panels, drag and drop, the welcome window, the workspace (Combine and
Rearrange), copy, metrics, type, colour, motion, empty states and errors. The mockups in `../mockups/` render these screens; `features.md` says what
each tool does; `../ARCHITECTURE.md` says who builds it.

Preview facts quoted here were read statically from `/System/Applications/Preview.app` (menus, toolbar property list,
nibs, `.loctable` strings). Preview was never launched.

## 1. The idea in one paragraph

A person who can use Preview can use Super PDF without learning anything: same window, same sidebar, same menus,
same markup bar, same shortcuts. The one new thing is a blue **Tools** button in the toolbar. It opens a sheet of big
tiles, each with a plain name and one line that says what it does. Choosing a tile opens one small panel on the right
with at most three choices and one big blue button. The document itself is the preview: a watermark appears on the
page while you type it, pages shrink as you drag the "smaller" slider, black boxes appear as you choose what to hide.
The original file is never overwritten without asking. Everything is undoable. Drag does the obvious thing: pages
rearrange, dropped files combine, dragged-out pages become a new PDF. Several files dropped on the app open the
workspace: a big, friendly card per file on a soft blue canvas, each name in its own pastel pill, files of any kind
turning into PDFs on their cards while you arrange them, and one big **Finish** button.

### 1.3 The look: cheerful, never noisy

The app should feel effortless and happy to use, the way the best web PDF tools feel, while staying a fast, native Mac
app (no web look-alikes, no ads, no upsells). Five things carry the cheer; everything else stays Preview-calm:

| Ingredient | Where it shows |
|---|---|
| **One bright colour per Tools section** (§2.3) | Every tool's icon is a rounded square filled with its section's colour (lighter at the top) with a white symbol: tiles, section chips and headers in the sheet, the panel header (with a soft wash of the colour behind it), the welcome window's targets. |
| **Pastel file pills** (§2.3, §6.2) | In the workspace and in Combine's list every file's name sits in its own pastel pill with deep ink of the same hue (sky, pink, mint, peach, lavender, lemon, aqua, coral), so files are told apart at a glance and never by colour alone. |
| **A soft canvas** | The workspace sits on a light blue canvas with white rounded cards; the welcome window and the Tools sheet have a faint wash of the brand colours behind their titles. |
| **Springy motion** (§2.5) | Tiles and cards grow a touch on a lively spring under the pointer; cards spring aside to make room for what you drag; the success check pops in with a short burst of confetti; long jobs show a light sweeping across their progress. Reduce Motion turns all of it into plain crossfades. |
| **Warm, plain words** (§7) | "Drop in PDFs, photos or Office files — we’ll take it from there.", "Add PDF, image, Word, Excel, and PowerPoint files", "All set: 12 pages, in your order." Still sentence case, no jargon, no exclamation marks. |

### 1.1 The grandma test (rules that every screen passes)

| Rule | What it means in practice |
|---|---|
| **One verb per button** | A button says what will happen: "Make smaller", "Save as Word…", "Black out 12 items". Never "OK", "Apply", "Process", "Export". |
| **No jargon on the surface** | "Make smaller" (not Compress/Optimize), "Recognise text" (not OCR), "Black out" (not Redact), "Lock in notes and fields" (not Flatten), "Add a password" (not Encrypt), "Save for long-term archiving (PDF/A)" (not PDF/A conversion). The old names stay as search terms and in the hint line in brackets, so experts find them. |
| **Say what it does before it does it** | Every tile and panel has a hint line in plain words: "Shrinks the file so it's easier to send. The pages stay the same." |
| **One screen at a time** | A tool is one panel. No wizards longer than three steps, no tabs inside panels, no nested dialogs. "More options" is a disclosure at the bottom, closed by default. |
| **Nothing is lost** | Results are new files next to the original ("Report (smaller).pdf"); in-place edits are undoable (⌘Z) and versioned; the first save asks "Save a copy" or "Replace". Destructive words ("delete", "remove", "black out") always come with the count and an undo. |
| **Say what happened** | A result banner with the numbers: "Done. The file is 72% smaller (6.1 MB → 1.7 MB)." with Show in Finder · Share · Undo. |
| **Big targets** | Tiles are 150×116 pt, primary buttons 36 pt tall and full width, thumbnails at least 100 pt, drop zones the whole window. |
| **Drag is a verb too** | Rearranging, combining, extracting, inserting and placing all work by drag, and the drop target lights up and says what will happen ("Add 3 pages here"). |
| **Preview's words where Preview has them** | "Thumbnails", "Table of Contents", "Highlights and Notes", "Bookmarks", "Rotate Left", "Crop", "Markup", "Show Inspector", "Enter Password…", "Export As…", "Import from iPhone". |
| **Apple's tone, warmly** | Friendly and encouraging ("we’ll take it from there", "All set"), sentence case, curly quotes around file names, a real ellipsis on anything that opens a dialog, no exclamation marks, no "Oops". |

### 1.2 How many clicks

| Task | Clicks after opening the file |
|---|---|
| Any tool | 2: **Tools** → tile (the panel opens with sensible defaults) + 1 to confirm. Favourites pinned to the toolbar are 1 click. |
| Rotate a page, delete a page | 0 clicks: select the thumbnail, press ⌘R / ⌫ (Preview's keys), or right-click → Rotate Right. |
| Rearrange pages | drag |
| Combine files | drop the files on the welcome window or the Dock icon (the workspace opens, a card per file), or on the sidebar |
| Extract pages | drag thumbnails to the Desktop |
| Convert any file to PDF | drop it on the Dock icon or the window: it converts and opens |
| Sign | Markup → Sign (Preview's flow), or Tools → Sign |

## 2. Window anatomy

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  [▤ View ▾] ┆ [−][1][+]      Report.pdf — Edited        [✎ Markup] [⟲ Rotate]  ◉ Tools  [⇪ Share] [🔍 Search]      │  52 pt unified title/toolbar
├──────────────┬───────────────────────────────────────────────────────────────────┬────────────────┤
│ ┌──────────┐ │                                                                   │ ‹ Make smaller  ✕ │
│ │ ░░░░░░░░ │ │                         ┌───────────────────────┐                 │ Shrinks the file   │
│ │ ░░░░░░░░ │ │                         │                       │                 │ so it's easier to  │
│ │ ░░░░░░░░ │ │                         │                       │                 │ send. The pages    │
│ └──────────┘ │                         │       page 3 of 12    │                 │ stay the same.     │
│      1       │                         │                       │                 │                    │
│ ┌──────────┐ │                         │                       │                 │  ◯ Email   1.7 MB  │
│ │ ░░░░░░░░ │ │                         │                       │                 │  ◉ Good    2.8 MB  │
│ │ ░░░░░░░░ │ │                         │                       │                 │  ◯ Best    5.1 MB  │
│ └──────────┘ │                         └───────────────────────┘                 │                    │
│      2       │                                                                   │  Now: 6.1 MB       │
│ ┌──────────┐ │                         ┌───────────────────────┐                 │                    │
│ │ ▓▓▓▓▓▓▓▓ │ │                         │                       │                 │  More options  ▸   │
│ │ ▓▓▓▓▓▓▓▓ │ │                         │                       │                 │ ┌────────────────┐ │
│ └──────────┘ │                         │                       │                 │ │  Make smaller  │ │
│      3       │                                                                   │ └────────────────┘ │
│              │                                                                   │      Cancel        │
├──────────────┤                                                                   │                    │
│ 12 pages  [+]│                                                                   │                    │
└──────────────┴───────────────────────────────────────────────────────────────────┴────────────────┘
   197 pt sidebar              document (PDFView, grey well, page shadows)             320 pt tool panel
```

### 2.1 Metrics

| Element | Value | Source / reason |
|---|---|---|
| Default window | 1100 × 760 pt, min 640 × 440 | Preview's nib frame is 1024 × 461 with a 213 × 135 minimum; we need room for the panel. |
| Title/toolbar | Unified, 52 pt; traffic lights at (20, 18) | macOS 26 standard unified toolbar. |
| Toolbar items (default set, left → right) | Sidebar/View popup (`sidebar.leading`) · tracking separator · Zoom segmented (−, 1, +; Preview's `zoom_and_actual`) · flexible · **Markup** (`pencil.tip.crop.circle`) · **Rotate** (`rotate.left`) · **Form Filling** (shows only when the document has fields, `rectangle.and.pencil.and.ellipsis`) · flexible · **Tools** · **Share** (`square.and.arrow.up`) · **Search** field (180 pt, placeholder "Search") | Preview's `CommonToolbar.proplist` default set, with Tools added and Inspector moved to the Tools sheet and the View menu. Customisable (View › Customize Toolbar…): every tool is available as a toolbar item, so favourites become one click. |
| Tools button | Bordered-prominent (accent-filled) capsule, 28 pt tall, 16 pt side padding, label "Tools" with `square.grid.2x2` 13 pt symbol on the left; ⌘T; the only coloured control in a document window's toolbar (the workspace's Finish is the other, in its own toolbar) | The one new thing must be findable in a second. |
| Title | Document name centred, 13 pt semibold; "— Edited" suffix in secondary colour; proxy icon draggable | NSWindow standard. |
| Sidebar | Default 197 pt (Preview's saved `PVPDFLastSidebarWidth`), min 140, max 360; thin divider | Preview. |
| Sidebar thumbnails | Width = sidebar − 32 pt, aspect of the page, 8 pt radius, 1 pt border (`separatorColor`), 4 pt shadow; page number 11 pt below, centred; selected: 2 pt accent ring + accent 15% fill behind; 12 pt vertical gap | Preview's `PVFIIconView` scales to the sidebar width; page labels 11 pt. |
| Sidebar modes | Thumbnails ⌥⌘2 · Table of Contents ⌥⌘3 · Highlights and Notes ⌥⌘4 · Bookmarks ⌥⌘5 · Attachments ⌥⌘6 (Preview’s Contact Sheet becomes our workspace, ⌥⌘6 → ⌥⌘7 keeps Contact Sheet) · Search results (appears while searching) · Signatures (appears when the file has signatures) | Preview's View menu, extended. |
| Sidebar bottom bar | 29 pt: "12 pages" 11 pt secondary left; `plus` button right → "Add pages" menu (From file…, Blank page, From scanner…, From iPhone…) | Preview's `SidebarPaneBottomView` is 29 pt. |
| Document well | `underPageBackgroundColor`; page shadows on; page-break margins 4/4/4.75/4.75; continuous scroll default; book mode for two pages; scale 0.1–20 | Preview's `PDFContentView.nib` defaults. |
| Tool panel | 320 pt wide (Preview's Inspector width), inline (pushes the document, never floats), min document width 360 pt → below 1000 pt window width the panel overlays as a sheet-like card; header 52 pt; content inset 20 pt; footer 76 pt | Inspector precedent; no floating palettes. |
| Markup bar | 31 pt sub-toolbar under the toolbar, as Preview (`PVEditBanner` 1024 × 31) | Preview. |
| Result banner | 44 pt, under the toolbar, full width, `controlBackgroundColor` washed with 13 % of `success` from the left (fading out by 46 % of the width), 1 pt bottom separator; a 22 pt `success` check with a 4 pt halo + 13 pt text + buttons right; auto-hides after 8 s, or stays while the pointer is inside | Preview uses 28–31 pt banners for "A newer version of this document is available"; ours needs buttons. |
| Workspace (§6.2) | Canvas `canvas`; file cards 184 × 242 pt (page area 160 × 168, 12 pt in), 16 pt radius, 36 pt apart across and 28 pt down, 28 pt from the top, centred; page cards 148 × 214 pt (page area 128 × 150, 10 pt in), 14 pt radius, 32 / 24 pt apart; pills 22 pt (12 pt semibold; 20 pt and 11 pt on page cards); checkbox 20 pt round at (10, 10); hover toolbar 26 pt buttons ×4 at the top right; "+" 24 pt round accent between neighbours; list rows 64 pt, at most 820 pt wide; status line 36 pt; pinch or ⌘+ / ⌘− scale cards 0.7–1.6 | Smallpdf-style cards, big enough to read a page at a glance; gaps sized for the "+". |
| Tools sheet | 880 × 620 pt (clamped to window − 80 pt each way; min 640 × 480); corner 16 pt; search field 32 pt tall; section chips 28 pt tall, 6 pt apart, 12 pt under the search field; tiles 150 × 116 pt in a 5-column grid with 16 pt gaps and 24 pt margins; section header 13 pt semibold after its 20 pt icon square | Fits five tiles; readable at arm's length. |
| Tile | 150 × 116 pt, 12 pt radius, `controlBackgroundColor` with 1 pt `separatorColor` border; 36 pt rounded square (10 pt radius) in the section's colour, 24 % lighter at the top, with an 18 pt semibold white symbol; name 13 pt semibold; hint 11 pt secondary, 2 lines, truncated; hover: 1.5 pt border and a soft shadow in the section's colour, lift 2 pt, grow to 1.03 on the hover spring; keyboard focus: 2 pt accent ring | |
| Primary button | Full panel width, 36 pt tall, 10 pt radius, accent fill with a faint light along the top and a soft accent shadow, 13 pt semibold white; gives to 0.97 on a spring when pressed; disabled at 40% | Bigger than AppKit's 22 pt default on purpose. |
| Welcome window | 760 × 520 pt, non-resizable, centred; four 160 × 140 pt targets with 40 pt icon squares; recents list below; the drop tip 18 pt above the bottom | |

### 2.2 Typography

System font (SF Pro) only, matching Preview, which uses `.AppleSystemUIFont` at 11/12/13 pt. Sizes used:

| Role | Size / weight |
|---|---|
| Body, controls, menus, thumbnails labels in lists | 13 regular |
| Secondary, hints, metadata, page numbers under thumbnails | 11 regular, `secondaryLabelColor` |
| Panel and sheet section titles | 15 semibold |
| Tools sheet title ("What do you want to do?") | 20 semibold |
| Welcome title | 28 bold; subtitle 15 regular secondary |
| Tile name | 13 semibold; hint 11 |
| Result banner | 13 regular, numbers in semibold |
| Monospace never appears in the UI. | |

### 2.3 Colour

Chrome and text use semantic system colours, so light and dark mode, the accent colour choice and Increase Contrast
work for free. On top of them sits a small, fixed **brand palette**: one colour per Tools section, the app's indigo, a
success green, the workspace's canvas and cards, and eight pastel file pills, each with its own dark value.

| Token | Light | Dark | Use |
|---|---|---|---|
| `windowBackgroundColor` | #ECECEC | #323232 | window chrome |
| sidebar (vibrant `sidebar` material) | ≈ #F2F2F2 | ≈ #2A2A2A | sidebar, Tools sheet background |
| `underPageBackgroundColor` | #E6E6E6 | #1E1E1E | document well |
| `controlBackgroundColor` | #FFFFFF | #1E1E1E / 2A2A2A | tiles, panel cards, banner |
| `separatorColor` | #000 10% | #FFF 10% | borders, dividers |
| `labelColor` / `secondaryLabelColor` / `tertiaryLabelColor` | #000 85% / 50% / 25% | #FFF 85% / 55% / 25% | text |
| `controlAccentColor` (default blue) | #007AFF | #0A84FF | Tools button, primary buttons, Finish, selection rings, checkboxes, the "+" between cards, drop highlights, insertion line |
| `systemRed` | #FF3B30 | #FF453A | Black out marks, destructive confirm buttons only |
| Highlight colours | Preview's: Yellow #FACD5A, Green #7CC868, Blue #69B0F1, Pink #FB5C89, Purple #C885DA (dark: #5E4613, #294714, #1F3466, #5E2D42, #422D61); notes fill #FFEB6B etc. | | markup, identical to Preview so files look the same in both apps |

**Brand palette** (`SPColor`, mirrored in `../mockups/src/shared.css`):

| Token | Light | Dark | Use |
|---|---|---|---|
| `categoryBlue` — Pages | #2F80ED | #4C8DF6 | the section's icons, chip, header and panel wash; Combine on the welcome window |
| `categoryGreen` — Convert | #1FAF68 | #2DC27A | 〃; Convert a file on the welcome window |
| `categoryOrange` — Edit | #FF8A1F | #FF9A3C | 〃 |
| `categoryYellow` — Mark up | #F5B000 | #FFC21A | 〃 |
| `categoryPurple` — Sign & fill | #8B5CF6 | #9D74FF | 〃 |
| `categoryRed` — Protect | #EF4444 | #F65A5A | 〃; the delete buttons of the workspace's hover toolbar and preview |
| `categoryTeal` — Fix & check | #0EB2C2 | #22C3D2 | 〃 |
| `categoryPink` — Scan | #EC4899 | #F45FAA | 〃; Scan on the welcome window |
| `brand` | #5B5BF6 | #7272FF | the app's mark (blue → indigo → violet → pink), Open a PDF, the welcome tip |
| `success` | #22B35E | #30C46C | the result banner's check and wash |
| `canvas` | #EDF3FE | #171B23 | the workspace's background |
| `card` | #FFFFFF | #252B36 | the workspace's cards |

**File pills** (fill / ink; the ink is also the file's strong colour). Files take them in turn; a document's own pages
take the first. Ink on fill is at least 4.5 : 1 in both appearances (self-test).

| Pill | Light fill / ink | Dark fill / ink |
|---|---|---|
| sky | #DCEBFF / #1F5FBF | #1E3A66 / #A9CBFF |
| pink | #FFDDEB / #B4245F | #5A2440 / #FFB3D2 |
| mint | #D3F5E3 / #127346 | #1C4A35 / #A6EBC7 |
| peach | #FFE4CF / #A8500F | #5A3519 / #FFC9A1 |
| lavender | #E9E0FF / #5B3CC4 | #3A2D66 / #CDBDFF |
| lemon | #FFF2B8 / #7D5E00 | #4D4214 / #FFE58A |
| aqua | #CFF4F6 / #0B6E78 | #164A50 / #9FE8EE |
| coral | #FFE0DC / #B3322A | #5A2622 / #FFB8AF |

Redaction marks: 1.5 pt `systemRed` outline with 10% fill before applying; solid black (or the chosen colour) after.

### 2.4 Iconography

SF Symbols throughout. A tool's symbol sits white on a rounded square filled with its section's colour (`SPIcon`:
24 % lighter at the top, a hairline edge, a soft shadow of the colour), at 36 pt in tiles, 40 pt on the welcome
window, 24 pt in panel headers, 20 pt before section headers and 18 pt in the section chips. Sections have their own
symbols: Pages `doc.on.doc.fill`, Convert `arrow.triangle.2.circlepath`, Edit `pencil`, Mark up `highlighter`, Sign &
fill `signature`, Protect `lock.fill`, Fix & check `wrench.and.screwdriver.fill`, Scan `viewfinder`. The symbols are the
same ones Preview and the menus use: `sidebar.leading`, `pencil.tip.crop.circle` (Markup),
`rotate.left`, `crop`, `highlighter`, `book`, `list.bullet.indent`, `square.grid.2x2` (Tools), `square.and.arrow.up`,
`doc.on.doc` (Combine), `arrow.down.right.and.arrow.up.left` (Make smaller), `text.viewfinder` (Recognise text),
`text.redaction` (Black out), `lock` / `lock.open`, `signature`, `person.2.badge.key` (Request signatures),
`doc.text.magnifyingglass` (Compare), `checkmark.seal` (Check), `camera` / `scanner`,
`textformat` (Edit text), `number` (Number pages), `drop` (Watermark), `doc.richtext` (Word), `tablecells` (Excel),
`rectangle.on.rectangle` (PowerPoint), `photo` (Images), `archivebox` (PDF/A), `speaker.wave.2` (Read aloud).

### 2.5 Motion

| Event | Animation |
|---|---|
| Tools sheet | System sheet slide (≈ 250 ms); tiles fade-up in 3 staggered rows of 40 ms; search field focused on open |
| Hover (tiles, welcome targets, workspace cards) | Grow to 1.03 (cards 1.02) on the hover spring (response 0.32, damping 0.58): a little bounce; border and shadow take the section's colour over 150 ms |
| Tool panel open/close | Width 0 → 320 with ease-out 220 ms; the document re-fits width during the animation; content fades in at 120 ms |
| Switching tools | Crossfade content 150 ms; header title slides 8 pt |
| Thumbnail drag | Picked-up thumb scales 1.05 with 8 pt shadow; others shift with a spring (response 0.3, damping 0.8); insertion line fades in 100 ms |
| Workspace drag | The dragged cards leave their places (the others close up) and the cards after the pointer spring aside (response 0.3, damping 0.8) to open a dashed hole where they will land; after a change every card slides to its new place on the same spring, new cards pop in from 0.86, removed ones fade in 150 ms |
| Preview (workspace) | Fades in over the canvas in 180 ms, out in 150 ms |
| Drop target | 2 pt accent ring + 8% accent tint over the target, 120 ms; the label "Add here" appears after 300 ms hover |
| Result banner | Slides down 44 pt under the toolbar, 300 ms ease-out; the check pops in from 0.2 on the pop spring (response 0.42, damping 0.5) and a short burst of confetti in the section colours falls from it for 1.4 s; hides up after 8 s or on click |
| Progress (panel button) | The filled part grows on a spring; a soft band of light sweeps across it every 1.6 s |
| Live preview edits (watermark, numbers, headers) | Re-render debounced 80 ms; no animation, the page just updates |
| Page rotate | 90° rotate of the thumbnail and page 250 ms |
| Reduce Motion on | Crossfades only, no movement: no hover growth, no spring, no confetti, no pop |

## 3. Drag and drop everywhere

| Drag | Onto | Result | Target feedback |
|---|---|---|---|
| Files (PDF, images, Office, anything convertible) | Welcome window | One file opens; several open the workspace with a card per file (§6.2), the ones that aren't PDFs converting on their cards | A dashed card over the window with a bobbing arrow: "Drop to open" / "Drop to combine 3 files" |
| Files | Dock icon | One file opens; several ask "Combine these 3 files?" — Combine… opens the workspace, Open Separately opens each | Dock bounce |
| Files | Document window (page area) | Opens in a new tab/window (PDF) or converts then opens | Window-wide accent ring, label "Open" |
| Files | Sidebar between two thumbnails | Inserts the file's pages at that position (converting first if needed) | Insertion line + "Add 3 pages here" |
| Files | Sidebar end | Appends | Insertion line at end |
| Thumbnails | Within the sidebar | Reorder (multi-select supported) | Insertion line |
| Cards (files or pages) | Within the workspace | Reorder (multi-select supported) | The cards spring aside to open a dashed hole |
| Files | Anywhere in the workspace | Each file's pages go into the gap under the pointer, as its own card while it converts | The hole opens, with "Add 3 pages here" |
| Thumbnails | Another document's sidebar | Copies pages there (⌥ moves) | Insertion line in that window |
| Thumbnails or workspace cards | Finder / Desktop / Mail | A new PDF "Report – pages 3-5.pdf" (file promise) | Standard drag image: stacked pages (or cards) with a count badge |
| Image file | A page (in Edit or Markup mode) | Edit mode: placed as a page object; Markup: placed as an image stamp | Cursor badge shows "+" and a label "Place image" |
| Text | A page | New text box | Label "Add text" |
| Files | Tools sheet tile (e.g. "Combine files", "Images → PDF", "To Word") | Runs that tool on the dropped files | Tile highlights |
| PDF | A tool panel's drop zone (Compare, Insert pages, Watermark from file) | Fills that input | Zone highlights |

Rules: the drop target always says what will happen in two or three words; a drop that cannot work shows the "not
allowed" cursor and the reason in a tooltip ("Can't add a folder. Drop the files inside it."); a drop onto an
encrypted document asks for the password first; dropping never overwrites a file.

## 4. The Tools sheet

Mockup: `tools-sheet.png` (and `-dark`).

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│  (soft wash of blue and pink behind the title)                                        ✕   │
│   What do you want to do?                                                                 │
│   ┌──────────────────────────────────────────────────────────────────────────────────┐    │
│   │ 🔍  Search tools — try "smaller", "sign", "Word", "black out"                      │    │
│   └──────────────────────────────────────────────────────────────────────────────────┘    │
│   (■ Pages) (■ Convert) (■ Edit) (■ Mark up) (■ Sign & fill) (■ Protect) (■ Fix & check) (■ Scan)
│                                                                                           │
│   Recently used                                                                           │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐                        │
│   │ ■ Make   │ │ ■ Sign   │ │ ■ Combine│ │ ■ To Word│ │ ■ Black  │                        │
│   │  smaller │ │          │ │  files   │ │          │ │  out     │                        │
│   └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘                        │
│                                                                                           │
│   ■ Pages                                                                                 │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐                        │
│   │ ■ Combine│ │ ■ Rear-  │ │ ■ Split  │ │ ■ Extract│ │ ■ Rotate │                        │
│   │  files   │ │  range   │ │          │ │  pages   │ │  pages   │                        │
│   │ Put files│ │ Drag pa- │ │ Make se- │ │ Save some│ │ Turn     │                        │
│   │ together │ │ ges in   │ │ veral    │ │ pages as │ │ pages    │                        │
│   └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘                        │
│   … (scrolls: Convert, Edit, Mark up, Sign & fill, Protect, Fix & check, Scan)            │
└───────────────────────────────────────────────────────────────────────────────────────────┘
   ■ = the section's colour, a rounded square with a white symbol (§2.4)
```

- **Section chips** under the search field: each section's icon and name in a white capsule; a click (or ⌘1–8) jumps
  to the section; hover tints the chip with its colour. They show the whole palette at once, so the sheet reads as a
  colourful map of everything the app does.
- **Section headers** carry the same 20 pt icon square before the name; Recently used has none.
- Opens with **Tools** (toolbar), **⌘T**, the Tools menu item "All Tools…", or the Dock menu. Esc closes. It is a window
  sheet, so the document stays visible behind it.
- The search field has focus on open. Typing filters tiles live across all sections and matches names, hints and the
  jargon synonyms (`features.md` naming rule): "compress", "optimize", "reduce", "shrink" all show "Make smaller";
  "ocr" shows "Recognise text"; "redact" shows "Black out"; "merge" shows "Combine files"; "docx" shows "To Word" and
  "Word → PDF". Return runs the first result. No results: "Nothing called "%@". Try "smaller", "sign" or "Word"."
- **Recently used** shows up to five tiles by frecency; empty on first launch, in which case the row is hidden.
- Sections in order, each with its colour (§2.3): **Pages**, **Convert**, **Edit**, **Mark up**, **Sign & fill**,
  **Protect**, **Fix & check**, **Scan**. Order is the order of a document's life: get the pages right, convert, change,
  mark, sign, protect, check.
- Tiles that need something the Mac does not have yet are still shown, with a small grey badge: "Needs iPhone nearby"
  (Continuity scan), "Install converter" (LibreOffice for `.ods`). Clicking explains in the panel; nothing is hidden,
  nothing is greyed out without a reason.
- Right-click a tile → "Add to Toolbar" (one-click favourites) and "Add to Dock Menu".
- Keyboard: arrows move between tiles, Return opens, ⌘1–8 jump to sections.
- The same tiles appear in the **Tools** menu as submenus (Tools › Pages › Rotate Pages…), for people who live in menus,
  and the same actions are in the thumbnail context menu when they apply to pages.

### 4.1 Tile catalogue (names, hints, synonyms)

| Section | Tile name | Hint (second line) | Search synonyms | `features.md` # |
|---|---|---|---|---|
| Pages | Combine files | Put several files into one PDF | merge, join, append, concatenate | 18 |
| Pages | Rearrange pages | Drag pages into a new order | organise, organize, reorder, move, sort | 19 |
| Pages | Split | Cut this PDF into several files | separate, divide, chapters | 23 |
| Pages | Extract pages | Save some pages as their own PDF | pull out, save pages, range | 22 |
| Pages | Rotate pages | Turn pages the right way up | sideways, upside down, landscape | 20 |
| Pages | Delete pages | Remove pages you don't need | remove | 21 |
| Pages | Crop | Trim the edges of pages | margins, cut, trim, page boxes | 28 |
| Pages | Insert pages | Add a blank page or pages from another file | add page, blank, scanner | 24, 25, 27 |
| Pages | Number pages | Add page numbers | pagination, folio, page labels | 30, 31 |
| Pages | Booklet | Lay pages out for printing and folding | imposition, n-up, 2-up, contact sheet | 32, 33 |
| Pages | Resize pages | Change the paper size | A4, letter, scale, page boxes | 29 |
| Convert | To Word | Make a Word document you can edit | docx, doc, export, rtf | 50 |
| Convert | To Excel | Pull tables into a spreadsheet | xlsx, csv, table, numbers | 51 |
| Convert | To PowerPoint | Make slides from the pages | pptx, keynote, presentation | 52 |
| Convert | To images | Save pages as JPG or PNG | jpeg, png, tiff, picture, export images | 53 |
| Convert | To text or web page | Plain text, HTML or an EPUB book | txt, html, epub, ebook, reflow | 54, 55 |
| Convert | For archiving (PDF/A) | Save a copy that will open the same way in decades | pdfa, archive, iso 19005, standards, pdf/x | 56, 57 |
| Convert | Images → PDF | Turn photos and scans into a PDF | jpg to pdf, png, heic, picture | 34 |
| Convert | Any file → PDF | Word, Excel, PowerPoint, Pages, web pages, text, EPUB, ZIP… | docx to pdf, convert, create pdf, html, csv, hwp, odt | 35–49 |
| Edit | Edit text & images | Change words and pictures on the page | edit pdf, typo, replace image | 60, 61, 62, 72 |
| Edit | Headers & footers | Put a title, date or numbers at the top or bottom | running head | 64 |
| Edit | Watermark | Stamp "Draft" or a logo across every page | confidential, background, logo | 66, 67 |
| Edit | Bates numbering | Number pages across many files for legal filing | legal, exhibit, stamp numbers | 65 |
| Edit | Stamps | Add "Approved", "Received", a date or your own stamp | approved, draft, dynamic stamp | 68 |
| Edit | Links | Make text or areas clickable | hyperlink, url, go to page | 63 |
| Edit | Contents | Add a clickable table of contents | bookmarks, outline, chapters, navigation | 6 |
| Edit | Do this to many files | Run tools on a whole folder at once | batch, action wizard, routine, automate | 75 |
| Mark up | Highlight & notes | Highlight, underline, add a note | comment, annotate, sticky | 76 |
| Mark up | Draw & shapes | Pen, arrows, boxes, callouts | sketch, ink, annotate, cloud | 76 |
| Mark up | Comments list | See and answer every comment | review, replies, resolve, summary | 77 |
| Mark up | Attach a file | Clip a file or a voice note to a page | attachment, audio | 79 |
| Mark up | Measure | Measure distances and areas on plans | ruler, scale, area, distance | 15 |
| Sign & fill | Sign | Put your signature on the page, or sign with a certificate | signature, initials, e-sign, digital id | 82 |
| Sign & fill | Fill a form | Type into the boxes and tick the ticks | form filler, autofill | 80 |
| Sign & fill | Make a form | Turn this PDF into a form people can fill in | prepare form, fields, fillable | 81 |
| Sign & fill | Request signatures | Send this to people to sign, and track who's done | e-signature, send for signature, docusign, agreement | 84 |
| Sign & fill | Certificates & signatures | See who signed, trust people, manage your signing certificate | verify, digital id, trust | 83, 85 |
| Protect | Add a password | Lock the file so only people with the password can open it | encrypt, protect, permissions, restrict | 86 |
| Protect | Remove password | Save a copy that opens without a password | unlock, decrypt, remove security | 87 |
| Protect | Black out | Permanently hide names, numbers or anything private | redact, censor, sanitize | 69 |
| Protect | Lock in notes & fields | Make notes and form entries part of the page | flatten, burn in | 70 |
| Protect | Remove hidden info | Strip metadata, comments and hidden things before sharing | sanitize, metadata, clean | 88 |
| Fix & check | Make smaller | Shrink the file so it's easier to send | compress, optimize, reduce file size, shrink, email | 91 |
| Fix & check | Recognise text | Make a scan searchable and copyable | ocr, searchable, scan to text | 92 |
| Fix & check | Compare files | See what changed between two versions | diff, differences, versions | 13 |
| Fix & check | Check accessibility | Make the PDF work with screen readers | tags, alt text, reading order, pdf/ua, 508 | 97 |
| Fix & check | Read aloud | Hear the document read to you | speak, voice, listen, audio | 3 |
| Fix & check | Check for printing | Find problems before sending to a printer | preflight, print production, separations, cmyk, bleed | 94, 95, 96 |
| Fix & check | Repair | Fix a file that won't open properly | damaged, corrupt, recover, fonts, fast web view | 98, 99, 100 |
| Scan | Scan with iPhone | Use your iPhone's camera as a scanner | continuity camera, phone, document camera | 101 |
| Scan | Scan with a scanner | Use a flatbed or sheet-fed scanner | image capture, twain, flatbed | 102 |
| Scan | From a photo | Straighten and clean up a photo of a page | perspective, deskew, picture | 103, 104 |

52 tiles; the remaining features in `features.md` are reached from inside these panels, the sidebar modes or the menus.

## 5. Tool panels

### 5.1 Anatomy (every panel)

```
┌──────────────────────────────────┐
│ ‹   ■ Watermark              ✕   │  52 pt header: back (to Tools sheet), section icon square, 15 pt title, close
│ Stamp "Draft" or a logo across   │  11 pt hint, secondary
│ every page.                      │
├──────────────────────────────────┤
│                                  │
│  (Text) (Picture)                │  segmented control when the tool has two kinds of input
│                                  │
│  ┌────────────────────────────┐  │
│  │ DRAFT                      │  │  text field, 13 pt, 28 pt tall
│  └────────────────────────────┘  │
│                                  │
│  Lightness   ○─────────●──── 30% │  labelled sliders: label left 13 pt, value right 11 pt secondary
│  Angle       [Diagonal ▾]        │  popups for choices
│  Pages       [All pages ▾]       │
│                                  │
│  ▸ More options                  │  disclosure, closed by default; opens the Acrobat-level controls
│                                  │
│                                  │  (space; the preview is the document itself, live)
├──────────────────────────────────┤
│ ┌──────────────────────────────┐ │  76 pt footer
│ │       Add watermark          │ │  primary button 36 pt
│ └──────────────────────────────┘ │
│            Cancel                │  text button 11 pt
└──────────────────────────────────┘
```

- **Header**: back arrow returns to the Tools sheet with the search text preserved; ✕ closes the panel (Esc too). A
  soft wash of the section's colour (12 % fading to nothing over 64 pt) sits behind the header, so every panel wears
  its section's colour.
- **Scope line** (when the tool works on pages): "Pages: All · This page · 3–5 · Selected (4)" as a popup directly
  under the hint. Selecting thumbnails in the sidebar while a panel is open switches the scope to "Selected".
- **Controls**: at most three visible; sliders have a live value; popups have at most seven items; checkboxes have
  the thing they do as label ("Also remove hidden information").
- **Live preview**: the document shows the effect while the panel is open (overlay drawn through
  `PDFPageOverlayViewProvider`, not committed). For file-level tools without a visual effect (Make smaller, Convert)
  the panel shows a "before → after" summary instead (size, pages, engine used).
- **More options**: Acrobat's full control set behind one disclosure, so the panel is never longer than the window by
  default. It remembers its open/closed state per tool.
- **Footer**: one primary button with a verb. For tools that write a new file the button says "Save as …" / "Make
  smaller" and the output location line sits above it: "Saves "Report (smaller).pdf" next to the original · Change…".
  Secondary action is a text button (Cancel, or "Remove existing watermark" in red when relevant).
- **Progress**: the button becomes a progress bar with "Page 14 of 120 · Stop"; the fill grows on a spring and a soft
  light sweeps across it so a long job looks alive; the panel stays open; the sidebar thumbnails tick as pages complete.
- **Result**: the panel closes and the result banner appears (§7.3). For new files the new document opens in a new
  tab (⌘-click the banner to reveal in Finder).
- **Errors** appear inside the panel above the footer as a 13 pt message with an icon and one action (§7.4).

### 5.2 Panel archetypes

| Archetype | Used by | Shape |
|---|---|---|
| **A. One-choice** | Rotate, Delete, Extract, Lock in notes, Remove password, Repair, Fast web view, Read aloud | Scope + one control (or none) + button. Many of these are better reached from the thumbnail context menu; the panel exists so the tile works. |
| **B. Preset + more** | Make smaller, For archiving, To images, Split, Booklet, Resize | Three radio presets with a consequence line each ("Email · 1.7 MB"), More options for the full set. |
| **C. Live-preview editor** | Watermark, Headers & footers, Number pages, Bates, Background, Crop, Stamps, Links | Controls on the left panel, effect drawn on the page immediately, drag handles on the page where position matters. |
| **D. Mode** | Edit text & images, Draw & shapes, Highlight & notes, Fill a form, Make a form, Measure, Black out (marking), Sign (placing), Rearrange (the workspace), Compare | The panel is a thin palette (tool buttons + properties) and the document becomes interactive; the footer button is "Done". |
| **E. Convert** | To Word/Excel/PowerPoint/text, Any file → PDF, Images → PDF, Combine | Input list (drop zone when the tool accepts files), output format/location, one line that names the engine, button "Save as Word…" (opens a save panel defaulting next to the original). |
| **G. Flow** | Request signatures, Scan, Certificates | Up to three numbered steps in the same panel (a segmented "1 Who · 2 Where · 3 Send" at the top), back/next in the footer. |

### 5.3 Panel specifications

Each entry: controls in order (defaults in bold), More options, primary button, output rule, preview, and copy.

**Make smaller** (B) — radio: **Good (recommended)**, Email (smallest), Best quality; each with the estimated size
computed on a 5-page sample within 1 s ("≈ 1.7 MB"); line "Now: 6.1 MB". More options: image quality slider, picture
sharpness dpi (72/150/300), "Remove comments and form entries", "Remove bookmarks and attachments", "Remove extra
fonts", "Make pages load fast on the web". Button **Make smaller**. Output: "Report (smaller).pdf" next to the original.
Result: "Done. 72% smaller (6.1 MB → 1.7 MB)." If no gain: panel message "This file is already as small as it gets."
with the button disabled.

**Recognise text** (B) — summary line "14 of 20 pages have no text yet"; language popup **Automatic**; checkbox "Clean
up the scan first (straighten, whiten)" **on**; More options: "Make text editable (replaces the picture with real
text)", dpi. Button **Recognise text**. Output: in place (undoable) — it adds an invisible layer; "Save a copy" rule
applies at save. Progress per page. Result: "Recognised 14 pages. You can now search and copy the text."

**Black out** (D) — top segmented: **Mark by hand** · Find and mark; hand mode: drag boxes or select text; find mode:
text field + chips (Phone numbers, Emails, Card numbers, Dates, Names from the address book, Custom pattern…) with a
live count "12 found on 5 pages" and a results list with a checkbox each; option "Also remove hidden information
(metadata, comments)" **on**; "Write REDACTED over the boxes" off. Footer: **Black out 12 items**, in red, then a
confirm sheet "This can't be undone in the new file. Your original stays as it is." with Black out / Cancel. Output:
always a new file "Report (blacked out).pdf". Preview: red outlines → black boxes after.

**Watermark** (C) — segmented **Text** · Picture; text field (default "DRAFT"); Lightness slider **30%**; Angle popup
**Diagonal** (Straight, Diagonal, Custom…); Pages popup **All pages**; More options: font, size, colour, behind/over
content, position grid 3×3, scale, "only when printing", "only on screen". Button **Add watermark**; secondary (red
text) "Remove watermark" when one of ours exists. Output: in place, undoable. Preview live with a drag handle.

**Headers & footers** (C) — a 2×3 grid of small fields (left/centre/right × top/bottom) with a "+" menu per field (Page
number, Page count, Date, Title, File name, Bates number…); Font popup; Size; Pages; More options: margins, shrink
page to make room, replace existing, date format, start number. Button **Add to pages**. In place.

**Number pages** (C) — Position: 3×2 picker of dots; Style popup **"1"** ("Page 1", "Page 1 of 12", "– 1 –", "i, ii",
"A-1"); Start at **1**; Pages (with "Skip first" stepper). Button **Add numbers**. Also "Page labels" link under More
options (what the sidebar shows).

**Combine files** (E) — the queue (list with icon, the name in its file pill, "Pages: all ▾", ✕); "Add files…" button
and a drop zone; option "Add a contents entry for each file" **on**; File size popup **Normal**. Button **Combine 3
files**. Output: new unsaved document "Combined.pdf" (Save asks where). The workspace (§6.2) is the bigger way to do
the same: dropping several files on the app or the welcome window opens it.

**Split** (B) — radio: **Every N pages** (stepper 1), By size (MB stepper), By contents entries, Blank pages between
documents, Ranges (text field "1-3, 4-9"); output folder line; naming "Report – part 1.pdf". Button **Split into 4
files**. Result banner "Saved 4 files in "Report parts"" with Show in Finder.

**Extract pages** (A) — scope (defaults to the selected thumbnails); checkbox "Remove them from this document" off;
"Each page as its own file" off. Button **Save pages as PDF…**.

**Rotate pages / Delete pages** (A) — scope; Rotate: two big buttons ⟲ ⟳ (and "All sideways pages"); Delete: button
**Delete 3 pages** (never the last page: "A PDF needs at least one page."). In place, undoable.

**Crop** (C) — crop handles on the page; Apply to: **This page** · All pages · Range; "Remove white margins" button;
More options: exact numbers, units, which box. Button **Crop**. Notice under the hint (Preview's): "Cropping hides
content without removing it. Use Black out to remove it."

**Insert pages** (A) — segmented **From file** · Blank page · From scanner · From iPhone; position: "After page [3]".
Button **Insert**.

**Booklet** (B) — radio **Booklet (fold in half)**, 2 per sheet, 4 per sheet, Contact sheet; paper size; Button **Make
booklet PDF**. New file.

**To Word / To Excel / To PowerPoint / To text or web page** (E) — format segmented where relevant (Word: **.docx** ·
.rtf; Excel: **.xlsx** · .csv; text: **Text** · HTML · EPUB); for scanned pages a line "3 pages are pictures — text
will be recognised first"; Layout: **Keep the look** · Flowing text (Word); "One sheet per table" (Excel); "Editable
text over page pictures" (PowerPoint). Button **Save as Word…** (save panel, same folder). Result opens the file in
its app? No: banner "Saved "Report.docx"" with **Open in Word** / Show in Finder.

**To images** (B) — format **PNG** · JPEG · TIFF; Quality radio **Good (150 dpi)** · Print (300) · Screen (72); pages
scope; "Export the pictures inside instead" link. Button **Save images…** (folder). Banner "Saved 12 images".

**For archiving (PDF/A)** (B) — radio **PDF/A-2b (recommended)** · PDF/A-1b (oldest readers) · PDF/A-3b (keeps
attachments); line "We'll check the result and tell you if anything couldn't be converted." Button **Save archive
copy**. Result banner "Saved "Report (archive).pdf". It passes the PDF/A-2b check." or "… 2 things couldn't be fixed
· Show".

**Images → PDF / Any file → PDF** (E) — drop zone + list; paper **Fit each picture** · A4 · Letter; margins; order by
drag; engine line "Converted by: the built-in converter" (or "LibreOffice" / "Pages will open to export this file").
Button **Make PDF**. New document.

**Edit text & images** (D) — palette: Select, Text, Image, Add text box, Add image, Find & replace; properties strip
(font, size, bold/italic, colour, alignment) appears when text is selected; status line "Fonts not on this Mac are
substituted" when relevant. Button **Done**. In place, undoable per edit.

**Highlight & notes / Draw & shapes** (D) — opens Preview's Markup bar (same tools, same order, same icons) and a
palette of colours; the panel lists the tools with their shortcuts so people can learn them; Done closes.

**Comments list** — switches the sidebar to Highlights and Notes with filter chips (All, Mine, Unresolved); each row
has Reply and Resolve; toolbar in the sidebar: Sort (Page, Date, Author), "Summarise comments to PDF…", Import/Export.

**Sign** (D) — segmented **My signature** · With a certificate. My signature: the saved signatures as big buttons
(Preview's library, shared Keychain item), "Create signature…" (Trackpad · Camera · iPhone, Preview's three), then
click on the page to place; handles to resize; "Initials" toggle. Certificate: popup of certificates (+ "Create my
certificate…"), reason/location fields, checkbox "Lock the document after signing"; appearance preview; Button **Sign
and save…** (always a new file: "Contract (signed).pdf").

**Fill a form** (D) — the form fields highlight in light blue; panel: "AutoFill from my card" button, field list with
checkmarks, "Clear form"; "This page has no fields — Fill anywhere" switches to text-box placement. Button **Done**.

**Make a form** (D) — "Find fields for me" button (auto-detect) with the count; palette: Text box, Tick box, Choice,
Date, Signature, Number, Multiple-line text, Picture; properties for the selected field (Name, Required, Default,
Format popup, "Calculate from…" sum/average/product of chosen fields); "Set tab order" toggle shows numbers. Button
**Done**. In place.

**Request signatures** (G) — Step 1 Who: a list of signers (name/email from Contacts, colour chip each, order
toggle "Sign in this order"); Step 2 Where: click the page to place Signature / Initials / Date / Name / Tick box for
the chosen signer; Step 3 Send: message field, "Send with Mail" / "Send with Messages" / "AirDrop" / "Save signing
package…", line "They can sign in any PDF app and send it back. When the file comes back, open it here and we'll
match it." Afterwards the **Signatures I asked for** list (window: Window › Signature Requests) shows each request with
signers and states Waiting · Returned · Done, buttons Remind (prefilled mail) and Sign in person, and "Seal and finish"
when all have signed.

**Certificates & signatures** (G) — tabs: Signatures in this file (name, date, valid ✓ / changed after signing ⚠, chain,
"Trust this person"), My certificate (Create / Import .p12 / Export public certificate), People I trust.

**Add a password** (A) — password field + verify with a strength bar and the sentence "If you forget this password,
no one can open the file"; "Also need a password to change it" disclosure with the plain-words permission
checkboxes (Allow printing, Allow copying text, Allow filling forms and commenting, Allow page changes). Button
**Save protected copy**. New file "Report (protected).pdf".

**Remove password** (A) — "This file needs a password to open" or "This file limits printing/copying"; password
field. Button **Save copy without password**. New file.

**Lock in notes & fields** (A) — checkboxes **Notes and markup** on, **Form entries** on; "Make pages into pictures
(strongest)" off. Button **Save locked-in copy**.

**Remove hidden info** (A) — checklist with what was found and counts (Metadata · 4 comments · 2 attachments · Hidden
text (OCR layer) · Bookmarks · Links · Scripts); all on except Bookmarks/Links; Button **Save clean copy**.

**Compare files** (D) — "Compare with: [drop or choose a file]" (defaults to an earlier version if one exists);
checkbox "Text only"; view toggles **Side by side** · Overlay; a change list in the panel ("Page 3: 2 sentences
changed"); ‹ › navigate; Button **Save comparison report…**.

**Check accessibility / Check for printing** (B with a results list) — Button **Check** → results grouped Pass / Needs
attention / Failed with "Fix" buttons where automatic ("Set the language to English", "Add a title", "Tag the
document"), "Describe this image" rows open a field for the alt text. Report export.

**Repair** (A) — line with what's wrong when known ("The file's index is damaged"); "Also embed missing fonts". Button
**Repair and save copy**.

**Read aloud** (A) — play/pause, speed, voice; highlights the sentence; Button **Read from this page**.

**Scan with iPhone / scanner / From a photo** (G) — Step 1 pick device (list with status; "No iPhone nearby — make
sure it's unlocked, close by, and signed in to the same Apple Account"); Step 2 scan (device UI or embedded scanner
view: colour/grey/mono, dpi, size, both sides); Step 3 pages come into the sidebar with a "Clean up" toggle on;
"Scan another" / **Done**. Insert position "At the end".

**Measure** (D) — tools Distance · Perimeter · Area; "Set scale: this line is [10] [m]"; results list; Done.

**Do this to many files** (E) — list of steps (Add a tool…) each a tile picker; files/folder drop zone; output folder;
"Save as routine"; Button **Run on 24 files**.

**Links / Contents / Stamps / Bates / Resize / Attach a file / Certificates** follow archetypes C/A/G with the
controls named in `features.md`.

## 6. Other screens

### 6.1 Welcome window

Shown when the app opens with no document (and via Window › Welcome). Non-resizable 760 × 520. Mockup: `welcome.png`
(and `-dark`).

```
┌────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●     (soft pools of blue, indigo and pink along the top)              │
│                                  ┌────┐                                    │
│                                  │ 📄 │  the mark: blue → indigo → violet → pink
│                                  └────┘                                    │
│                              Super PDF                                     │
│      Drop in PDFs, photos or Office files — we’ll take it from there.      │
│                                                                            │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│   │ ■        ⌘O  │  │ ■            │  │ ■            │  │ ■            │   │
│   │ Open a PDF   │  │ Combine files│  │ Scan         │  │ Convert a    │   │
│   │ Or drop one  │  │ Put PDFs,    │  │ With your    │  │ file         │   │
│   │ anywhere in  │  │ photos and   │  │ iPhone or a  │  │ Word, Excel, │   │
│   │ this window  │  │ documents    │  │ scanner      │  │ photos and   │   │
│   │              │  │ together     │  │              │  │ more → PDF   │   │
│   └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘   │
│     indigo            blue (Pages)      pink (Scan)       green (Convert)   │
│   Recent                                                                   │
│   ┌─┐ Lease agreement.pdf           Yesterday, 4:12 PM     12 pages  2.1 MB│
│   ┌─┐ Tax return 2025.pdf           Monday                 44 pages  8.0 MB│
│   ┌─┐ Grandma's recipes.pdf         12 Sep                  6 pages  310 KB│
│        ⤓ Drop one file to open it, or several to put them together.        │
└────────────────────────────────────────────────────────────────────────────┘
```

Targets are 160 × 140, 14 pt radius, a 40 pt icon square (11 pt radius) in the target's colour with a white symbol,
label 15 semibold, hint 11 secondary; hover borders the card in its colour, gives it a coloured shadow and grows it on
the hover spring. Dropping files anywhere: one opens (converted first when it isn't a PDF), several open the workspace
(§6.2). While files are over the window a dashed card covers it with an accent circle and a bobbing arrow: "Drop to
open", "Drop to combine 3 files", or the reason a drop can't work. When none of the dropped files is a PDF, the first
one converts before the workspace opens and the card says "Getting your files ready…" with a spinner. Recent rows: 36
pt, thumbnail 24 pt, name 13, metadata 11 secondary, hover tints the row with the accent; right-click → Show in Finder /
Remove from list.

Empty recents: the list area shows "Files you open will show up here." in `tertiaryLabelColor`.

### 6.2 The workspace (Combine, Rearrange)

Full-window mode on the soft blue canvas, entered by dropping several files on the welcome window or the app (Combine),
from the welcome window's Combine files, from the Rearrange tile, View › Page Organiser (⌥⌘6) or the sidebar's
"⤢". Mockups: `workspace.png` (Files, and `-dark`), `workspace-pages.png` (Pages, a drag in progress),
`workspace-preview.png` (the preview).

```
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  [▤▾] │ [📄 Files | ▦ Pages]  Combined           [+▾] [⟲] [⟳] [🗑] │ [◎] [⇅▾] [▦|☰]  (Finish) │
│              4 files · 17 pages                                                                │
├──────────────────────────────────────────────────────────────────────────────────────────────┤
│   ┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐              │
│   │◉ ┌────────┐  │     │○  [🔍⟳⧉🗑]   │     │○ ┌────────┐  │     │○ ┌────────┐  │              │
│   │  │▤▤▤▤▤▤▤▤│▏ │ (+) │  ┌─────────┐ │ (+) │  │   ⟳    │  │ (+) │  │▤▤▤▤▤▤▤▤│▏ │              │
│   │  │▤▤▤▤▤▤▤▤│▏ │     │  │ picture │ │     │  │ ▬▬▬▬── │  │     │  │▤▤▤▤▤▤▤▤│▏ │              │
│   │  └────────┘  │     │  └─────────┘ │     │  └────────┘  │     │  └────────┘  │              │
│   │(Lease agr…pdf)│    │(Floor plan.png)│   │(Budget 2026.xlsx)│ │(Schedule.pdf)│              │
│   │   12 pages   │     │    1 page    │     │Converting… 62%│    │   3 pages    │              │
│   └──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘              │
│   ┌ ─ ─ ─ ─ ─ ─ ┐                                                                              │
│   │     (+)      │   Add PDF, image, Word, Excel, and PowerPoint files · or drop them anywhere  │
│   │ PDF JPG DOC… │                                                                              │
│   └ ─ ─ ─ ─ ─ ─ ┘                                                                              │
├──────────────────────────────────────────────────────────────────────────────────────────────┤
│  4 files · 17 pages · 1 selected                  Drag to reorder · Space to preview · Drop more files anywhere │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Files | Pages** (the toolbar's first control, a picture and a word each). Files shows one card per file: its page
  stack (sheets fanned behind when it has more than one page), the file's name in its pastel pill, "12 pages". Pages
  shows one card per page, each with its file's pill (truncated in the middle) and "Page 3". The workspace opens on
  Files when it holds several files, on Pages for one document. A file is where its pages came from until the next
  save; a document's own pages are a file named after it.
- **Cards** are white, rounded, softly shadowed. A round checkbox at the top left selects (click the card to select it
  alone, ⌘ and ⇧ add, ⌘A or Select All takes everything); selected cards get a 2.5 pt accent ring. Hovering grows the
  card a touch and shows a small white toolbar at its top right: **Preview** (🔍), **Rotate** (⟳), **Duplicate** (⧉: in
  Files the copy is a file of its own in the next colour; in Pages it stays in its file), **Delete** (🗑, red). Each has
  a tooltip, and each is also the card's accessibility action.
- **The round "+"** sits between neighbouring cards in Files (and appears in the gap under the pointer in Pages): it
  opens the add menu for that spot (From file… — any format, converted —, Blank page, From scanner…, From iPhone…).
- **The add card** ends the grid: dashed accent border, a big "+", "Add PDF, image, Word, Excel, and PowerPoint files",
  "or drop them anywhere" and the formats as coloured badges. A click chooses files; a drop adds them.
- **Converting**: a file that isn't a PDF waits as its own card where it will go, with a spinner, a progress bar and
  "Converting… 62%" (or "Converting to PDF…" while the converter can't tell), then becomes a real card; each file is
  one undo step. Files dropped anywhere on the canvas go into the gap under the pointer.
- **Drag to rearrange**: the dragged cards leave their places and the others spring aside to open a dashed hole where
  they will land; release and they settle there, every card sliding to its new place. Dragging cards out to Finder makes
  a PDF of their pages; dragging them to another window copies them (⌥ moves).
- **Toolbar**: View ▾ · Files | Pages · the window's title with "4 files · 17 pages" · **Add ▾** · Rotate Left · Rotate
  Right · Delete (the selection) · Select All · **Sort ▾** (Name (A to Z), Name (Z to A), Reverse Order: whole files
  move, one undo step) · Grid | List · **Finish** (prominent). List shows 64 pt rows: checkbox, a small page, the pill,
  the count, the toolbar at the right when hovered.
- **Preview** (🔍, double-click, Space or Return): the page large on the frosted canvas, the file's pill at the top left,
  ✕ at the top right, and a floating bar with ‹ 5 / 12 ›, Rotate Left, Rotate Right and Delete. From a file card it
  turns that file's pages; from a page card, every page. ← → turn, ⌘L ⌘R rotate the page shown, ⌫ deletes it, Esc,
  Space or a click outside the page closes it.
- **Keys**: arrows move the selection (⇧ extends), ⌫ deletes, ⌘L ⌘R rotate, ⌘A selects all, Space previews, ⌘+ / ⌘− (or
  pinch) resize the cards, Esc closes the preview, then goes back to the document.
- **Finish** goes back to the document and shows the banner: "Combined 4 files into 17 pages." with Save… for a
  combine, "All set: 12 pages, in your order." with Save… after rearranging. Nothing is written until Save; Esc goes
  back without the banner (changes kept, undo stack intact).
- The status line always counts files, pages and the selection and says what the gestures do (11 pt secondary).

### 6.3 Sidebar modes

- **Thumbnails**: as §2; context menu: Rotate Left ⌘L · Rotate Right ⌘R · Delete Page ⌫ · Extract Page… · Insert
  Page ▸ (Blank, From File…, From Scanner…, From iPhone…) · Duplicate · Crop… · Black out this page… · Make smaller… ·
  Share Page….
- **Table of Contents**: outline tree, 24 pt rows, 13 pt (Preview); drag to nest/reorder, double-click to rename,
  "+" adds an entry for the current page; empty: "No table of contents. Add entries with +, or let us find headings."
  with button **Find headings**.
- **Highlights and Notes**: Preview's cells (page number 11 bold, author 11, content 13), plus Reply/Resolve; filter
  chips at the top; empty: "No highlights or notes." (Preview: "No Highlights or Notes Found").
- **Bookmarks**: Preview's 45 pt cells; ⌘D adds.
- **Attachments**: rows with icon, name, size; drag in to add; empty: "No attachments. Drop a file here to attach it."
- **Search**: Preview's results cells (38 × 50 thumb, snippet 13, "3 matches" 11), sort by Page Order / Search Rank.
- **Signatures**: list of signatures with status icons; "Verify all".

### 6.4 Markup bar

Preview's bar, same order, same labels: Text Selection · Selection ▾ · Black out · Sketch · Draw · Shapes ▾ · Text ·
Highlight · Sign ▾ · Note ‖ Shape Style · Border Colour · Fill Colour · Text Style ‖ Rotate · Crop · Form Fill. Two
additions at the end, separated: **Stamp ▾** and **Measure ▾**. Shortcuts as Preview (⌃⌘H highlight, ⌃⌘U underline,
⌃⌘S strike, ⌃⌘R rectangle, ⌃⌘O oval, ⌃⌘I line, ⌃⌘A arrow, ⌃⌘T text, ⌃⌘N note, ⌃⌘L loupe).

### 6.5 (Retired: chat side panel)

Super PDF has no AI tools (`features.md` §3.4), so there is no chat panel. The section number stays so references to
§6.6 keep meaning.

### 6.6 Settings (⌘,)

Panes: **General** (open files in tabs, default save behaviour: Ask / Always save a copy / Replace, author name,
default zoom), **Tools** (favourites in toolbar, recently-used row on/off, show jargon names in hints on/off for
experts), **Converters** (LibreOffice: Not installed · Get LibreOffice / Installed at … · Choose… · Look Again, and the
MPL notice; Office apps found: Word, Pages…), **Signatures** (my certificate, trusted people, timestamp server off), **Scanning** (default dpi/colour),
**Privacy** (the exhaustive network list from `features.md` §3.5, "Check for updates" toggle).

## 7. Copy: results, saving, errors, empty states

### 7.1 Saving

- First ⌘S on a file we did not create: sheet "Save changes to "Report.pdf"?" with **Save a copy…** (default; proposes
  "Report (edited).pdf" in the same folder), **Replace original**, Cancel. A checkbox "Always do this" sets the
  General setting. Files created here (Combined, converted) just show the save panel.
- Autosave and versions are on after the first choice (NSDocument). Revert To › Browse All Versions works.
- Closing with unsaved changes: Preview's wording: "You have a Super PDF document with unsaved changes. Do you want to
  review these changes before closing?" — Review Changes… / Discard Changes / Cancel.

### 7.2 Output naming

`<name> (<what>).<ext>` in the same folder; suffixes: smaller, blacked out, protected, no password, locked in, signed,
archive, clean, repaired, part 1…, pages 3-5. Collisions get " 2". The location is always shown in
the panel and changeable with "Change…".

### 7.3 Result banners

| Tool | Banner |
|---|---|
| Make smaller | Done. The file is 72% smaller (6.1 MB → 1.7 MB). · Show in Finder · Share · Undo |
| Recognise text | Recognised 14 pages. You can now search and copy the text. · Undo |
| Black out | Blacked out 12 items on 5 pages and saved "Report (blacked out).pdf". · Show in Finder |
| Combine (the panel, the workspace's Finish) | Combined 3 files into 41 pages. · Save… |
| Rearrange (the workspace's Finish) | All set: 12 pages, in your order. · Save… |
| Convert to Word | Saved "Report.docx". · Open in Word · Show in Finder |
| To images | Saved 12 images in "Report images". · Show in Finder |
| PDF/A | Saved "Report (archive).pdf". It passes the PDF/A-2b check. |
| Password | Saved "Report (protected).pdf". Keep the password somewhere safe. |
| Sign | Signed and saved "Contract (signed).pdf". · Share |
| Request signatures | Sent to 2 people. We'll match their files when they come back. · Show requests |
| Split | Saved 4 files in "Report parts". · Show in Finder |
| Rotate/Delete (in place) | no banner; the sidebar shows it and ⌘Z works |

Every banner opens with its green check popping in and a short burst of confetti (none with Reduce Motion).

### 7.4 Error copy

Rules: say what happened, what it means, what to do; never a code on the surface ("Show details" reveals it); one
button that fixes it when possible.

| Situation | Copy | Action |
|---|---|---|
| Encrypted file | This document is password protected. Please enter the password below. (Preview's words) | Unlock / Cancel; wrong: "Invalid password. Please try again." |
| Owner-restricted | This file doesn't allow printing (or copying). If you know the owner password you can remove the limit. | Remove password… |
| Damaged file | "Report.pdf" couldn't be opened. It may be damaged. We can try to repair it. | Repair / Cancel; repaired: "We repaired "Report.pdf". Check that everything looks right, then save a copy." |
| Not a convertible type | Super PDF can't turn ".sketch" files into a PDF. Try opening the file in its app and using Print › Save as PDF. | OK |
| Needs LibreOffice | Spreadsheets saved as ".ods" need the free Office converter (LibreOffice, about 800 MB). | Get LibreOffice (opens its download page) / Not now |
| Needs an Office app | To convert this with full fidelity, Excel needs to open it briefly. | Use Excel / Use the built-in converter (simpler result) |
| iWork app missing | Pages isn't installed, so only the preview inside the file can be used (usually the first page). Pages is free on the Mac App Store. | Continue / Get Pages |
| No iPhone | No iPhone or iPad nearby. Make sure it's unlocked, close by, and signed in to the same Apple Account. | Try again |
| No scanner | No scanner found. Check that it's on and connected. | Try again |
| Fonts missing (edit text) | The font "Garamond Premier" isn't on this Mac, so new text uses "Georgia" instead. | OK |
| Can't delete last page | A PDF needs at least one page. | OK |
| Redact confirm | This permanently removes 12 items from the new file. Your original stays as it is. | Black out / Cancel |
| Conversion failed | Something went wrong converting "Budget.xlsx". The file may be damaged or use features we don't support yet. | Try with LibreOffice / Show details |
| Signature invalid | This signature doesn't match the document: it was changed after signing. | Show what changed |
| Form has scripts | This form uses scripts we don't run. Calculations may not update. | OK |
| XFA form | This form was made with an Adobe-only format. You can view it but not fill it here. | OK |

### 7.5 Empty states

| Where | Text |
|---|---|
| Welcome recents | Files you open will show up here. |
| Thumbnail sidebar (no doc) | — (sidebar hidden) |
| Table of Contents | No table of contents yet. (+ Find headings) |
| Highlights and Notes | No highlights or notes. |
| Attachments | No attachments. Drop a file here to attach it. |
| Search | Not found (Preview) / No results for "%@". |
| Comments list filter | Nothing unresolved. |
| Signatures I asked for | No requests yet. Use Tools › Request signatures to send a document for signing. |
| Tools search | Nothing called "%@". Try "smaller", "sign" or "Word". |
| Compare | Drop the other version here, or choose it. |

## 8. Keyboard and menus

Menus mirror Preview's exactly where they overlap (File: New from Clipboard ⌘N, Open… ⌘O, Open Recent, Close ⌘W,
Save ⌘S, Duplicate, Rename, Move To, Revert To, Enter Password…, Edit Permissions…, Import from iPhone…, Import from
Camera…, Import from Scanner…, Export As…, Export as PDF…, Print… ⌘P; Edit: Undo/Redo, …, Insert ▸ Page from Scanner…
/ Page from File… / Blank Page, Find ▸, Spelling, Speech; View: Hide Sidebar ⌥⌘1, Thumbnails ⌥⌘2, Table of Contents
⌥⌘3, Highlights and Notes ⌥⌘4, Bookmarks ⌥⌘5, Page Organiser ⌥⌘6, Contact Sheet ⌥⌘7, Continuous Scroll ⌘1, Single Page
⌘2, Two Pages ⌘3, Use Dark Appearance for PDF, Actual Size ⌘0, Zoom to Fit ⌘9, Zoom In/Out ⌘+/−, Show Markup Toolbar
⇧⌘A, Customize Toolbar…, Slideshow ⇧⌘F, Enter Full Screen ⌃⌘F; Go: Up/Down, Previous/Next Item ⌥↑/↓, Go to Page…
⌥⌘G, Back/Forward ⌘[/]; Tools: **All Tools… ⌘T**, Show Inspector ⌘I, Show Magnifier `, Annotate ▸ (Preview's list),
Add Bookmark ⌘D, Rotate Left ⌘L, Rotate Right ⌘R, Crop ⌘K, then one submenu per Tools section with every tile;
Window: tabs, Welcome, Signature Requests; Help). New shortcuts: ⌘T Tools, ⌥⌘6 Page Organiser, ⌘⇧S Save a
copy.

## 9. Accessibility of the app

Every tile, control and thumbnail has a VoiceOver label and hint (the tile hint is the accessibility hint); the Tools
sheet is a grid with headings, and its section chips are buttons; workspace cards are checkboxes named "Lease
agreement.pdf, 12 pages" whose hover toolbar (Preview, Rotate, Duplicate, Delete) is also their accessibility actions,
the "+" between cards is a button "Add files here", and the preview's bar is a toolbar; panels have a default button
and Esc; Increase Contrast adds 1 pt borders to tiles and
buttons; Reduce Motion disables movement; text sizes follow the system's text-size preference (Settings › General ›
Text size in the app: Default / Larger / Largest scales 13 → 15 → 17 everywhere); colour is never the only signal
(a file's pill carries its name; redaction marks have an icon); pill ink on its fill is at least 4.5 : 1.

## 10. Decisions and alternatives

| Decision | Alternative rejected | Why |
|---|---|---|
| One **Tools** sheet with tiles | Acrobat's right rail of tools; a ribbon; a tab bar of categories | Rails and ribbons are always visible and make the window busy; a sheet keeps Preview's calm window and gives tiles room for a hint line. Favourites in the toolbar cover the "one click" need for frequent tools. |
| Tool panel inline on the right (320 pt) | Floating palettes; modal sheets for every tool | Floating windows get lost; modal sheets hide the document, which is the preview. Inline matches Preview's Inspector. |
| Document is the preview | A preview thumbnail inside the panel | A thumbnail is too small to judge a watermark or a crop. The real page at real size is the best preview. |
| New file by default for file-level tools | Overwrite with undo | Undo can't be trusted across a crash or after closing; a sibling file is what people expect ("where's my original?" never happens). |
| Plain names with jargon as synonyms | Acrobat's names | The brief's grandma test; experts still find tools by typing the old name. |
| The workspace as a full-window mode | Only the sidebar | Dragging in a 197 pt column is cramped for big reorders and for mixing files; Preview already has a Contact Sheet mode. |
| A brand palette on top of the system colours | System colours only | The system colours are calm but grey-feeling next to the web tools people know; one fixed, tested colour per section makes the app recognisable and easy to scan, while chrome, text and the accent still follow the system. |
| Files and Pages views of the same document in the workspace | A separate combine queue window | One model (the document's pages and where each came from) means every gesture, undo and Save work the same in both views; nothing is copied until Finish. |
| Cards laid out by hand, springing aside while dragging | `NSCollectionView` with a gap indicator | A collection view can't move its items out of the way while a drag is over it; hand layout keeps only the cards on screen alive, so 500 pages stay light. |
| Combine opens the workspace | Opening the Combine panel | Seeing every file as a big card, converting in place, is the easiest way to get the order right; the panel stays for the Tools sheet and Finder's Quick Action. |
| Request signatures as a file exchange | Hosted links | No server, by constraint; email/Messages/AirDrop are what the audience uses anyway. |
| Preview's exact menu and shortcut set | Our own structure | Zero relearning for Preview users; muscle memory keeps working. |
