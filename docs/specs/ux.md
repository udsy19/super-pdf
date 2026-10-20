# UX design

Super PDF is Preview with one more button. This document is the contract for how the app looks and behaves: the
window, the Tools sheet, the tool panels, drag and drop, the welcome window, the page organiser, copy, metrics, type,
colour, motion, empty states and errors. The mockups in `../mockups/` render these screens; `features.md` says what
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
rearrange, dropped files combine, dragged-out pages become a new PDF.

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
| **Apple's tone** | Sentence case, curly quotes around file names, a real ellipsis on anything that opens a dialog, no exclamation marks, no "Oops". |

### 1.2 How many clicks

| Task | Clicks after opening the file |
|---|---|
| Any tool | 2: **Tools** → tile (the panel opens with sensible defaults) + 1 to confirm. Favourites pinned to the toolbar are 1 click. |
| Rotate a page, delete a page | 0 clicks: select the thumbnail, press ⌘R / ⌫ (Preview's keys), or right-click → Rotate Right. |
| Rearrange pages | drag |
| Combine files | drop the files on the sidebar (or the Dock icon, or the welcome window) |
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
| Tools button | Bordered-prominent (accent-filled) capsule, 28 pt tall, 16 pt side padding, label "Tools" with `square.grid.2x2` 13 pt symbol on the left; ⌘T; appears in the window title as the only coloured control | The one new thing must be findable in a second. |
| Title | Document name centred, 13 pt semibold; "— Edited" suffix in secondary colour; proxy icon draggable | NSWindow standard. |
| Sidebar | Default 197 pt (Preview's saved `PVPDFLastSidebarWidth`), min 140, max 360; thin divider | Preview. |
| Sidebar thumbnails | Width = sidebar − 32 pt, aspect of the page, 8 pt radius, 1 pt border (`separatorColor`), 4 pt shadow; page number 11 pt below, centred; selected: 2 pt accent ring + accent 15% fill behind; 12 pt vertical gap | Preview's `PVFIIconView` scales to the sidebar width; page labels 11 pt. |
| Sidebar modes | Thumbnails ⌥⌘2 · Table of Contents ⌥⌘3 · Highlights and Notes ⌥⌘4 · Bookmarks ⌥⌘5 · Attachments ⌥⌘6 (Preview's Contact Sheet becomes our page organiser, ⌥⌘6 → ⌥⌘7 keeps Contact Sheet) · Search results (appears while searching) · Signatures (appears when the file has signatures) | Preview's View menu, extended. |
| Sidebar bottom bar | 29 pt: "12 pages" 11 pt secondary left; `plus` button right → "Add pages" menu (From file…, Blank page, From scanner…, From iPhone…) | Preview's `SidebarPaneBottomView` is 29 pt. |
| Document well | `underPageBackgroundColor`; page shadows on; page-break margins 4/4/4.75/4.75; continuous scroll default; book mode for two pages; scale 0.1–20 | Preview's `PDFContentView.nib` defaults. |
| Tool panel | 320 pt wide (Preview's Inspector width), inline (pushes the document, never floats), min document width 360 pt → below 1000 pt window width the panel overlays as a sheet-like card; header 52 pt; content inset 20 pt; footer 76 pt | Inspector precedent; no floating palettes. |
| Markup bar | 31 pt sub-toolbar under the toolbar, as Preview (`PVEditBanner` 1024 × 31) | Preview. |
| Result banner | 44 pt, under the toolbar, full width, `controlBackgroundColor` with a 1 pt bottom separator; icon + 13 pt text + buttons right; auto-hides after 8 s, or stays while the pointer is inside | Preview uses 28–31 pt banners for "A newer version of this document is available"; ours needs buttons. |
| Page organiser grid | Thumbs 160 pt wide default (slider 80–320; Preview's contact sheet default 120), 24 pt gap, 12 pt radius; hover reveals rotate ⟲ ⟳ and ✕ at the bottom; insertion line 3 pt accent | Google Photos "hold, then drag pages to rearrange" pattern. |
| Tools sheet | 880 × 620 pt (clamped to window − 80 pt each way; min 640 × 480); corner 16 pt; search field 32 pt tall; tiles 150 × 116 pt in a 5-column grid with 16 pt gaps and 24 pt margins; section header 13 pt semibold uppercase-free, 32 pt tall | Fits five tiles; readable at arm's length. |
| Tile | 150 × 116 pt, 12 pt radius, `controlBackgroundColor` with 1 pt `separatorColor` border; 40 pt circle in the category colour at 15% with a 20 pt symbol in the category colour; name 13 pt semibold; hint 11 pt secondary, 2 lines, truncated; hover: border → accent, lift 1 pt, 150 ms; keyboard focus ring | |
| Primary button | Full panel width, 36 pt tall, 10 pt radius, accent fill, 13 pt semibold white; disabled at 40% | Bigger than AppKit's 22 pt default on purpose. |
| Welcome window | 760 × 520 pt, non-resizable, centred; four 160 × 140 pt targets; recents list below | |

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

Semantic system colours only, so light and dark mode, accent colour choice and Increase Contrast all work for free.

| Token | Light | Dark | Use |
|---|---|---|---|
| `windowBackgroundColor` | #ECECEC | #323232 | window chrome |
| sidebar (vibrant `sidebar` material) | ≈ #F2F2F2 | ≈ #2A2A2A | sidebar, Tools sheet background |
| `underPageBackgroundColor` | #E6E6E6 | #1E1E1E | document well |
| `controlBackgroundColor` | #FFFFFF | #1E1E1E / 2A2A2A | tiles, panel cards, banner |
| `separatorColor` | #000 10% | #FFF 10% | borders, dividers |
| `labelColor` / `secondaryLabelColor` / `tertiaryLabelColor` | #000 85% / 50% / 25% | #FFF 85% / 55% / 25% | text |
| `controlAccentColor` (default blue) | #007AFF | #0A84FF | Tools button, primary buttons, selection rings, drop highlights, insertion line |
| `systemRed` | #FF3B30 | #FF453A | Black out marks, destructive confirm buttons only |
| Category colours (tiles) | blue #007AFF Pages · green #34C759 Convert · orange #FF9500 Edit · yellow #FFCC00 Mark up · purple #AF52DE Sign & fill · red #FF3B30 Protect · teal #30B0C7 Fix & check · brown #A2845E Scan | dark variants per Apple's system palette | tile icon circles, panel header icons, nothing else |
| Highlight colours | Preview's: Yellow #FACD5A, Green #7CC868, Blue #69B0F1, Pink #FB5C89, Purple #C885DA (dark: #5E4613, #294714, #1F3466, #5E2D42, #422D61); notes fill #FFEB6B etc. | | markup, identical to Preview so files look the same in both apps |

Redaction marks: 1.5 pt `systemRed` outline with 10% fill before applying; solid black (or the chosen colour) after.

### 2.4 Iconography

SF Symbols throughout, the same ones Preview and the menus use: `sidebar.leading`, `pencil.tip.crop.circle` (Markup),
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
| Tool panel open/close | Width 0 → 320 with ease-out 220 ms; the document re-fits width during the animation; content fades in at 120 ms |
| Switching tools | Crossfade content 150 ms; header title slides 8 pt |
| Thumbnail drag | Picked-up thumb scales 1.05 with 8 pt shadow; others shift with a spring (response 0.3, damping 0.8); insertion line fades in 100 ms |
| Drop target | 2 pt accent ring + 8% accent tint over the target, 120 ms; the label "Add here" appears after 300 ms hover |
| Result banner | Slides down 44 pt under the toolbar, 300 ms ease-out; progress bar inside for long jobs; hides up after 8 s or on click |
| Live preview edits (watermark, numbers, headers) | Re-render debounced 80 ms; no animation, the page just updates |
| Page rotate | 90° rotate of the thumbnail and page 250 ms |
| Reduce Motion on | Crossfades only, no movement |

## 3. Drag and drop everywhere

| Drag | Onto | Result | Target feedback |
|---|---|---|---|
| Files (PDF, images, Office, anything convertible) | Dock icon or the welcome window | One file opens; several files → "Combine these 3 files?" sheet with the queue (§6.2) | Dock bounce; welcome window target highlights |
| Files | Document window (page area) | Opens in a new tab/window (PDF) or converts then opens | Window-wide accent ring, label "Open" |
| Files | Sidebar between two thumbnails | Inserts the file's pages at that position (converting first if needed) | Insertion line + "Add 3 pages here" |
| Files | Sidebar end | Appends | Insertion line at end |
| Thumbnails | Within sidebar / organiser | Reorder (multi-select supported) | Insertion line |
| Thumbnails | Another document's sidebar | Copies pages there (⌥ moves) | Insertion line in that window |
| Thumbnails | Finder / Desktop / Mail | A new PDF "Report – pages 3-5.pdf" (file promise) | Standard drag image: stacked pages with a count badge |
| Image file | A page (in Edit or Markup mode) | Edit mode: placed as a page object; Markup: placed as an image stamp | Cursor badge shows "+" and a label "Place image" |
| Text | A page | New text box | Label "Add text" |
| Files | Tools sheet tile (e.g. "Combine files", "Images → PDF", "To Word") | Runs that tool on the dropped files | Tile highlights |
| PDF | A tool panel's drop zone (Compare, Insert pages, Watermark from file) | Fills that input | Zone highlights |

Rules: the drop target always says what will happen in two or three words; a drop that cannot work shows the "not
allowed" cursor and the reason in a tooltip ("Can't add a folder. Drop the files inside it."); a drop onto an
encrypted document asks for the password first; dropping never overwrites a file.

## 4. The Tools sheet

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                       ✕   │
│   What do you want to do?                                                                 │
│   ┌──────────────────────────────────────────────────────────────────────────────────┐    │
│   │ 🔍  Search tools — try "smaller", "sign", "Word", "black out"                      │    │
│   └──────────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                           │
│   Recently used                                                                           │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐                        │
│   │ ◯ Make   │ │ ◯ Sign   │ │ ◯ Combine│ │ ◯ To Word│ │ ◯ Black  │                        │
│   │  smaller │ │          │ │  files   │ │          │ │  out     │                        │
│   └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘                        │
│                                                                                           │
│   Pages                                                                                   │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐                        │
│   │ ◯ Combine│ │ ◯ Rear-  │ │ ◯ Split  │ │ ◯ Extract│ │ ◯ Rotate │                        │
│   │  files   │ │  range   │ │          │ │  pages   │ │  pages   │                        │
│   │ Put files│ │ Drag pa- │ │ Make se- │ │ Save some│ │ Turn     │                        │
│   │ together │ │ ges in   │ │ veral    │ │ pages as │ │ pages    │                        │
│   └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘                        │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐                        │
│   │ ◯ Delete │ │ ◯ Crop   │ │ ◯ Insert │ │ ◯ Number │ │ ◯ Booklet│                        │
│   │  pages   │ │          │ │  pages   │ │  pages   │ │          │                        │
│   └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘                        │
│                                                                                           │
│   Convert                                                                                 │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐                        │
│   │ ◯ To Word│ │ ◯ To Exc.│ │ ◯ To Pow.│ │ ◯ To ima-│ │ ◯ Any    │   … (scrolls)          │
│   └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘                        │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

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
│ ‹   ◯ Watermark              ✕   │  52 pt header: back (to Tools sheet), category icon, 15 pt title, close
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

- **Header**: back arrow returns to the Tools sheet with the search text preserved; ✕ closes the panel (Esc too).
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
- **Progress**: the button becomes a progress bar with "Page 14 of 120 · Stop"; the panel stays open; the sidebar
  thumbnails tick as pages complete.
- **Result**: the panel closes and the result banner appears (§7.3). For new files the new document opens in a new
  tab (⌘-click the banner to reveal in Finder).
- **Errors** appear inside the panel above the footer as a 13 pt message with an icon and one action (§7.4).

### 5.2 Panel archetypes

| Archetype | Used by | Shape |
|---|---|---|
| **A. One-choice** | Rotate, Delete, Extract, Lock in notes, Remove password, Repair, Fast web view, Read aloud | Scope + one control (or none) + button. Many of these are better reached from the thumbnail context menu; the panel exists so the tile works. |
| **B. Preset + more** | Make smaller, For archiving, To images, Split, Booklet, Resize | Three radio presets with a consequence line each ("Email · 1.7 MB"), More options for the full set. |
| **C. Live-preview editor** | Watermark, Headers & footers, Number pages, Bates, Background, Crop, Stamps, Links | Controls on the left panel, effect drawn on the page immediately, drag handles on the page where position matters. |
| **D. Mode** | Edit text & images, Draw & shapes, Highlight & notes, Fill a form, Make a form, Measure, Black out (marking), Sign (placing), Rearrange (organiser), Compare | The panel is a thin palette (tool buttons + properties) and the document becomes interactive; the footer button is "Done". |
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

**Combine files** (E) — the queue (list with thumbnails, name, pages, "Pages: all ▾", drag to reorder, ✕); "Add
files…" button and a drop zone; option "Add a contents entry for each file" **on**; File size popup **Normal**. Button
**Combine 3 files**. Output: new unsaved document "Combined.pdf" (Save asks where). Also the organiser view for
mixing pages (§6.2).

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

Shown when the app opens with no document (and via Window › Welcome). Non-resizable 760 × 520.

```
┌────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●                                                                      │
│                                                                            │
│                              Super PDF                                     │
│              Open a PDF, or drop any file here to turn it into one.        │
│                                                                            │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│   │              │  │              │  │              │  │              │   │
│   │   ▢ Open     │  │  ▢▢ Combine  │  │  ▣ Scan      │  │  ⇄ Convert   │   │
│   │   a PDF      │  │  files       │  │              │  │  a file      │   │
│   │              │  │  Make one    │  │  iPhone or   │  │  Word, photos│   │
│   │  ⌘O          │  │  PDF from    │  │  a scanner   │  │  and more    │   │
│   │              │  │  several     │  │              │  │  → PDF       │   │
│   └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘   │
│                                                                            │
│   Recent                                                                   │
│   ┌─┐ Lease agreement.pdf           Yesterday, 4:12 PM     12 pages  2.1 MB│
│   ┌─┐ Tax return 2025.pdf           Monday                 44 pages  8.0 MB│
│   ┌─┐ Grandma's recipes.pdf         12 Sep                  6 pages  310 KB│
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

Targets are 160 × 140, 14 pt radius, icon 36 pt in the category colour, label 15 semibold, hint 11 secondary. Dropping
files anywhere in the window acts like "Combine files" (one file: open/convert). Recent rows: 36 pt, thumbnail 24 pt,
name 13, metadata 11 secondary; right-click → Show in Finder / Remove from list.

Empty recents: the list area shows "Files you open will show up here." in `tertiaryLabelColor`.

### 6.2 Page organiser (Rearrange, Combine)

Full-window mode, like Preview's Contact Sheet, entered from the Rearrange tile, View › Page Organiser (⌥⌘6), the
sidebar's "⤢" button, or by dropping a second file on a document.

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   Rearrange pages — Report.pdf            [Select all]  [⟲] [⟳] [🗑]  (size ────●──)  Done │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────┐    ┌─────────┐    ┌─────────┐  ┃ ┌─────────┐    ┌─────────┐    ┌ ─ ─ ─ ─ ┐  │
│   │ ░░░░░░░ │    │ ░░░░░░░ │    │ ▓▓▓▓▓▓▓ │  ┃ │ ░░░░░░░ │    │ ░░░░░░░ │    │   +     │  │
│   │ ░░░░░░░ │    │ ░░░░░░░ │    │ ▓▓▓▓▓▓▓ │  ┃ │ ░░░░░░░ │    │ ░░░░░░░ │    │ Add     │  │
│   │ ░░░░░░░ │    │ ░░░░░░░ │    │ ▓▓▓▓▓▓▓ │  ┃ │ ░░░░░░░ │    │ ░░░░░░░ │    │ pages   │  │
│   └─────────┘    └─────────┘    └─────────┘  ┃ └─────────┘    └─────────┘    └ ─ ─ ─ ─ ┘  │
│       1              2              3        ┃     4              5                       │
│                                 ⟲  ⟳  ✕      ┃ ← insertion line while dragging            │
│                                                                                          │
│   ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐                 │
│   │ ░░░░░░░ │    │ ░░░░░░░ │    │ ░░░░░░░ │    │ ░░░░░░░ │    │ ░░░░░░░ │                 │
│   └─────────┘    └─────────┘    └─────────┘    └─────────┘    └─────────┘                 │
│       6              7              8              9             10                       │
│                                                                                          │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│  12 pages · 3 selected         Drag pages to rearrange. Drop files here to add them.      │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

- Thumbs 160 pt (slider), page numbers below, pages from a second file keep a coloured 3 pt bar in that file's colour
  until saved (so you can see what came from where); hover shows ⟲ ⟳ ✕ under the thumb; multi-select with ⌘/⇧ and
  rubber-band; drag to reorder with a 3 pt accent insertion line; drag out to Finder extracts; ⌫ deletes (undoable);
  ⌘R/⌘L rotate; the "+ Add pages" tile at the end opens the add menu and is also a drop target.
- Bottom status line explains the two gestures permanently (11 pt secondary).
- Done returns to the document; nothing is written until Save. Esc also returns (changes kept, undo stack intact).
- Combine from the welcome window opens the same screen with a left column listing the files (name, page count,
  colour) and the grid showing all pages in order; files can be reordered in the column, pages in the grid.

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
experts), **Converters** (LibreOffice: Not installed · Install… / Installed at … · Remove; Office apps found: Word,
Pages…), **Signatures** (my certificate, trusted people, timestamp server off), **Scanning** (default dpi/colour),
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
| Combine | Combined 3 files into 41 pages. · Save… |
| Convert to Word | Saved "Report.docx". · Open in Word · Show in Finder |
| To images | Saved 12 images in "Report images". · Show in Finder |
| PDF/A | Saved "Report (archive).pdf". It passes the PDF/A-2b check. |
| Password | Saved "Report (protected).pdf". Keep the password somewhere safe. |
| Sign | Signed and saved "Contract (signed).pdf". · Share |
| Request signatures | Sent to 2 people. We'll match their files when they come back. · Show requests |
| Split | Saved 4 files in "Report parts". · Show in Finder |
| Rotate/Delete (in place) | no banner; the sidebar shows it and ⌘Z works |

### 7.4 Error copy

Rules: say what happened, what it means, what to do; never a code on the surface ("Show details" reveals it); one
button that fixes it when possible.

| Situation | Copy | Action |
|---|---|---|
| Encrypted file | This document is password protected. Please enter the password below. (Preview's words) | Unlock / Cancel; wrong: "Invalid password. Please try again." |
| Owner-restricted | This file doesn't allow printing (or copying). If you know the owner password you can remove the limit. | Remove password… |
| Damaged file | "Report.pdf" couldn't be opened. It may be damaged. We can try to repair it. | Repair / Cancel; repaired: "We repaired "Report.pdf". Check that everything looks right, then save a copy." |
| Not a convertible type | Super PDF can't turn ".sketch" files into a PDF. Try opening the file in its app and using Print › Save as PDF. | OK |
| Needs LibreOffice | Spreadsheets saved as ".ods" need the free Office converter (LibreOffice, about 800 MB). | Install… / Not now |
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
sheet is a grid with headings; panels have a default button and Esc; Increase Contrast adds 1 pt borders to tiles and
buttons; Reduce Motion disables movement; text sizes follow the system's text-size preference (Settings › General ›
Text size in the app: Default / Larger / Largest scales 13 → 15 → 17 everywhere); colour is never the only signal
(file colour bars in the organiser also show the file's name on hover; redaction marks have an icon).

## 10. Decisions and alternatives

| Decision | Alternative rejected | Why |
|---|---|---|
| One **Tools** sheet with tiles | Acrobat's right rail of tools; a ribbon; a tab bar of categories | Rails and ribbons are always visible and make the window busy; a sheet keeps Preview's calm window and gives tiles room for a hint line. Favourites in the toolbar cover the "one click" need for frequent tools. |
| Tool panel inline on the right (320 pt) | Floating palettes; modal sheets for every tool | Floating windows get lost; modal sheets hide the document, which is the preview. Inline matches Preview's Inspector. |
| Document is the preview | A preview thumbnail inside the panel | A thumbnail is too small to judge a watermark or a crop. The real page at real size is the best preview. |
| New file by default for file-level tools | Overwrite with undo | Undo can't be trusted across a crash or after closing; a sibling file is what people expect ("where's my original?" never happens). |
| Plain names with jargon as synonyms | Acrobat's names | The brief's grandma test; experts still find tools by typing the old name. |
| Page organiser as a full-window mode | Only the sidebar | Dragging in a 197 pt column is cramped for big reorders and for mixing files; Preview already has a Contact Sheet mode. |
| Request signatures as a file exchange | Hosted links | No server, by constraint; email/Messages/AirDrop are what the audience uses anyway. |
| Preview's exact menu and shortcut set | Our own structure | Zero relearning for Preview users; muscle memory keeps working. |
