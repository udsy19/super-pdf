# Architecture

Super PDF is a native macOS app in Swift (Swift 5 language mode on the Swift 6 toolchain), built with SwiftPM and the
Command Line Tools only (no Xcode project). Deployment target macOS 14. It is a document-based app (NSDocument) with
one window per PDF, a welcome window, a settings window and a "Signature Requests" window. Every feature in
`docs/specs/features.md` runs on the Mac; the only network traffic is listed in features §3.5.

The look and behaviour are specified in `docs/specs/ux.md` (window, Tools sheet, panels, copy, metrics) and the tools
in `docs/specs/features.md` (behaviour, approach, engine). Section references in code comments point into those files
(`ux §5.3`, `features #69`).

## Engines: self-contained, adapted from the sister apps (decision)

Super Flow ships the GitHub Releases updater that this app needs. As in Super Granola, the engines are **copied into this repository as engine modules**
with provenance comments; there is no shared package and no path dependency on a sibling checkout (the sibling apps are
app packages whose modules are not products). A copy is a fork: fixes are ported by hand.

| Engine module | Contents | Source |
|---|---|---|
| `UpdateKit` | GitHub Releases updater: check, SHA-256 + code-signature verification, stage, swap on quit or idle | Super Flow `UpdateKit/*` |
| `PDFModelKit` | Swift wrapper over **QPDF** (features §3.1): document open/repair/save (incremental or full), object access, page tree ops, content-stream tokenizer, overlay/underlay, embedded files, name trees, page labels, outlines, structure tree, encryption (R6), linearization, image stream read/replace, signature placeholders and ByteRange patching. QPDF itself is a `binaryTarget` xcframework built by `scripts/build-qpdf.sh` (CMake, static libjpeg-turbo + system zlib) and published on this repository's Releases, pinned by checksum, as Super Flow pins llama.cpp | new; QPDF 12 (Apache-2.0) |

Rules for the copies: every copied file starts with `// Adapted from <repo> <path> (commit <sha>)` plus what changed;
engines carry no app policy (no `Services`, no `Defaults`, no UI strings); configuration comes in through initialisers;
each engine has a self-test file in `SuperPDFSelfTest`. The QPDF pin lives in `Package.swift`.

## Modules

