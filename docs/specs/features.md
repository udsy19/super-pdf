# Features

Every tool Super PDF ships: Adobe Acrobat's feature set (inventoried statically from the Acrobat DC bundle on the
reference Mac, §0) plus the required list from the brief, each with its behaviour, its plain-language name in the app,
the local implementation approach and the engine that does the work. Nothing here needs an account, a server or the
network except the one-time model and helper downloads in §3.5.

Companion documents: `ux.md` owns how a tool looks and is reached (one tile, one panel, one button); `../ARCHITECTURE.md`
owns which module implements it. "§" references without a file name point into this document.

## 0. Evidence and conventions

| Tag | Meaning |
|---|---|
| **[A]** | Found in the Acrobat DC bundle (`/Applications/Adobe Acrobat DC/Adobe Acrobat.app`): plug-in names, `.strings` labels, tool-center lists, Optimizer presets, Sequences. Read statically; the app was never launched. |
| **[P]** | Found in Preview.app (`/System/Applications/Preview.app`): menu labels, toolbar, strings. Preview is the UI model. |
| **[S]** | Verified against the macOS 26 SDK headers on the reference Mac (`xcrun --show-sdk-path`): the API exists with the stated availability. |
| **[L]** | Verified against the installed LibreOffice 26.2 (`/opt/homebrew/bin/soffice --help`). |
| **[D]** | Product decision taken here. Recorded with the alternative that lost. |

**Naming rule.** Every tool has a plain name that says what happens to the file ("Make smaller"), and a hint line that
says why ("so it's easier to send"). Jargon stays in the search index so people who know Acrobat's names still find the
tool ("Compress", "Optimize", "Reduce file size" all find "Make smaller"). The canonical names live in `ux.md` §4; this
file uses them with Acrobat's name in brackets the first time.

**Non-destructive rule.** A tool never overwrites the open file. Tools that change the whole file (convert, compress,
protect, flatten, PDF/A, redact, OCR) write a new file next to the original with a suffix ("Report (smaller).pdf") and
open it; tools that edit the document (pages, markup, text, forms, headers) edit in place with full undo and macOS
document versions (File › Revert To › Browse All Versions), and the first save after opening asks "Save a copy or
replace?" once per document. `ux.md` §7.

**Engine columns.** `PDFKit` = Apple PDFKit (view, annotations, forms, text, write options) [S]; `Quartz` = Core Graphics
PDF contexts and rendering [S]; `QPDF` = the object-level engine (§3.1); `Vision` = Apple Vision OCR and document
detection [S]; `Office` = the conversion registry (§3.2); `Own` = Swift code in this repository.

