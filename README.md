<h1 align="center">Super PDF</h1>

<p align="center">
  <b>Every Acrobat tool. As simple as Preview. Everything on your Mac.</b><br>
  Open a PDF, press <b>Tools</b>, pick a tile. Drag pages to rearrange, drop files to combine. Nothing leaves the machine.
</p>

<p align="center">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-52CC64"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple&logoColor=white">
  <img alt="Local" src="https://img.shields.io/badge/cloud-none-111">
  <img alt="Status" src="https://img.shields.io/badge/status-1.0%20in%20testing-0A7AFF">
</p>

<p align="center">
  <a href="docs/specs/ux.md"><b>UX design</b></a> ·
  <a href="docs/specs/features.md">Feature inventory</a> ·
  <a href="docs/ARCHITECTURE.md">Architecture and work packages</a> ·
  <a href="docs/mockups/">Mockups</a>
</p>

---

Super PDF is a free, open-source macOS PDF app that does what Adobe Acrobat does — combine, organise, convert, edit,
mark up, sign, request signatures, protect, redact, OCR, compress, compare, fill and build forms, check accessibility,
scan — with the window of Apple's Preview: one document, one thumbnail sidebar, one
**Tools** button. Every tool is one friendly tile with a plain-language name ("Make smaller", not "Optimize PDF") that
opens one small panel with one big button. The original file is never overwritten without asking; every change can be
undone.

There is no account, no server, no telemetry and no AI. OCR runs on Apple Vision. Office conversions
run natively where macOS can do them, through LibreOffice when it is installed on the Mac, and through Word, Excel,
PowerPoint, Pages, Numbers or Keynote when they are (see `docs/specs/features.md` §3). The only network traffic is
listed in [`PRIVACY.md`](PRIVACY.md).

## Install

```sh
curl -fsSL https://udsy19.github.io/super-pdf/install.sh | bash
```

or download `SuperPDF.dmg` from the [latest release](https://github.com/udsy19/super-pdf/releases/latest) and drag
Super PDF into Applications. The app is signed with its own certificate, not notarised: the first time, macOS asks you
to confirm in System Settings › Privacy & Security (the DMG's notes say how). It keeps itself up to date from this
repository's releases; Settings › Privacy turns that off, and Super PDF › Check for Updates… always works.

Uninstall: `curl -fsSL https://udsy19.github.io/super-pdf/install.sh | bash -s -- --uninstall`.

## What's in the box

| | |
|---|---|
| **The window** | Preview's: thumbnails, table of contents, highlights and notes, bookmarks, attachments, search; the page organiser; the markup bar; reader mode and read aloud. |
| **Tools** (⌘T) | 52 tiles in eight sections — Pages, Convert, Edit, Mark up, Sign & fill, Protect, Fix & check, Scan — each one panel with one button; the document itself is the live preview. |
| **Do this to many files** | Any of the file-level tools on a folder, in order; save the steps as a routine. |
| **Finder** | Quick Actions: Combine in Super PDF, Make Smaller, Convert to PDF, Recognise Text. Services: Open Selection as PDF. Print dialogs: Save to Super PDF. |
| **Links** | `superpdf://open?file=/path.pdf` and `superpdf://tool/make-smaller?file=/a.pdf&file=/b.pdf`. |

## Building

Command Line Tools only (no Xcode), macOS 14 or later, Apple silicon or Intel.

```sh
scripts/build-qpdf.sh fetch     # once per checkout: the pinned QPDF xcframework into Vendor/ (needs gh)
swift build
swift run SuperPDFSelfTest      # headless checks, including the end-to-end chains through the real modules
scripts/signing-setup.sh        # once: a project-local signing identity in .signing/ (keeps privacy grants)
scripts/build-app.sh            # build/Super PDF.app, with static launch checks; --debug for a quick build
scripts/e2e.sh                  # the real app driven through Accessibility on throwaway data (needs Accessibility)
```

`scripts/make-dmg.sh` makes the universal DMG; `scripts/release.sh <version>` publishes it (with the SHA-256 line the
updater checks). The design lives in `docs/`: [UX](docs/specs/ux.md), [features](docs/specs/features.md),
[architecture](docs/ARCHITECTURE.md) and [mockups](docs/mockups/).

## Licence

MIT. Third-party code keeps its own licences, listed in full in `THIRD_PARTY_NOTICES.md` (shipped inside the app):
QPDF (Apache-2.0), libjpeg-turbo (IJG, BSD-3-Clause, zlib), swift-certificates, swift-asn1 and swift-crypto with
BoringSSL (Apache-2.0). LibreOffice (MPL-2.0) is never bundled or downloaded by Super PDF; an installed copy is used
when there is one.