```
Sources/
  SuperPDFCore/      contracts & shared utilities (no feature logic): domain model (DocumentHandle, PageRef, ToolID,
                     ToolRequest/ToolResult, Scope, OutputPolicy, ConversionJob, SignatureRequest…), service protocols,
                     the Services registry, SuperPDFPaths, typed Defaults + every settings key (ux §6.6), the TOOL
                     CATALOG as data (ux §4.1: id, section, name, hint, synonyms, SF Symbol, archetype, features #),
                     design tokens SPColor/SPFont/SPMetrics/SPMotion (ux §2.1–2.5), converter registry table as data (features §3.2), strings (ux §7), Keychain
                     helper, logging, undo helpers
  PDFModelKit/       engine: QPDF wrapper (see Engines)
  LayoutKit/         text & layout analysis engine (features §2.4): characters → words/lines/paragraphs/columns/
                     headings/lists/tables/figures/reading order; works on PDFKit text positions and on Vision OCR
                     output; produces a LayoutDocument used by convert, edit, reflow, compare, tagging, forms
  RenderKit/         Quartz rendering & writing: page rasterization at dpi, PDF/A and PDF/X contexts, booklet/N-up
                     imposition, "print as image", contact sheets, colour conversion via ColorSync, output preview
  DocumentKit/       NSDocument subclass (PDFDocument wrapper + PDFModelKit handle), open/repair/password flow, save
                     policy ("Save a copy / Replace", ux §7.1), versions, output naming (ux §7.2), undo stack for page
                     operations, recent documents, document-level state (view state)
  ViewerKit/         main window: toolbar (ux §2.1), sidebar modes (thumbnails with drag/drop, contents, notes,
                     bookmarks, attachments, search, signatures), PDFView host, reader mode, read aloud, find,
                     page organiser (ux §6.2), result banner, welcome window (ux §6.1), drag & drop (ux §3)
  ToolsKit/          the Tools sheet (ux §4), the panel host and archetypes A–E and G (ux §5), scope control, live
                     preview overlay (PDFPageOverlayViewProvider), progress/error presentation, favourites, frecency,
                     search with synonyms; registers every tool's panel from the catalog + the implementing service
  PagesKit/          page tools (features §1.2): combine, rearrange, rotate, delete, extract (file promises), split,
                     insert, replace, duplicate, reverse, crop, resize/page boxes, number pages, page labels,
                     booklet, contact sheet
  ConvertKit/        conversion registry runtime (features §3.2): native importers (NSAttributedString, TextKit
                     pagination, WebKit HTML/EPUB/Markdown, ImageIO, CSV, ZIP, EML, own xlsx/pptx/hwpx readers),
                     LibreOffice helper (detect, install, run), app automation (Word/Excel/PowerPoint/Pages/Numbers/
                     Keynote), Quick Look fallback; exporters: images, text, HTML, EPUB, docx/xlsx/pptx writers
                     (OOXML), PDF/A + verifier, PDF/X, comments/forms data (XFDF/FDF/CSV/JSON)
  EditKit/           edit text & images (content-stream block editing, font substitution, subsetting), add text/
                     image, find & replace, links, headers & footers, Bates, watermark, background, stamps,
                     optional content, remove scripts, properties/initial view
  MarkupKit/         annotation tools (Preview-identical markup bar), appearance-stream generation, comments list,
                     replies/status, correction marks, file/audio attachments, comment summary, XFDF import/export,
                     measure tool, snapshot
  FormsKit/          fill (widgets, AutoFill from Contacts, AF* calculation/format emulation, fill-anywhere),
                     make a form (field detection via LayoutKit, field palette, properties, tab order, barcodes),
                     form data import/export, templates
  SignKit/           signature library (Keychain, trackpad/camera/iPhone capture), placement, certificate signing
                     (CMS via swift-certificates, SecKey), verification + trust store, certificates (create/import/
                     export), request-signatures flow and tracker (features #84), seal + audit page
  ProtectKit/        password/permissions (PDFKit write options → PDFModelKit fallback), remove password, certificate
                     encryption, security envelope, remove hidden information, redaction (mark by hand / find by text
                     and patterns / apply with true content removal + rasterize-verify), flatten
  FixKit/            make smaller (presets, estimator, optimizer options, image downsampling), OCR (Vision → invisible
                     text layer; scan clean-up via Core Image), repair, fast web view, fonts embed, PDF/A check,
                     print checks, output preview, flatten transparency, printer marks/hairlines, accessibility check
                     + auto-tag + reading order editor + alt text
  ScanKit/           Continuity Camera (NSMenuItemImportFromDeviceIdentifier + NSServicesMenuRequestor), Image Capture
                     scanners (ICScannerDevice/IKScannerDeviceView), document detection from photos (Vision), clean-up
  BatchKit/          "Do this to many files": step pipelines over the tool registry, routines, Finder Quick Actions
                     (app extension target), App Intents (one per file-level tool), PDF Services print item
  SettingsKit/       settings window panes (ux §6.6), converters pane (LibreOffice
                     install/remove, detected apps), signatures pane, privacy pane
  UpdateKit/, PDFModelKit/
                     engines (see "Engines"): no app policy
  SuperPDF/          app target: launch sequence, module wiring, Services.updates, main menu
                     (Preview's tree + Tools, ux §8), superpdf:// routing, Dock menu, open/drop handling
  SuperPDFQuickActions/  Finder extension target (Combine, Make smaller, Convert to PDF, Recognise text)
  SuperPDFSelfTest/  headless checks (`swift run SuperPDFSelfTest`), per module, plus engine smoke tests and benches
```

## Rules

- Feature modules depend **only** on `SuperPDFCore` (plus the engine modules listed per module in `Package.swift`,
  and `LayoutKit`/`RenderKit`/`PDFModelKit` which are engines without app policy). They never import each other; they
  talk through the `Services` registry.
- Each protocol has one owning module. Its `<Module>Module.install()` registers the implementation in `Services`.
  The app target owns `Services.updates`.