**No AI [D].** Super PDF has no AI tools and ships no language model: no assistant, chat, summaries, translation,
question generator or generated text of any kind (§3.4). OCR (#92) and document detection (#103) are Apple Vision tools
like any other. The numbers of the removed tools (#105–#112, #118) stay unused so references elsewhere keep meaning.

## 1. Feature inventory

Counts: 124 numbers in §1 (user-facing tiles or commands; #105–#112 and #118 are retired, §3.4) plus the viewer features of §2. Acrobat's tool apps (59 `.aapp` files), 24 plug-ins, menu strings and settings files were inventoried [A]; §1.12 lists the long tail that the headline tools absorb. The required list from the
brief is marked **(req)**.

### 1.1 Open, view, read

| # | Tool (app name) [Acrobat name] | Behaviour | Approach | Engine |
|---|---|---|---|---|
| 1 | Open a PDF | Open, drag onto window/Dock, Finder "Open With", Quick Look → "Open in Super PDF", `superpdf://` URL. Password prompt if encrypted (§1.8). Damaged files are repaired on open (QPDF recovery) with a notice "This file was damaged; we repaired what we could." | NSDocument + PDFKit; QPDF for recovery | PDFKit, QPDF |
| 2 | Reader (req) [Read mode / Full Screen] | Toolbar and sidebar hide, document centred, page turns by arrow keys/trackpad, optional two-page book layout, night mode (invert colours softly), "Reflow" for text-heavy pages (extracted text reflowed at a chosen size). Exit with Esc. | PDFView display modes; reflow uses extracted text with paragraph detection (§2.4) | PDFKit, Own |
| 3 | Read aloud [Read Out Loud] | Reads the page or selection with the system voice; highlights the sentence being read; speed control. | AVSpeechSynthesizer + PDFSelection per sentence | Own |
| 4 | Find [Find / Advanced Search] | ⌘F bar: live results with page thumbnails, match case, whole word, next/previous, search inside comments and bookmarks, search across the Combine queue. Results list in the sidebar. | PDFDocument.findString + annotation contents | PDFKit |
| 5 | Zoom, fit, rotate view | Zoom in/out/fit page/fit width/actual size, pinch, rotate view (temporary, not saved). | PDFView | PDFKit |
| 6 | Contents (req: bookmarks/outline) [Bookmarks panel] | Sidebar mode showing the document outline as a tree; click to jump; add, rename, nest, delete, reorder by drag; "Make contents from headings" (§1.5 #41). | PDFOutline read/write | PDFKit |
| 7 | Bookmarks (mine) | Personal bookmarks on pages (like Safari), stored in the file as a private outline branch or in app data when the file is read-only. | PDFOutline + app store | PDFKit, Own |
| 8 | Notes list [Comments list] | Sidebar mode listing every comment/annotation with author, date, page, text; filter by type/author; click to jump; mark resolved; reply. | PDFAnnotation enumeration | PDFKit |
| 9 | Attachments [Attachments panel] | Sidebar mode listing embedded files; open, save, add, remove. | QPDF embedded files (EmbeddedFiles name tree) | QPDF |
| 10 | Document info [Document Properties] | Title, author, subject, keywords, created/modified, producer, page size, page count, PDF version, security summary, fonts used (embedded or not), file size. Editable fields. | PDFDocument attributes + QPDF for fonts/version | PDFKit, QPDF |
| 11 | Page layout & thumbnails | Thumbnail sidebar with page numbers and labels; continuous/single/two-page; page labels (roman, etc.) honoured. | PDFThumbnailView replaced by own collection view for drag/drop (ux §5) | PDFKit, Own |
| 12 | Layers [Layers panel] | Show/hide optional content groups (OCGs). | QPDF OCProperties → render with Quartz honoring visibility (re-rendered via content filter) | QPDF, Quartz |
| 13 | Compare files [Compare Files] | Pick two files (or two versions); side-by-side with synchronized scrolling; text differences highlighted (inserted/deleted/changed); visual differences for images and layout; summary "14 changes on 6 pages"; export a comparison report PDF. | Text diff on per-page extracted text with positions (diff-match-patch style), visual diff by rendering both at 150 dpi and comparing tiles with perceptual threshold | PDFKit, Quartz, Own |
| 14 | Magnifier, rulers, grid | Loupe (Preview's Show Magnifier), rulers in pt/mm/in, snap grid for markup. | Own overlay | Own |
| 15 | Measure [Measuring tool] | Distance, perimeter, area; scale calibration ("this line is 10 m"); units pt/in/mm/cm/pica/ft/yd/m/km/mi (Acrobat's list [A]); snap to path endpoints and midpoints; results as annotations with the value. | Own overlay; stored as PDF measurement annotations (Line/Polygon with /Measure dict) | Own, QPDF |
| 16 | Print | Standard print panel with page range, scaling, booklet, "print comments", "print as image". | NSPrintOperation + PDFView | PDFKit |
| 17 | Share (req) | Share sheet (Mail, Messages, AirDrop, Notes…); "Share a copy without my notes" option flattens/strips first. | NSSharingServicePicker | Own |

### 1.2 Organize pages

| # | Tool | Behaviour | Approach | Engine |
|---|---|---|---|---|
| 18 | Combine files (req: Merge) [Combine Files] | Drop files of any supported type into the queue; reorder; per-file page ranges; images become pages; Office files convert on the way in (§3.2); result opens as a new unsaved document "Combined.pdf". Also: drop a file on the thumbnail sidebar to insert it at that position. | PDFDocument page insertion; conversion registry for non-PDFs | PDFKit, Office |
| 19 | Rearrange (req: Organize) [Organize Pages] | Drag thumbnails in the sidebar or the page grid (ux §6); multi-select; keyboard move. | Own thumbnail grid; PDFDocument move | PDFKit, Own |
| 20 | Rotate pages (req) | Rotate selected pages 90° either way; "all pages"; saved rotation (page /Rotate). | PDFPage.rotation | PDFKit |
| 21 | Delete pages (req) | Delete selection; undoable; the last page cannot be deleted (notice). | PDFDocument.removePage | PDFKit |
| 22 | Extract pages (req) | Save selected pages or a range as a new PDF; option "remove them from this file"; drag thumbnails to Finder to extract. | New PDFDocument from pages; NSFilePromiseProvider for drag-out | PDFKit, Own |
| 23 | Split (req) [Split] | Split by: every N pages, file size, top-level outline entries, page ranges, blank-page separators (scan batches). Output folder with naming pattern. | PDFDocument slicing; blank detection by ink coverage | PDFKit, Own |
| 24 | Insert pages [Insert from file / Insert blank page / Insert from clipboard / Insert from scanner] | Insert blank (same size as neighbour), from file (any supported type), from clipboard image, from scanner (§1.10). | PDFPage(image:) and insertion | PDFKit, Office |
| 25 | Replace pages [Replace Pages] | Replace a range with pages from another file, keeping links/comments where positions match. | Page swap preserving annotations by copy | PDFKit |
| 26 | Duplicate pages | Duplicate selection in place. | PDFPage.copy | PDFKit |
| 27 | Reverse order | Reverse all pages (scanned backwards). | Reorder | PDFKit |
| 28 | Crop (req) [Crop Pages] | Drag a crop box on the page; apply to this page / range / all; "Remove white margins" auto; "Undo crop" restores (crop sets /CropBox, media stays). | PDFPage.setBounds(forBox: .cropBox); white-margin detection by render | PDFKit, Own |
| 29 | Resize pages / Set page boxes [Set Page Boxes] | Change page size (A4/Letter/custom) by scaling or padding; media/crop/trim/bleed/art boxes for print. | Transform page content via Quartz re-draw or box edit via QPDF | Quartz, QPDF |
| 30 | Number pages (req) [Add Page Numbers] | Position (6 spots), start number, format ("Page 1 of 12", "1", "– 1 –", roman), font/size, range, skip first N, preview live. | Header/footer engine (§1.5 #37) | Own, Quartz |
| 31 | Page labels [Number Pages (labels)] | Set logical labels (i, ii, 1, 2, A-1) shown in the sidebar and thumbnails. | QPDF /PageLabels | QPDF |
| 32 | Booklet / N-up imposition [Print production: Booklet, Multiple pages per sheet] | Make a booklet (2-up, saddle-stitch order) or N-up sheet; output a new PDF. | Quartz re-draw pages into new layout | Quartz |
| 33 | Thumbnails → contact sheet | Export a contact sheet image/PDF of all pages. | Quartz | Quartz |

### 1.3 Convert to PDF

| # | Tool | Behaviour | Approach | Engine |
|---|---|---|---|---|
| 34 | Images → PDF (req: JPG to PDF) | Drop JPG/PNG/HEIC/TIFF/GIF/BMP/WebP/RAW; one page per image; paper size "fit image" or A4/Letter with margins; order by drag; multi-page TIFF expands. | NSImage/ImageIO → PDFPage(image:) | PDFKit, ImageIO |
| 35 | Word → PDF (req: .doc/.docx) | Native: NSAttributedString(.docx/.doc) → paginated with TextKit → PDF (good for text documents; loses complex layout, tracked changes shown as final). Better: LibreOffice helper or Microsoft Word on the Mac via automation (§3.2 ranking). The panel shows which engine will be used, and "Get LibreOffice" when LibreOffice would do better and isn't on the Mac. | Registry: native → LibreOffice → Word automation | Office |
| 36 | Excel → PDF (req: .xls/.xlsx) | Native: own OOXML reader for `.xlsx` (sheets, cells, merged cells, column widths, number formats, basic styles) rendered as tables; `.xls` and charts need LibreOffice/Excel automation. | Registry: native xlsx → LibreOffice → Excel automation | Office, Own |
| 37 | PowerPoint → PDF (req: .ppt/.pptx) | Native: own OOXML reader for `.pptx` (slides, text boxes, images, basic shapes, backgrounds); animations ignored; `.ppt` and complex themes need LibreOffice/PowerPoint automation. | Registry: native pptx → LibreOffice → PowerPoint automation | Office, Own |
| 38 | ODT/ODS/ODP → PDF (req) | `.odt` native via NSAttributedString(.odt) [S]; `.ods`/`.odp` via LibreOffice (its home format, perfect fidelity). | Registry | Office |
| 39 | Pages/Numbers/Keynote → PDF (req: iWork) | If the iWork app is installed: automation export ("Pages exports your file as PDF" — the app opens briefly). Otherwise: the preview inside the package (`preview.jpg`/`QuickLook/Preview.pdf`, often first page only) with a clear notice; LibreOffice has no iWork import. | Registry: iWork automation → embedded preview | Office |
| 40 | Text/RTF/RTFD → PDF (req: TXT/RTF) | NSAttributedString → paginate (font, size, margins options; monospaced for code). | TextKit | Own |
| 41 | HTML / web page → PDF (req: HTML) | Local `.html`/`.htm`/`.webarchive` and pasted URLs (user-initiated fetch): WKWebView renders, `createPDF` or print-to-PDF with paper size and "fit width". | WebKit | WebKit |
| 42 | EPUB → PDF (req) | Unzip, read OPF spine, render chapters with WebKit to PDF, merge with chapter outline. | WebKit + own EPUB reader | WebKit, Own |
| 43 | CSV/TSV → PDF (req) | Parse (delimiter/encoding detection), render as table with header row, repeated on each page, landscape auto when wide. | Own table layout | Own |
| 44 | ZIP → PDF (req) | Unzip, convert each supported file, combine in name order with a bookmark per file; unsupported files listed in the notice. | Registry + Combine | Office, Own |
| 45 | HWP → PDF (req: Hangul) | LibreOffice helper (HWP import filter for HWP 3/5 binary); `.hwpx` (zip+XML) via own basic reader (paragraphs, tables, images) if LibreOffice is absent. | Registry: LibreOffice → own hwpx | Office |
| 46 | Markdown → PDF | Render with the built-in Markdown→HTML, then WebKit. | WebKit | WebKit |
| 47 | Anything → PDF (req: PDF Converter) | The catch-all tile: drop any file; the registry picks the best engine (§3.2 table); unknown types fall back to Quick Look (QLThumbnailGenerator for images at full size, page one only) with a notice. Also available as a Finder Quick Action and Dock-icon drop. | Registry | Office |
| 48 | Print to Super PDF | A PDF Services item ("Save to Super PDF") in every app's print dialog opens the printed PDF here. | `~/Library/PDF Services` workflow installed on first run (asks) | Own |
| 49 | Clipboard → PDF | New document from clipboard text/image. | TextKit / ImageIO | Own |

### 1.4 Convert from PDF

| # | Tool | Behaviour | Approach | Engine |
|---|---|---|---|---|
| 50 | PDF → Word (req) [Export PDF to Word] | Own `.docx` writer: paragraphs with runs (font, size, bold/italic, colour), headings by size, lists, tables (from ruling lines and text alignment), images placed inline or anchored; page breaks preserved; "Keep page layout" mode uses text boxes positioned per page for forms/brochures; scanned pages go through OCR first (asks). Also `.rtf` via NSAttributedString. | Layout analysis (§2.4) + OOXML writer | Own, PDFKit, Vision |
| 51 | PDF → Excel (req) | Own `.xlsx` writer: tables detected per page (ruling lines, column alignment, repeated headers), one sheet per table or per page; numbers typed as numbers; "all text as one sheet" fallback. `.csv` export too. | Table detection + OOXML writer | Own |
| 52 | PDF → PowerPoint (req) | Own `.pptx` writer: one slide per page, page image as background plus editable text boxes at their positions (so text is editable, look preserved); "Text only" mode builds title/body placeholders. | Quartz render + layout analysis + OOXML writer | Own, Quartz |
| 53 | PDF → JPG/PNG (req) | Pages → images at 72/150/300/600 dpi or custom; PNG (lossless, transparency), JPEG (quality), TIFF, HEIC, WebP; one file per page or a single multi-page TIFF; "export images only" pulls the embedded images out at native resolution. | Quartz rendering; QPDF image stream extraction | Quartz, QPDF |
| 54 | PDF → Text | Plain text with layout (columns kept) or reading order; per-page separators optional. | Text extraction (§2.4) | PDFKit, Own |
| 55 | PDF → HTML / EPUB | Reflowed HTML with headings, paragraphs, images; EPUB packages the HTML with a chapter per outline entry. | Layout analysis + own writers | Own |
| 56 | PDF → PDF/A (req) [Save as PDF/A] | Conformance PDF/A-1b, 2b, 2u, 3b (3b keeps attachments), and the accessible "a" levels (1a/2a/3a, which require tags: offered when the file is tagged or after "Check accessibility" has tagged it); Acrobat lists the same families plus PDF/E, PDF/VT and PDF/UA [A]: PDF/UA is produced by the accessibility fixer (#97), PDF/E and PDF/VT are out of scope; embeds fonts (re-renders text using available fonts when a font is not embeddable → notice), converts colour to sRGB with OutputIntent, removes JavaScript/encryption/transparency where the level forbids it, writes XMP `pdfaid`; then verifies with the built-in checker (§1.9 #93) and shows the result. A file whose own pages already pass the check is kept as it is (only scripts, encryption, forbidden attachments and hidden notes go; OutputIntent and XMP are added), so a recognised scan's text layer and a tagged file's tags survive; the "a" levels of a tagged file always keep its pages. | QPDF for the kept-pages path, XMP, outline and attachments; Quartz `kCGPDFContextCreatePDFA` [S, macOS 11+] for re-rendered output; own verifier | Quartz, QPDF, Own |
| 57 | PDF → PDF/X [Save as PDF/X] | PDF/X-1a/X-4 basics: OutputIntent (`kCGPDFContextOutputIntents` [S]), trim/bleed boxes, no RGB in X-1a (warns and converts). | Quartz, QPDF | Quartz, QPDF |
| 58 | PDF → images → PDF ("Print as image") | Rasterize every page (fixes rendering problems, removes everything but pixels). Used by Flatten "fully" and by Redact as a belt-and-braces option. | Quartz | Quartz |
| 59 | Export comments / form data | Comments as FDF/XFDF/CSV/PDF summary; form data as FDF/XFDF/CSV/JSON. | QPDF (XFDF writer own) | Own, QPDF |

### 1.5 Edit

| # | Tool | Behaviour | Approach | Engine |
|---|---|---|---|---|
| 60 | Edit text (req: Edit PDF) [Edit Text & Images] | Click a paragraph → it becomes an editable block (font, size, colour, alignment); retype, delete, add lines; reflow within the block; missing fonts substituted with a notice; new text boxes anywhere. Changes rewrite the page content stream for that block (other content untouched). | Content-stream parsing into text blocks (§2.4), re-serialization with QPDF; font subsetting for new glyphs via Core Text + own CFF/TrueType subsetter | QPDF, Own |
| 61 | Edit images (req) | Select an image: move, resize, rotate, crop, replace, delete, flip; "Edit in…" round-trip through the image editor the user picks (Preview, Photos, Pixelmator). | XObject edit in content stream + image stream replace | QPDF, Own |
| 62 | Add text box / Add image | Place text or image objects (not annotations) on a page. | Content-stream append | QPDF |
| 63 | Links [Add/Edit Link] | Draw a link rectangle → go to page / open URL / open file / run action; auto-detect URLs and page references ("Create links from URLs"). | PDFAnnotation link + PDFAction | PDFKit |
| 64 | Headers & footers [Add Header & Footer] | Left/centre/right header and footer text with tokens: page number, page count, date, title, author, custom; font, size, colour, margins, range, "shrink page to make room"; live preview; saved presets; remove/update existing (ours are tagged so they can be replaced). | Own layout drawn into content streams (prepend/append) with a marker; QPDF | Own, QPDF |
| 65 | Bates numbering [Bates Numbering] | Prefix/suffix, start number, digits (6 default), position, apply to many files (queue), per-file continuation, remove Bates. | Header/footer engine with document-sequence counter | Own, QPDF |
| 66 | Watermark (req) [Add Watermark] | Text or image/PDF watermark; opacity, rotation, scale, position, behind/over content, page range, "only when printing" / "only on screen"; live preview; remove watermark (ours are tagged; foreign ones can be removed when they are separate XObjects). | Watermark XObject via QPDF (Form XObject, overlay/underlay) | QPDF, Quartz |
| 67 | Background [Add Background] | Colour or image/PDF background, opacity, scale, range. | Underlay XObject | QPDF |
| 68 | Stamps [Stamp tool] | Standard stamps (Approved, Draft, Confidential, Final, Received, Sign here, …), dynamic stamps (name/date/time), custom from image/PDF, stamp palette with favourites. | PDFAnnotation stamp with appearance stream | PDFKit, QPDF |
| 69 | Redact (req: Black out) [Redact / Mark for Redaction / Apply Redactions] | Draw boxes or select text → marked (red outline); "Find and black out" by text, pattern (Acrobat's set [A]: phone numbers, credit cards, social security numbers, email addresses, dates, plus IBANs, UK NI and Indian Aadhaar numbers, custom regular expression; whole/partial word marking) or list of words; page ranges; then **Apply** removes text, image pixels and vector content under the boxes for real (not just a black box), optional overlay text ("REDACTED" or an exemption code; Acrobat's U.S. FOIA (b)(1)–(b)(9) and Privacy Act code sets ship as presets and custom sets can be added [A]), outline/fill colours, and offers "Also remove hidden information" (§1.8 #85); always writes a new file. | Content-stream editing: text objects clipped/removed by glyph bounds, images re-encoded with the area filled, paths clipped; verified by rasterize-compare; QPDF | QPDF, Own, Vision (scanned pages: OCR words) |
| 70 | Flatten (req) [Flatten] | Burn annotations and form fields into page content; options: comments, form fields, both; "fully flatten to image". | PDFKit `PDFDocumentBurnInAnnotationsOption` [S, macOS 13] for the standard case; Quartz rasterize for "fully"; QPDF to drop AcroForm | PDFKit, Quartz, QPDF |
| 71 | Optional content | Hide/show layer groups; "flatten layers" removes hidden content. | QPDF | QPDF |
| 72 | Find & replace text | Replace a word everywhere (same font, fits or warns). | Edit-text engine | QPDF, Own |
| 73 | Spelling | Spell check in comments and form fields; edit-text blocks use the system checker. | NSSpellChecker | Own |
| 74 | Actions / JavaScript [Document JavaScript / Set Page Action] | View and remove document JavaScript and actions ("This file has scripts. Remove them?"); Super PDF never runs PDF JavaScript [D: security, Acrobat's JS engine is out of scope]. Form calculations are supported natively (§1.7 #80). | QPDF | QPDF |
| 75 | Batch ("Do this to many files") [Action Wizard] | Any file-level tool can run on a folder/drop of files: pick tool(s) → order → output folder; progress list; recipes saved as "Routines" (e.g. "OCR, compress, PDF/A"). Also Finder Quick Actions and a Shortcuts app action per tool (App Intents). | Own pipeline over the tool registry | Own |

### 1.6 Mark up and comment

| # | Tool | Behaviour | Approach | Engine |
|---|---|---|---|---|
| 76 | Annotator (req) [Comment toolbar] | Preview-style markup bar: Highlight / Underline / Strikethrough (text), Sticky note, Text box, Callout, Pen (draw), Highlighter pen, Shapes (rectangle, oval, line, arrow, polygon, cloud), Eraser, Signature (§1.7), Colour/line/opacity/font popovers. Author name from Contacts "Me" card (editable). | PDFAnnotation subtypes [S]: Highlight/Underline/StrikeOut/Text/FreeText/Ink/Square/Circle/Line/Polygon; appearance streams generated by Own for fidelity in other readers | PDFKit, Own |
| 77 | Comments review [Comments list, replies, status] | Replies, status (Accepted/Rejected/Completed), "Resolve", filter, sort, summarise comments to a PDF, import/export comments (XFDF), "Show only my comments". | Popup/IRT annotations; XFDF | PDFKit, Own |
| 78 | Text correction marks [Insert text / Replace text / Delete text marks] | Proofreading marks: insert caret with text, replace (strike + caret), delete (strike) — exported as standard annotations other apps show. | Caret/StrikeOut annotations with IRT | PDFKit |
| 79 | Attach file / audio comment [Attach File / Record Audio] | Attach a file to a page as a paper-clip annotation; record a voice note (microphone) as a sound annotation. | FileAttachment / Sound annotations via QPDF (PDFKit has no public file-attachment annotation writer) | QPDF, Own |

### 1.7 Sign and forms

| # | Tool | Behaviour | Approach | Engine |
|---|---|---|---|---|
| 80 | Fill form (req: Form filler) [Fill & Sign] | Form fields are detected and highlighted; tab order; auto-fill from the user's Contacts card and from previous fills (local); checkboxes/radios/choices/dates; calculation and format scripts of the common AcroForm kinds (sum, product, average, minimum, maximum, simplified field notation; Number/Percentage/Date/Time/Special/Custom formats [A]; simple JavaScript `AFNumber_Format`, `AFSimple_Calculate` emulated natively) [D: emulate the Adobe `AF*` helpers, not a JS engine]; for pages without fields, "Fill anywhere" places text boxes and check marks (Preview's form-filling and Acrobat's Fill & Sign). XFA forms: shown as static with a notice (Acrobat-only format). | PDFAnnotation widgets; own AF emulation | PDFKit, Own |
| 81 | Make a form (req: Prepare form) [Prepare Form] | Auto-detect fields from underlines, boxes and labels ("Name: ____", "☐"), then add/move/resize fields: text, multiline, number, date, checkbox, radio group, dropdown, list, button, signature field, image field; properties (name, tooltip, required, read-only, default value, format, calculation across fields, validation range, actions: show/hide a field, go to a page, open a link, reset, submit by email); align/distribute/match size; duplicate across pages; barcode field (QR, PDF417, Aztec via Core Image generators; Data Matrix not available) [A]; tab order by drag; "Distribute" exports a fillable copy and tracks returns (§1.7 #84). | Field detection by layout analysis; AcroForm + widgets via QPDF; PDFKit for display | Own, QPDF, PDFKit |
| 82 | Sign (req: Sign PDF) [Fill & Sign: Sign / Certificates: Digitally sign] | Two levels, both one tile: **Add my signature** (draw with trackpad, type in a script font, photograph with iPhone/camera, import image; saved in the Keychain-protected signature library like Preview; place, resize; initials too) and **Sign with a certificate** (PAdES-B-B digital signature with a certificate from Keychain or one the app creates for the user, visible appearance with name/date/reason/location, lock the document after signing optional, long-term validation off by default because it needs a timestamp server). | Signature appearance via Stamp/Widget; digital signature: PKCS#7/CMS detached over `/ByteRange` with `swift-certificates` CMS and SecKey; QPDF writes the /Sig dictionary and placeholder, incremental update preserved | Own, QPDF, Security |
| 83 | Verify signatures [Signature panel] | Signature panel: who signed, when, valid/modified since, certificate chain and trust (system trust + user-trusted certificates list), "document was changed after signing" detection by ByteRange and incremental-update analysis. | CMS verify with swift-certificates; QPDF incremental parse | Own, QPDF |
| 84 | Request signatures (req) [Request E-signatures / Send for signature] | **Local flow, no server** [D]: (1) choose who signs (names/emails from Contacts) and place their fields (signature, initials, date, name, checkbox) with a colour per signer; (2) "Send" builds a *signing package*: the PDF with the fields, each assigned to a signer, plus an embedded `request.json` (request id, signer list, order, created date) and a one-page cover explaining "Open in any PDF app, sign in the highlighted spots, send it back"; it is sent through Mail/Messages/AirDrop with a prefilled message; (3) returned files are recognised by request id when opened or dropped on the "Signatures I asked for" list, signatures merged into the master (incremental updates appended or, for files signed by other apps, the returned copy becomes the master once every signer is done); (4) the tracker shows Waiting / Returned / Done per signer with "Remind" (prefilled email) and "Sign in person" (hand the Mac over, field unlocked for that signer); (5) when everyone has signed, a final certified copy is sealed with the sender's certificate and an audit page is appended. Everything lives in `~/Library/Application Support/Super PDF/Requests/`. The alternative (hosting a share link) was rejected: it needs a server. | Own request store, fields via Make a form, sealing via Sign with certificate | Own, QPDF |
| 85 | Certificates | Create a personal signing certificate (self-signed X.509, 10 years, stored in the login Keychain), import `.p12`, export the public certificate to share with people who need to verify, trust a certificate someone sent, see the list. | swift-certificates + Security.framework | Own, Security |

### 1.8 Protect

| # | Tool | Behaviour | Approach | Engine |
|---|---|---|---|---|
| 86 | Protect with a password (req) [Protect / Encrypt with Password] | Password to open and/or password to change; permissions checklist in plain words ("Allow printing" with Low resolution / High resolution, "Allow copying text", "Allow filling forms and signing", "Allow commenting", "Allow page changes" (insert/delete/rotate), "Allow screen readers" always on) mapping to Acrobat's Printing Allowed / Changes Allowed matrix [A]; AES-256 (R6) by default, AES-128 under More options for old readers; "Encrypt everything except metadata" and "Only attachments" (security envelope, §1.12 #122) under More options; strength meter; "I'll remember it" warning. Writes a new file. | PDFKit write options (`PDFDocumentOwnerPasswordOption`, `UserPasswordOption`, `AccessPermissionsOption` [S]) — PDFKit writes AES-256 on macOS 14; QPDF as the fallback writer with explicit R6 | PDFKit, QPDF |
| 87 | Remove password (req: Unlock) | Enter the password once → saves an unprotected copy; also "remove restrictions" when only an owner password limits printing/copying and the user knows it (we never crack passwords). | Open with password → write without encryption | PDFKit, QPDF |
| 88 | Remove hidden information [Sanitize / Remove Hidden Information] | Lists and removes: metadata, XMP, comments, form data, hidden text (invisible/OCR layer optional), hidden layers, embedded files, bookmarks, links, JavaScript, deleted/obscured content (unreferenced objects), thumbnails, overlapping objects under images. Always a new file. | QPDF object walk | QPDF |
| 89 | Encrypt with certificate [Certificate Security] | Public-key encryption for named recipients (their certificates); recipient opens with their private key. | Own PKCS#7 envelope + QPDF `/Filter /Adobe.PubSec` | Own, QPDF |
| 90 | Permissions view | Shows what the current file allows and whether Super PDF is honouring an owner restriction ("This file doesn't allow printing"). | PDFDocument.accessPermissions [S] | PDFKit |

### 1.9 Fix, check and optimise

| # | Tool | Behaviour | Approach | Engine |
|---|---|---|---|---|
| 91 | Make smaller (req: Compress) [Compress PDF / PDF Optimizer / Reduce File Size] | Acrobat offers three levels (large/medium/small) [A]; we show three sizes as a before/after estimate ("Email: 1.2 MB", "Good: 2.8 MB", "Best quality: 5.1 MB") computed by trial on a page sample; details disclosure for Acrobat's Optimizer settings: image downsampling (dpi per colour/grey/mono), JPEG quality, remove embedded thumbnails, unembed standard fonts, discard comments/forms/JavaScript/metadata/attachments, flatten layers, remove unused objects, compress object streams, linearize ("Fast web view"), discard embedded thumbnails/search index/alternate images/private application data, convert LZW to Flate, discard invalid bookmarks and links, flatten form fields and layers (Acrobat's Optimizer panels Images / Fonts / Transparency / Discard Objects / Discard User Data / Clean Up [A]); "Audit space usage" pie (images, fonts, content, structure, attachments) under More options. Result toast with the saved percentage. | QPDF: object streams, stream recompression, unused-object removal, linearize; image downsampling via ImageIO re-encode per XObject (keeps masks, CMYK via ColorSync); font unembedding for the 14 standard fonts; PDFKit's `SaveImagesAsJPEG`/`OptimizeImagesForScreen` [S, 13.4] as the fast path for "Email" | QPDF, ImageIO, PDFKit |
| 92 | Recognise text (req: OCR) [Scan & OCR / Recognize Text] | Detects pages without text; runs OCR (auto language, 20+ languages via Vision, user-selectable), writes an invisible text layer aligned to the words so search/copy/select work; "Editable text" option replaces the image with real text for clean scans (Edit-text engine); deskew and despeckle before OCR for scans; progress per page; result "Recognised 24 pages · 2 pages had no text". | Vision `VNRecognizeTextRequest` (accurate) [S] → invisible text (render mode 3) with per-word positions via QPDF; PDFKit's `PDFDocumentSaveTextFromOCROption` [S, 13] kept as a one-line fallback | Vision, QPDF, PDFKit |
| 93 | Check PDF/A [Preflight: verify PDF/A] | Validates the file against the chosen PDF/A level (syntax, fonts embedded, colour, XMP, forbidden features) and lists problems with page references; "Fix" runs #56. | Own verifier over QPDF | QPDF, Own |
| 94 | Check for problems [Preflight (basics)] | Print-production checks: fonts not embedded, images under N dpi, RGB on a CMYK job, transparency, page boxes inconsistent, hairlines, overprint, spot colours, PDF version, file size; report with page links. | QPDF + Quartz analysis | QPDF, Quartz, Own |
| 95 | Output preview [Output Preview (basics)] | Show separations (C, M, Y, K, spot) by rendering with the other components muted, total ink coverage warning, simulate paper white; display-only. | Quartz render with colour transforms via ColorSync | Quartz, Own |
| 96 | Flatten transparency / Convert colours [Flattener Preview / Convert Colors] | Rasterize transparent regions at a chosen dpi; convert document colours to sRGB/Gray/a CMYK profile with an OutputIntent. | Quartz re-render with ColorSync | Quartz |
| 97 | Check accessibility (req: accessibility check/tags) [Accessibility Checker / Make Accessible / Reading Order] | Runs the checks (title, language, tags present, reading order, alt text on images, table headers, heading structure, colour contrast, form field labels, bookmarks for >20 pages); "Fix for me" sets title/language, auto-tags with layout analysis (headings, paragraphs, lists, tables, figures), asks for alt text per image (a "Describe this image" field), reading-order editor by dragging numbered regions; tags tree view. | QPDF structure tree (StructTreeRoot, marked content ids inserted into content streams), layout analysis (§2.4) | QPDF, Own |
| 98 | Repair | Rebuild cross-reference, recover objects, fix broken streams; reports what was fixed. | QPDF recovery mode | QPDF |
| 99 | Fast web view [Linearize] | Rewrite as linearized for page-at-a-time loading. | QPDF | QPDF |
| 100 | Fonts | Embed all fonts available on the Mac that the file references but did not embed (subset); list fonts. | Core Text + own subsetter + QPDF | Own, QPDF |

### 1.10 Scan

| # | Tool | Behaviour | Approach | Engine |
|---|---|---|---|---|
| 101 | Scan with iPhone or iPad (req: Scanner) | Continuity Camera "Scan Documents": the phone's document camera captures, straightens and returns PDF pages into the open document or a new one. Requires an iPhone signed into the same Apple ID nearby (the system shows which). | AppKit Continuity Camera menu item (`NSMenuItemImportFromDeviceIdentifier` [S, 10.14]) and `NSServicesMenuRequestor` for the returned PDF/image data | AppKit |
| 102 | Scan with a scanner | Flatbed/ADF scanners via Image Capture: pick device, colour/grey/mono, dpi, duplex, size; each sheet becomes a page; auto-deskew, crop and "whiten background" post-processing; "Scan more" keeps adding. | ImageCaptureCore `ICScannerDevice` + ImageKit `IKScannerDeviceView` [S] | ImageCaptureCore, ImageKit |
| 103 | Scan with the Mac's camera / from a photo | Point a photo (or the built-in camera, lower quality) at a document: Vision finds the document's corners, perspective-corrects, enhances. | Vision `VNDetectDocumentSegmentationRequest` [S] + Core Image perspective correction | Vision, Core Image |
| 104 | Clean up a scan | Deskew, remove black borders, despeckle, whiten, auto-rotate by text orientation, split facing pages, reorder duplex scans. | Core Image + Vision orientation | Core Image, Vision |

### 1.11 (Retired: AI tools)

Summarise (#105), Chat with this PDF (#106), the AI assistant (#107), Translate (#108), Make questions (#109), Explain /
rewrite (#110), Suggest alt text (#111) and Name this file (#112) are not built: Super PDF has no AI (§3.4).

### 1.12 The long tail (Acrobat features absorbed into the tools above or small on their own)

| # | Tool | Behaviour | Approach | Engine |
|---|---|---|---|---|
| 113 | Page transitions | Slideshow transitions per page (Acrobat "Page Transitions") used by Slideshow/Full Screen. | QPDF `/Trans`; our slideshow honours them | QPDF, Own |
| 114 | Named destinations | View, add, rename destinations used by links (Acrobat "Destinations" pane); inside the Links panel. | QPDF name tree | QPDF |
| 115 | Search a folder | "Search in…" across a folder of PDFs with a local full-text index (Acrobat "Full Text Index with Catalog" / Advanced Search across local documents); results grouped by file. | SQLite FTS5 index per chosen folder, refreshed on open | Own |
| 116 | Snapshot | Copy an area as an image (Acrobat "Take a Snapshot", Preview's Rectangular Selection + Copy). | PDFView selection render | PDFKit |
| 117 | Comment summary | "Summarise comments to PDF…" with connector lines or sequence numbers, source + summary pages or summary only, font size (Acrobat's options [A]). | Own renderer | Quartz |
| 119 | Web page → PDF with linked pages | "Also include linked pages (1–2 levels, same site)" in Web page → PDF, with a bookmark per page (Acrobat "Create PDF from Web Page", levels, stay on same server). User-initiated fetch only. | WebKit crawl with limits | WebKit |
| 120 | Printer marks and hairlines | Add trim/bleed/registration marks and page information; thicken hairlines below a threshold (Acrobat Print Production). | Quartz overlay; content-stream line-width rewrite | Quartz, QPDF |
| 121 | New from template | Blank, Letter, Invoice, Meeting notes, Sign-in sheet, Grid paper — simple built-in PDF templates with form fields (Acrobat "Create from template"). | Bundled PDFs | Own |
| 122 | Security envelope | Wrap files in an encrypted PDF "envelope" with a cover page, for sending attachments safely (Acrobat "Create Security Envelope"). | Attachments + password/certificate encryption | QPDF |
| 123 | Reading options | Reading order override, "Read whole document / current page", screen-reader hints, high-contrast page colours (Acrobat Accessibility Setup Assistant / Reading Options). | PDFView + own | Own |
| 124 | Document properties: initial view, custom fields | Set how the file opens (page, zoom, layout, sidebar), custom metadata fields, XMP view (Acrobat Document Properties tabs Description / Security / Fonts / Initial View / Custom / Advanced). | QPDF `/OpenAction`, `/PageMode`, `/Info`, XMP | QPDF |

## 2. Viewer and document features (always on)

### 2.1 Window and navigation
Single window per document (tabs supported: Window › Merge All Windows, like Preview), thumbnail sidebar, Contents,
Notes, Attachments, Search sidebars; page navigation (Go menu: next/previous/first/last/go to page), back/forward
history, continuous scroll, single page, two pages, book mode, fit modes, full screen, slideshow (Preview's View menu
[P]). Per-document view state remembered. Dark mode follows the system; the page itself can be inverted in Reader.

### 2.2 Drag and drop (ux §3)
- Files onto the window, the sidebar, the Dock icon, the Combine queue, the Welcome window: PDFs open or insert, other
  types convert then open or insert.
- Thumbnails within the sidebar or page grid: reorder; to another window's sidebar: copy pages; to Finder: extract.
- Images onto a page: placed as an image object (Edit) or stamp (Markup), the drop target shows which.
- Text onto a page: new text box.

### 2.3 Undo, versions, autosave
NSDocument with autosave-in-place off by default for foreign files (`ux.md` §7): first save asks "Save a copy" (default)
or "Replace the original". Every change is on the undo stack, including page operations and tool runs that edit in
place. Document versions are browsable. Tools that write new files leave the original untouched by construction.

### 2.4 Text and layout analysis (shared engine)
PDFKit provides characters with bounds; the layout engine groups them into words, lines, paragraphs, columns, headings
(size/weight), lists (bullet glyphs and indents), tables (ruling lines from path operators and alignment grids),
figures (image XObjects and vector clusters) and reading order (column-aware, top-left to bottom-right with header/
footer exclusion). Scanned pages go through Vision first. This engine feeds Edit text, PDF → Word/Excel/PowerPoint/
HTML/EPUB, Reflow, Compare, auto-tagging and form field detection. It is one module (`LayoutKit` in
`ARCHITECTURE.md`).

### 2.5 Spotlight, Quick Look, Services, Shortcuts
Spotlight importer not needed (macOS indexes PDFs). A Quick Look extension is not needed (system). Finder Quick
Actions: "Combine in Super PDF", "Make smaller", "Convert to PDF", "Recognise text". Shortcuts/App Intents: one action
per file-level tool. Services menu: "Open selection as PDF".

### 2.6 Accessibility of the app itself
Full VoiceOver labels, keyboard access to every tool (Tools sheet is a focusable grid; every panel has a default
button), Dynamic Type-like text size setting in Settings, reduced motion honoured, high-contrast outlines.

## 3. Engines and decisions

### 3.1 PDF object engine: QPDF [D]

PDFKit and Quartz cover viewing, annotations, forms display, text, rendering, encryption on write, PDF/A output and
flattening. They do not expose the PDF object model, which Edit text, redaction, headers/footers, Bates, watermarks,
page labels, attachments, hidden-information removal, structure tags, linearization, image downsampling, digital
signatures and repair all need.

| Option | Verdict |
|---|---|
| Own Swift PDF parser/writer | Rejected for v1: a robust parser (xref streams, object streams, damaged files, all encryption revisions, all filters) is months of work before the first feature; revisit if QPDF's build becomes a burden. |
| MuPDF | AGPL. Rejected (licence). |
| PDFium | BSD, but a large C++ tree with a GN/Ninja build and Skia; heavy for CLT-only builds. Rejected. |
| PDFBox (Java) / pdf-lib (JS) | Not native. Rejected. |
| **QPDF 12** (Apache-2.0, C++17, deps zlib + libjpeg) | **Chosen.** Mature object model, content-stream tokenizer (`QPDFPageObjectHelper`), overlay/underlay, page ops, linearization, AES-256 encryption, recovery of damaged files, JSON view of objects, object-stream/stream recompression. Built once by `scripts/build-qpdf.sh` (CMake from Homebrew, static with libjpeg-turbo and system zlib) into an xcframework published on this repository's GitHub Releases and pinned as a `binaryTarget` with checksum in `Package.swift`, exactly as Super Flow pins llama.cpp. A Swift wrapper module (`PDFModelKit`) exposes typed operations; no C++ leaks past it. |

### 3.2 Office and other conversions: a ranked registry [D]

Each (input type → output type) has an ordered list of converters. The first that is available on this Mac runs; the
panel shows which one will be used in one line ("Converted by the built-in converter" / "Converted by LibreOffice" /
"Pages will open briefly to export this file") and offers the better engine when one can be installed.

| Input → PDF | 1st: built in | 2nd: LibreOffice helper | 3rd: the app on this Mac (automation) | Notes |
|---|---|---|---|---|
| `.docx`, `.doc`, `.odt`, `.rtf`, `.rtfd`, `.txt`, `.html`, `.webarchive`, `.wordml` | NSAttributedString import [S: `textutil` lists these] + TextKit pagination: good for letters, reports, theses; loses text boxes, floating images, footnotes layout, tracked changes | High fidelity | Word (`.docx/.doc`) via Apple Events "save as PDF" | `.html` uses WebKit instead of TextKit (#41) |
| `.xlsx` | Own OOXML reader → table layout (sheets, merged cells, widths, formats, basic styles; no charts) | High fidelity, charts | Excel | — |
| `.xls` | — | Yes | Excel | Binary BIFF not worth a native reader |
| `.pptx` | Own OOXML reader (text, images, basic shapes, backgrounds; no animations/SmartArt) | High fidelity | PowerPoint/Keynote | — |
| `.ppt` | — | Yes | PowerPoint | — |
| `.ods`, `.odp` | — | Yes (native format) | — | NSAttributedString has no spreadsheet/presentation import |
| `.pages`, `.numbers`, `.key` | Embedded preview (first page or full QuickLook PDF when present) with a notice | — (no import filter) | Pages/Numbers/Keynote export (the usual route; the app opens briefly) | iWork apps are free on every Mac |
| `.hwp` | — | Yes (Hangul import filter) | — | `.hwpx` has an own basic reader |
| `.epub` | WebKit chapter render | Yes (Writer import) | — | — |
| `.md`, `.csv`, `.tsv`, `.json`/`.xml` (pretty-printed) | Own | — | — | — |
| `.zip` | Unzip + recurse | — | — | — |
| images, `.heic`, `.tiff`, `.psd` (flattened), `.svg` (WebKit) | ImageIO / WebKit | — | — | — |
| `.eml`/`.msg` (mail) | Own: headers + body (HTML via WebKit) + attachments as pages or embedded files | — | Mail | Acrobat has Outlook/Mail→PDF |
| anything else | Quick Look preview image (page one) with a notice | — | "Print to Super PDF" from the owning app (#48) | — |

**LibreOffice helper [D].** LibreOffice 26.2 is installed on the reference Mac (`/Applications/LibreOffice.app`, 800 MB,
`soffice --headless --convert-to pdf --outdir DIR FILE` [L]). Licence MPL-2.0: it cannot be bundled inside an
MIT app without carrying MPL terms, and 800 MB would dwarf the app. Decision: **never bundled, never downloaded or
installed by Super PDF; an installed copy is auto-detected** (`/Applications/LibreOffice.app`, `~/Applications`,
Homebrew cask path, Settings override) and run headless. When a file needs it and there is none, the panel says so
("Spreadsheets saved as ".ods" need the free Office converter (LibreOffice, about 800 MB).") and offers **Get
LibreOffice**, which opens LibreOffice's download page in the browser; the person installs it like any app, and Super
PDF finds it ("Look Again" in Settings, or at the next panel). The alternative that lost was a one-click install that
downloaded the official DMG, checked its SHA-256 and code signature and copied the app into Application Support: more
code, an 800 MB download inside the app, and a second copy of an app many people already have. Runs use a private
profile (`-env:UserInstallation=file://…/lo-profile`), a 120 s timeout, no network (`--norestore --nologo --headless`),
one job at a time. Settings › Converters shows where it was found, "Choose…" for another copy, and the MPL notice
(also in `THIRD_PARTY_NOTICES.md`).

**App automation.** Word/Excel/PowerPoint/Pages/Numbers/Keynote are driven with Apple Events (`NSAppleScript`/
`OSAKit`, `NSAppleEventsUsageDescription`, the macOS Automation permission prompt names the app). The user sees "Pages
will open to export this file" before it happens; the app is told to quit afterwards only if Super PDF launched it.

**PDF → Office is always native** (§1.4 #50–52): LibreOffice imports PDF as drawings, not documents, so it does not
help, and Acrobat's own export is the only comparable product. The layout-analysis engine (§2.4) is the investment.

### 3.3 OCR and document detection: Apple frameworks [D]
Vision `VNRecognizeTextRequest` (accurate level, automatic language detection, custom words from the document's
existing text) [S] is the OCR engine: no download, 20+ languages, fast on the Neural Engine. The invisible text layer
is written by us (QPDF) so positions are exact and the result works in every reader. Reading aloud uses
AVSpeechSynthesizer.

### 3.4 No AI [D]

Product decision: Super PDF ships no language model and no AI tools. The brief's AI items (AI assistant, chat,
summarizer, translate, question generator) and Acrobat's AI Assistant, generative summaries and podcast/presentation
generation are not reproduced (§5). There is nothing to download for any tool, no model storage, and no Settings pane
for models. The owner's decision; the alternative that lost was Super Flow's on-device llama.cpp stack (Qwen3.5).

### 3.5 What touches the network, exhaustively
1. None for LibreOffice: "Get LibreOffice" (and "Get Pages") open a download page in the browser or the App Store; Super
   PDF downloads nothing itself.
2. Update checks against this repository's GitHub Releases (Super Flow's `UpdateKit`, opt-out in Settings).
3. Fetching a URL the user typed into "Web page → PDF" (not built yet: Any file → PDF converts local web pages and web
   archives only, so today nothing is fetched).
4. Optional RFC 3161 timestamps when the user turns on "Add a trusted timestamp" in certificate signing and names a
   server. Off by default.
Everything else works with Wi-Fi off. `PRIVACY.md` repeats this list.

### 3.6 Digital signatures without a server [D]
`swift-certificates` + `swift-asn1` (Apache-2.0, Apple) generate self-signed certificates and produce/verify CMS
`SignedData`; `Security.framework` holds keys in the Keychain (`SecKeyCreateRandomKey`, access control: user presence
optional). The PDF side (`/Sig` with `/ByteRange`, `/SubFilter /ETSI.CAdES.detached`, incremental update, DocMDP for
"lock after signing") is done through QPDF. Trust: system roots plus the user's "People I trust" list of certificates;
no AATL download (that list is Adobe's and online). Request signatures (#84) is a pure document exchange on top of this.

## 4. Coverage check against the brief

| Required | Tool # | Required | Tool # |
|---|---|---|---|
| Compress PDF | 91 | PDF Converter | 47, 50–55 |
| PDF OCR | 92 | PDF to PDF/A | 56 |
| PDF to JPG/PNG | 53 | JPG to PDF | 34 |
| PDF to Word/Excel/PPT | 50, 51, 52 | Word/Excel/PPT to PDF | 35, 36, 37 |
| ODT/ODS/ODP to PDF | 38 | TXT/RTF/HWP/HTML/EPUB/ZIP/CSV to PDF | 40, 45, 41, 42, 44, 43 |
| Pages to PDF | 39 | Merge, Split, Rotate, Delete, Extract, Organize | 18, 23, 20, 21, 22, 19 |
| Edit PDF (text + images) | 60, 61 | Annotator | 76 |
| Reader | 2 | Number pages | 30 |
| Crop | 28 | Redact | 69 |
| Watermark | 66 | Form filler | 80 |
| Share | 17 | Sign PDF | 82 |
| Request signatures | 84 | Unlock / Protect / Flatten | 87 / 86 / 70 |
| AI assistant, Chat, Summarizer, Translate, Question generator | not built (§3.4) | Scanner | 101–104 |
| Compare files | 13 | Bookmarks/outline | 6, 7 |
| Headers/footers, Bates | 64, 65 | Measure | 15 |
| Accessibility check/tags | 97 | Optimize | 91 |
| Print production basics | 94, 95, 96, 32 | Stamps, comments review, attachments | 68, 77, 9/79 |
| Fill & sign, prepare form | 80/82, 81 | Action wizard (batch) | 75 |

## 5. Acrobat features deliberately not reproduced [D]
- Cloud: Adobe Document Cloud, shared reviews, Send & Track links, Adobe Sign servers, Acrobat online tools. Replaced by
  local flows (#84) and the share sheet.
- PDF JavaScript execution (#74): shown and removable, never run. Form calculations are emulated for the standard
  `AF*` helpers.
- Rich media: Flash/3D (U3D/PRC) playback, embedded video playback. Attachments can still be opened in their apps.
- PDF Portfolios: opened as a folder of attachments (Attachments sidebar), not as a portfolio layout.
- XFA forms: displayed static with a notice.
- Acrobat Distiller / PostScript: `.ps`/`.eps` convert through Quartz only when macOS can rasterize them; otherwise
  LibreOffice (Draw imports EPS).
- AI: Acrobat AI Assistant, generative summaries, Generate podcast / presentation, Adobe Firefly generative features,
  Adobe Express templates, PDF Spaces/Knowledge Base, Analyzer: not included; Super PDF has no AI (§3.4).
- Microsoft Purview sensitivity labels, SharePoint check-in/out, Dropbox, email accounts inside the app (SendMail): not included; the share sheet and Finder cover them.
- Geospatial measuring, 3D measuring, trap presets, ink manager, JDF: not included (print-production basics only).
- Articles, page templates, legacy multimedia renditions: not included.
