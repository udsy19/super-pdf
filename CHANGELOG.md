# Changelog

All notable changes to Super PDF. Versions follow [Semantic Versioning](https://semver.org).

## [1.1.1] - 2026-10-22

- Quick Look inside Super PDF: Space on a card in the Combine and Rearrange workspace (Files or Pages), on a sidebar
  thumbnail or on a recent file in the welcome window opens macOS's own preview panel, with its thumbnail strip, Markup,
  Share and Open with; the arrow keys and the strip move the selection, and it zooms out of and back into the card. Pages
  and merged files preview as they are now, without saving. This replaces the workspace's own preview overlay; rotate and
  delete stay on the cards' hover toolbar and the menus.
- Super PDF can be your PDF app, so Quick Look's header says "Open with Super PDF": the app now ranks as the default
  handler for PDFs, the welcome window offers it once (a gentle "Not Now" is remembered), and Settings › General has an
  "Open PDFs with Super PDF" line showing the current app ("Currently: Adobe Acrobat") with a button; macOS asks you to
  confirm.

## [1.1.0] - 2026-10-22

- A cheerful look: one bright colour per section on every tool's icon, section chips in the Tools sheet, a colour wash
  behind each panel's header, a friendlier welcome window, springy hovers, and a success check that pops in with a
  little confetti (all of it calm under Reduce Motion).
- The workspace for Combine and Rearrange: files (of any kind, converting on their own cards) or pages as big cards on a
  soft canvas, each file in its own pastel pill; drag to reorder while the others make room, a "+" between cards, a
  hover toolbar to preview, rotate, duplicate or delete, select all, sort, grid or list, a big preview with ‹ › and
  Finish. Several files dropped on the app or the welcome window open it.
- The page organiser is now the workspace (View › Page Organiser, ⌥⌘6, still opens it).

## [1.0.0] - 2026-10-22

First release.

- Preview's window, sidebar, menus, markup bar and shortcuts, with one more button: Tools (⌘T), 52 tiles in eight
  sections, each one panel with one button and the document as the live preview.
- Pages: combine (pages per file), rearrange, split, extract, rotate, delete, crop with handles on the page, insert,
  number, booklet, resize.
- Convert: Word, Excel, PowerPoint, pictures, text, web page, EPUB, PDF/A (the accessible levels keep a tagged file's
  tags; a file that already qualifies is kept as it is) and PDF/X; any file into a PDF, with LibreOffice and the Office
  and iWork apps when they are on the Mac.
- Edit text and pictures on the page, headers and footers, Bates numbers, watermarks, stamps, links, contents.
- Mark up and comment, with thumbnails that show the markup; attach files and voice notes; measure.
- Sign with a drawn, photographed, iPhone-sketched, typed or imported signature, or with a certificate; verify
  signatures; request signatures by email, Messages or AirDrop and seal the returned copies.
- Protect: passwords, Black out with true removal, remove hidden information, lock in notes and fields.
- Fix & check: make smaller, recognise text, compare, accessibility, printing checks, repair.
- Scan from an iPhone, a scanner or a photo.
- Do this to many files, with routines; Finder Quick Actions; Open Selection as PDF; Save to Super PDF in the Print
  dialog; `superpdf://` links.
- Settings: General, Tools, Converters, Signatures, Scanning, Privacy. Automatic updates from GitHub Releases, which can
  be turned off; Check for Updates… always works.
- `scripts/e2e.sh`: an end-to-end run of the real app, driven through Accessibility on throwaway data.