- **Tools are data + a service.** The catalog in Core lists every tile (ux §4.1). A module implements
  `ToolProviding` for its tool ids: `func panel(for id: ToolID, context: ToolContext) -> ToolPanel` (the archetype and
  its controls) and `func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult`. ToolsKit
  hosts panels generically; a tool never builds its own window. Adding a tool = one catalog row + one provider case.
- **Output policy is enforced in one place.** `ToolResult` is either `.inPlace(undoable: UndoGroup)` or
  `.newFile(URL, banner: ResultBanner)`. DocumentKit applies ux §7: naming, "Save a copy / Replace", versions.
  No module writes to the open file's URL directly.
- `SuperPDFCore` is the contract. A change to it updates every implementation and fake in the same change.
  Module-private settings use the module as key prefix: `Key<Bool>("toolsKit.recentRow", …)`.
- UI code and service protocols are `@MainActor`. Engines (QPDF, Vision, rendering, SQLite, conversions)
  work off the main actor and hand back values; they never touch `Services` from a background thread. PDFKit objects
  are touched only on the main actor; long jobs work on a private `PDFModelKit` handle of the same bytes.
- Local-first: no network except features §3.5 (`PRIVACY.md` repeats the list). No telemetry, no remote flags.
- No dead code: superseded code, placeholders and their now-unused helpers go in the same change.
- Copy comes from `ux.md` §4.1 and §7; sentence case, curly quotes, real ellipsis. Prompts are our own wording.
- Preview parity: menu tree, shortcuts, sidebar labels, markup bar order and highlight colours match Preview
  (ux §2.3, §6.4, §8) so files and muscle memory carry over.

## Core contracts (`SuperPDFCore`)

| Type / protocol | Owner (registers in `Services`) | Spec |
|---|---|---|
| `DocumentHandle` (URL, PDFDocument, PDFModelKit handle, state), `PageRef`, `Scope` (all/current/range/selected), `OutputPolicy`, `ToolResult`, `ResultBanner` | DocumentKit: `documents: DocumentManaging` | ux §7, features §2.3 |
| `ToolID`, `ToolCatalog` (sections, tiles, hints, synonyms, archetype), `ToolPanel` (archetype + controls), `ToolRequest`, `ToolProgress`, `ToolProviding` | ToolsKit: `tools: ToolRegistry` (collects providers; frecency; search) | ux §4, §5 |
| `LayoutDocument` (blocks, lines, words with bounds, tables, figures, reading order) | LayoutKit: `layout: LayoutAnalyzing` | features §2.4 |
| `Renderer` (rasterize, write PDF/A/X, impose) | RenderKit: `render: Rendering` | features §1.4 |
| `ConverterRegistry` (input UTType → output → ranked `Converter`s with `availability`), `ConversionJob` | ConvertKit: `convert: Converting`, `helpers: HelperManaging` (LibreOffice) | features §3.2 |
| `PageOperations` | PagesKit: `pages: PageEditing` | features §1.2 |
| `ContentEditing`, `Decorations` (headers, watermark, Bates, stamps) | EditKit: `edit: ContentEditing` | features §1.5 |
| `Annotating`, `CommentsReviewing`, `Measuring` | MarkupKit: `markup: Annotating` | features §1.6 |
| `FormFilling`, `FormBuilding`, `AFScriptEmulator` | FormsKit: `forms: FormServicing` | features §1.7 #80–81 |
| `SignatureLibrary`, `CertificateSigning`, `SignatureVerifying`, `SignatureRequest` (+ store) | SignKit: `sign: Signing`, `requests: SignatureRequesting` | features §1.7 #82–85, §3.6 |
| `Protecting`, `Redacting`, `Sanitizing`, `Flattening` | ProtectKit: `protect: Protecting` | features §1.8, #69–70 |
| `Optimizing`, `OCRing`, `Checking` (PDF/A, print, accessibility), `Repairing` | FixKit: `fix: Fixing` | features §1.9 |
| `Scanning` (sources, sessions) | ScanKit: `scan: Scanning` | features §1.10 |
| `BatchPipeline`, `Routine` | BatchKit: `batch: BatchRunning` | features #75 |
| `Defaults` keys, `SPColor/SPFont/SPMetrics/SPMotion`, `Strings` | Core | ux §2, §6.6, §7 |
| `UpdateChecking` | app: `updates` (UpdateKit) | — |

### Contract notes (WP1)

What `SuperPDFCore` actually declares, where it differs from or adds to the table above:

- **Names.** `Renderer` is the `Rendering` protocol; the converter registry is data (`ConverterTable`: lower-case
  extensions → ranked `ConverterEngine`s, `toPDF` / `fromPDF` / `fallback`) plus ConvertKit's runtime `Converting`
  (`converters(for: UTType, to:)` answers `ConverterOffer`s with `ConverterAvailability`); `PageOperations` is the
  `PageOperation` enum run through `PageEditing.perform(_:in:)`; `Decorations` is the `Decoration` enum run through
  `ContentEditing.apply(_:to:in:replacing:)` (PagesKit's Number pages uses `.pageNumbers` there). `Annotating`,
  `FormServicing`, `Signing`, `Protecting` and `Fixing` compose the listed sub-protocols. `Fixing` also owns
  `compare(_:with:textOnly:progress:)` for Compare files.
- **Extra slots.** `Services.viewer` (`ViewerPresenting`: window controller per document, PDFView, selection, tool
  panel slot, banner, sidebar, organiser, welcome, and the locked-PDF password asked inside the document's window,
  which DocumentKit's prompter uses), `Services.settings` (`SettingsPresenting`), and
  `Services.toolProviders`: every tool module appends its `ToolProviding` in `install()`; ToolsKit reads the list when
  it installs (after them) and registers `Services.tools`.
- **Tool host.** `ToolProviding` (`tools`, `availability`, `panel(for:context:)`, `preview(for:context:)`,
  `handle(action:context:)`, `run(_:progress:)`), with defaults for availability, preview and actions. Panels are
  declarative: `ToolPanel` = archetype + up to three `ToolControl`s + More options + primary/secondary `ToolButton` +
  `OutputPolicy` + optional `ToolMessage` / `ToolConfirmation` / G-steps; every control id keys a `ToolValue` in
  `ToolValues` (Codable, so routines store them). `ToolControl.custom` hosts a provider's own view (mode palettes, flow
  steps). Live previews are `ToolPreview.overlay` (drawn per page in page space) or `.summary` lines. Failures throw
  `ToolError` (panel copy + one action). Archetype F is gone with the AI tools; the letters stay as ux §5.2 names them.
- **Results and output.** A run writes into `request.workFolder`; `ToolResult` is `.inPlace(undoable:banner:)`,
  `.newFile`, `.newFiles`, `.newDocument(Data, name:)` or `.none`; `DocumentManaging.apply(_:of:)` moves files to
  `request.destination` (resolved before the run by `destination(for:of:source:)`, ux §7.2 naming with " 2" on
  collisions) and registers undo. `UndoGroup` is `.actions(undo:redo:)` (registered with
  `UndoManager.register(_:)`) or `.contents(before:after:)` (bytes DocumentKit swaps). `OutputSuffix` follows ux §7.2;
  parts and page extracts use ux §5.3/§3's en-dash form ("Report – part 1.pdf"). `DocumentHandle.undoManager` is weak
  (NSDocument owns it).
- **Engines see bytes, not PDFKit.** `DocumentHandle.snapshot()` gives a `PDFSource` (file + password when unedited,
  else the document's contents with its PDFKit changes written in, as a save writes them); every engine-facing method
  takes `PDFSource`.
- **Saves keep structure.** PDFKit redraws every page when it writes and drops what it doesn't model (structure tree,
  optional content, transitions, named destinations, JavaScript, annotation names and reply links, form scripts, app
  keys and marked content). So a document's authoritative bytes are what it was read from, or what the last engine edit
  (`.contents` result, and its undo) made: `DocumentHandle.contents`, DocumentKit's `DocumentBaseline`, which also
  records what PDFKit showed for them (pages, rotation and boxes, annotation fingerprints, outline, attributes). A save
  or snapshot writes only the PDFKit-level differences into those bytes with QPDF (`StructureMerge`): page order,
  rotation, boxes, inserted and removed pages, annotations added, changed (PDFKit's keys merged over the file's
  dictionary, unknown keys kept) and removed, form values, the outline, the attributes. It appends an incremental update
  when it can (unencrypted, not rebuilt, no page removed) and rewrites the file with QPDF otherwise; PDFKit writes the
  whole file only when its document can't be paired with the bytes, and the log says why. MarkupKit's
  `annotationRestorer` puts back the data PDFKit can't hold into the annotations a save took from PDFKit (new or
  changed ones); FormsKit needs no restorer.
- **Catalog.** 52 tiles (ux §4.1's rows; its old "54" was a miscount before the AI tiles went). Each tile has an
  `owner` module and `needsDocument`. Owners where no work package named the feature: Contents and Read aloud →
  ViewerKit, Compare files → FixKit. Read aloud sits in Fix & check next to Check accessibility (the Understand section
  went with the AI tools). SF Symbols: those ux §2.4 names, the rest chosen in WP1 (self-test checks they exist).
- **Menus.** `MenuTree.main` is ux §8 as data; the app builds NSMenus from it. Items without a standard AppKit action
  send `performMenuCommand(_:)` (`MenuCommandResponding`) up the responder chain with the `MenuCommand` as identifier;
  `MenuCommand.tool(_:)` opens a tile. Attachments has no shortcut: ux §2.1 gives it ⌥⌘6, but §6.2 and §8 give ⌥⌘6 to
  Page Organiser, which wins. ⌥⌘A (was Chat) is free.
- **Self-test rules.** Scratch Application Support and defaults suite; no case opens, launches or activates another
  app or URL (inject fake openers); `makeDocument(pages:)` / `makePDF(pages:)` build fixtures; `SUPERPDF_SELFTEST_ONLY`
  filters cases. Run `scripts/build-qpdf.sh fetch` once per checkout before `swift build`.

## Launch sequence

1. `SuperPDFCore` bootstrap: paths, Defaults migration, logging.
2. `<Module>Module.install()` in dependency order: DocumentKit, LayoutKit, RenderKit, PagesKit, ConvertKit, EditKit,
   MarkupKit, FormsKit, SignKit, ProtectKit, FixKit, ScanKit, BatchKit, ToolsKit (collects providers and verifies every
   catalog tile has exactly one provider — a self-test too), ViewerKit, SettingsKit.
3. App target: `Services.updates`; main menu; PDF Services item
   offer (once); Quick Actions registration.
4. Open the files passed in, else the welcome window. Then `Services.updates.start()`.

## End-to-end tool flow

Tools button → ToolsKit sheet (catalog) → tile → `tools.provider(for:)` → `panel(for:context:)` → ToolsKit renders the
archetype with live preview via `PDFPageOverlayViewProvider` → primary button → `run(request, progress)` off the main
actor (engine work on a `PDFModelKit` handle or PDFKit on main for annotation-level edits) → `ToolResult` → DocumentKit
applies the output policy → ViewerKit shows the result banner → undo stack / new document tab.

## Data

- `~/Library/Application Support/Super PDF/Helpers/LibreOffice.app` (+ `lo-profile`), `Requests/<id>/` (signing
  packages, returns, audit), `Signatures/` (Keychain-referenced images), `Index/<folder-hash>.sqlite` (folder search,
  FTS5), `Routines/*.json`, `Stamps/`.
- Per-document view state in the document's extended attributes (`com.udsy.superpdf.viewstate`), never inside the PDF.
- Keychain: signing private keys (`SecKeyCreateRandomKey`, access control optional), signature images key.

## Native dependencies

System frameworks: AppKit, SwiftUI (panels and settings), PDFKit, Quartz/ImageKit, CoreGraphics, CoreImage, Vision,
VisionKit, ImageCaptureCore, WebKit, AVFoundation (speech), Contacts, Security, CryptoKit, Compression, SQLite3,
UniformTypeIdentifiers, AppIntents. Packages: QPDF xcframework (binaryTarget built by `scripts/build-qpdf.sh`, published
on this repo's Releases, fetched into `Vendor/` by `scripts/build-qpdf.sh fetch`), `swift-certificates` 1.21.0 +
`swift-asn1` 1.7.3 (Apple, Apache-2.0, pinned exactly). No other third-party code. Licences in `THIRD_PARTY_NOTICES.md`.

## Work packages

One worker per package; each owns only the paths listed, implements the services named, follows the cited spec
sections, and adds its `<Module>Tests.swift` to the self-test. "Done" always includes: `swift build` clean,
`swift run SuperPDFSelfTest` green, no edits outside the owned paths (contract changes go to WP1's owner or are made
in Core with every caller updated in the same change). Every tool a package ships must pass the grandma test
(ux §1.1) as written in its panel spec (ux §5.3) and produce the exact banner/error copy (ux §7).

**Waves**

| Wave | Packages | Starts when |
|---|---|---|
| A | WP0a, WP0b, WP0c, WP1 | now |
| B | WP2, WP3, WP4, WP5 | WP1 merged (placeholders for every module and engine exist) |
| C | WP6, WP7, WP8, WP9, WP10, WP11, WP12, WP13, WP14 | WP1 + WP2 (LayoutKit/RenderKit) + WP0c (PDFModelKit) merged; each works against the ToolsKit placeholder API announced by WP5 |
| E | WP16 | every B/C package merged (wave D held WP15, removed with the AI tools) |

**WP0a — UpdateKit from Super Flow** (heavy). `Sources/UpdateKit/**` and `UpdateKitTests.swift`. Copy and adapt with
provenance comments; configuration through initialisers; the shared value types from
`SuperPDFCore/Contracts/Engines.swift` (extend there in the same change). Super Flow is not changed.

**WP0b — QPDF xcframework build** (careful). `scripts/build-qpdf.sh`, `.github/workflows/qpdf.yml`,
`THIRD_PARTY_NOTICES.md` (QPDF, libjpeg-turbo, zlib). CMake static build of QPDF 12 + libjpeg-turbo for arm64 and
x86_64, universal `xcframework` with module map, SHA-256, release upload, `Package.swift` binaryTarget line. Acceptance:
a scratch Swift executable opens, re-saves and linearizes a PDF through the framework on both slices.

**WP0c — PDFModelKit** (fable or heavy). `Sources/PDFModelKit/**`, `PDFModelKitTests.swift`. Swift wrapper over QPDF
(features §3.1): open with recovery, passwords, incremental/full save, object model, page tree ops, content-stream
tokenizer/serializer with marked-content support, overlay/underlay form XObjects, image XObject read/replace, embedded
files, outlines, page labels, name trees, structure tree read/write, AcroForm dictionary edits, encryption R6,
linearize, signature placeholder + ByteRange patch + incremental-update analysis. No C++ past the module boundary.
Tests: fixture corpus (clean, damaged, encrypted, xref-stream, object-stream, signed) round-trips; every op verified by
re-opening with PDFKit.

**WP1 — Core contracts and scaffold** (heavy, single owner, first). `Sources/SuperPDFCore/**`, placeholder
`<Module>Module.swift` for every module, placeholder files for every engine, the app target skeleton,
`Sources/SuperPDFSelfTest/{main,CoreTests,Fakes}.swift`, per-module test stubs. Everything in "Core contracts":
domain model, service protocols with fakes, `Services`, `SuperPDFPaths`, `Defaults` (ux §6.6), **the tool catalog
as data (ux §4.1, all 52 tiles with hints and synonyms)**, converter registry table (features §3.2), design tokens
(ux §2.1–2.5), strings (ux §4.1 hints, §7 banners/errors/empty states), menu tree + shortcuts (ux §8). Acceptance: `swift build` clean; Core self-tests (Defaults round-trip, token values, catalog
integrity: unique ids, every tile has a section/icon/hint/features #, synonyms lower-cased) pass.

**WP2 — LayoutKit + RenderKit** (fable). `Sources/{LayoutKit,RenderKit}/**`. Layout analysis (features §2.4) from
PDFKit character bounds and from Vision OCR results: words, lines, paragraphs, columns, headings, lists, tables (ruling
lines + alignment), figures, header/footer exclusion, reading order; `LayoutDocument` serialisable for fixtures.
RenderKit: rasterize, PDF/A (`kCGPDFContextCreatePDFA`) and PDF/X contexts, imposition, colour conversion, output
preview separations. Tests: golden fixtures (10 real-world PDFs: letter, two-column paper, invoice with table, form,
scan) with expected block trees; rendering snapshot checks.

**WP3 — DocumentKit** (careful). `Sources/DocumentKit/**`. NSDocument subclass, open/repair/password flows with the
exact copy (ux §7.4), save policy sheet (ux §7.1), output naming (ux §7.2), versions, undo groups for page operations,
recents, view state in xattrs, document tabs, `ToolResult` application. Tests: naming collisions, save-policy state
machine, undo/redo of page ops, repair path with a damaged fixture.

**WP4 — ViewerKit** (heavy). `Sources/ViewerKit/**`. Main window chrome and toolbar to the metrics of ux §2.1, sidebar
modes (ux §6.3) with the thumbnail collection view (drag reorder, drop files, drag-out file promises, context menu),
PDFView host and display modes, reader mode, read aloud, find bar + results sidebar, page organiser (ux §6.2),
result banner (ux §7.3), welcome window (ux §6.1), window-wide drag & drop (ux §3), Preview's menu tree and
shortcuts (ux §8). Tests: drop-target decisions table, organiser model (reorder/multi-select/insert from second file),
offscreen renders against the mockups' metrics.

**WP5 — ToolsKit** (heavy). `Sources/ToolsKit/**`. The Tools sheet (ux §4: search with synonyms, recently used by
frecency, sections, badges for unavailable engines, keyboard, right-click Add to Toolbar), the panel host with
archetypes A–E and G (ux §5.1–5.2), scope control, live-preview overlay plumbing, progress and error presentation, Tools
menu + toolbar items generated from the catalog, Dock menu. Announces the `ToolProviding` host API for wave C.
Tests: search ranking fixtures ("ocr" → Recognise text, "merge" → Combine files), frecency, archetype rendering
snapshots, provider-coverage check (every catalog tile has one provider).

**WP6 — PagesKit** (medium). `Sources/PagesKit/**`. Tools #18–33 as `ToolProviding` with the panels of ux §5.3
(Combine queue, Split presets, Extract, Rotate/Delete, Crop with white-margin detection, Insert, Number pages, page
labels, Booklet, Resize). Tests: page-op results on fixtures, split naming, blank-page detection, crop box maths.

**WP7 — ConvertKit** (heavy). `Sources/ConvertKit/**`. Converter registry runtime with availability detection
(features §3.2 table), native importers (NSAttributedString/TextKit pagination, WebKit for HTML/EPUB/Markdown, ImageIO,
CSV/TSV, ZIP recursion, EML, own xlsx/pptx/hwpx readers), LibreOffice helper (detect, guarded install from the
official DMG with SHA-256 + signature check, private profile, timeout), app automation via Apple Events with the
"will open briefly" notice, Quick Look fallback; exporters: images (#53), text/HTML/EPUB (#54–55), docx/xlsx/pptx
writers over LayoutKit (#50–52), PDF/A + verifier (#56, #93), PDF/X (#57), data exports (#59). Panels of ux §5.3
(To Word…, To images, For archiving, Images → PDF, Any file → PDF). Tests: each importer against fixtures (no network),
OOXML writers validated by re-reading the zip/XML, PDF/A verifier on known-good/known-bad files, registry ranking.

**WP8 — EditKit** (fable). `Sources/EditKit/**`. Edit text & images (#60–62, #72) on content streams via PDFModelKit
with LayoutKit blocks, font substitution + subsetting (Core Text + own CFF/TrueType subsetter), links (#63), headers &
footers (#64), Bates (#65), watermark/background (#66–67) as tagged XObjects with remove/update, stamps (#68),
optional content (#71), scripts removal (#74), properties/initial view (#124), page transitions (#113), destinations
(#114). Panels per ux §5.3 with live preview. Tests: edit a word and re-extract text; watermark add/remove round-trip;
header tokens; Bates continuation across files.

**WP9 — MarkupKit** (medium/heavy). `Sources/MarkupKit/**`. Preview-identical markup bar (ux §6.4), annotation
tools with generated appearance streams (#76), comments list with replies/status/filters (#77), correction marks (#78),
file/audio attachments (#79), comment summary (#117), XFDF import/export, measure (#15), snapshot (#116). Tests:
annotations open identically in PDFKit after save; XFDF round-trip; measure maths with scale.

**WP10 — FormsKit** (careful). `Sources/FormsKit/**`. Fill (#80: widgets, AutoFill from Contacts, `AF*` emulation for
format/calculate/validate, fill-anywhere), Make a form (#81: detection via LayoutKit, palette, properties, calculations,
tab order, barcodes via Core Image), data import/export, templates (#121). Tests: AF emulation fixtures (sum, number
format, date format) against expected strings; detection recall on form fixtures.

**WP11 — SignKit** (heavy). `Sources/SignKit/**`. Signature library (trackpad/camera/iPhone capture via the Preview-
style flows, Keychain), placement (#82), certificate signing PAdES-B-B with swift-certificates CMS + SecKey over
PDFModelKit placeholders, DocMDP lock, verification + trust store (#83), certificates (#85), request-signatures flow,
package format, return matching, tracker window, seal + audit page (#84). Tests: sign → verify with our verifier and
with `openssl cms -verify` on the extracted CMS; tamper detection; request package round-trip.

**WP12 — ProtectKit** (careful). `Sources/ProtectKit/**`. Password/permissions (#86), remove password (#87), remove
hidden information (#88), certificate encryption (#89), permissions view (#90), security envelope (#122), redaction
(#69) with true content removal (text by glyph bounds, images re-encoded with the area filled, vectors clipped),
rasterize-and-compare verification, pattern library and FOIA/Privacy code presets, flatten (#70). Tests: after
redaction no text extraction, no image pixels and no raw object bytes contain the target; permissions bits
round-trip; envelope opens with the password.

**WP13 — FixKit** (heavy). `Sources/FixKit/**`. Make smaller (#91: three presets with sample-based estimator in < 1 s,
optimizer option set, image downsampling per XObject keeping masks and colour spaces, font unembedding for standard
14, object streams, linearize), OCR (#92: Vision → invisible text layer with per-word positions; clean-up via Core
Image; editable-text option through EditKit), repair (#98), fast web view (#99), fonts (#100), PDF/A check (#93),
print checks (#94), output preview (#95), flatten transparency/convert colours (#96), printer marks/hairlines (#120),
accessibility check + auto-tag + reading order + alt text (#97, #123). Tests: size reduction and visual diff below
threshold on fixtures; OCR layer searchable in PDFKit; checker results on known files.

**WP14 — ScanKit** (medium). `Sources/ScanKit/**`. Continuity Camera import (#101), Image Capture scanners (#102),
photo document detection + perspective correction (#103), clean-up pipeline (#104), the three-step panel (ux §5.3).
Tests: detection + correction on photo fixtures; pipeline idempotence; device-list state mapping with a fake browser.

**WP16 — App target, packaging, end to end** (careful). `Sources/SuperPDF/**`, `Sources/SuperPDFQuickActions/**`,
`Sources/BatchKit/**`, `Sources/SettingsKit/**`, `scripts/**`, `Resources/**`, `.github/**`, `README.md`,
`PRIVACY.md`, `CHANGELOG.md`, `THIRD_PARTY_NOTICES.md`. Launch sequence, module install order, main menu, Dock menu,
URL routes, Info.plist (document types for every input format, usage strings for camera/contacts/automation/
microphone), Quick Actions, App Intents, PDF Services item, Settings panes (ux §6.6), batch runner (#75),
`build-app.sh` (QPDF linked statically; executables; static launch checks), DMG, `release.sh` + updater wiring, CI,
end-to-end self-test (scan fixture → OCR → make smaller → PDF/A → verify; combine → sign → verify; request package →
return → seal).

## Open questions (decided provisionally, revisit with evidence)

1. PDFKit's AES-256 behaviour on macOS 14 for `writeToURL(withOptions:)` — if it writes RC4/AES-128 for some inputs,
   ProtectKit always routes through PDFModelKit (WP12 measures and decides).
2. Whether `PDFDocumentBurnInAnnotationsOption` preserves form-field appearance streams for all widget types; if not,
   FixKit's own flattener via PDFModelKit takes over (WP12).
4. QPDF static build size and build time in CI (WP0b reports; fallback is a pre-built release artifact only).
