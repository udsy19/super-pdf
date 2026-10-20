<h1 align="center">Super PDF</h1>

<p align="center">
  <b>Every Acrobat tool. As simple as Preview. Everything on your Mac.</b><br>
  Open a PDF, press <b>Tools</b>, pick a tile. Drag pages to rearrange, drop files to combine. Nothing leaves the machine.
</p>

<p align="center">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-52CC64"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple&logoColor=white">
  <img alt="Local" src="https://img.shields.io/badge/cloud-none-111">
  <img alt="Status" src="https://img.shields.io/badge/status-design%20complete%2C%20build%20pending-0A7AFF">
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
run natively where macOS can do them and through an optional, auto-detected LibreOffice helper where it cannot
(see `docs/specs/features.md` §3).

## Status

The product is specified and designed; the build is split into the work packages in `docs/ARCHITECTURE.md`.

| Document | What it is |
|---|---|
| `docs/specs/ux.md` | The UX design: window anatomy, the Tools sheet, every tool panel, wireframes, metrics, type, colour, motion, empty states and error copy. The grandma test. |
| `docs/specs/features.md` | Every feature (Acrobat's set plus the required list), with behaviour, local implementation approach and engine. |
| `docs/ARCHITECTURE.md` | Modules, Core contracts, the `Services` registry, engines, and parallel work packages with briefs. |
| `docs/mockups/` | High-fidelity HTML/CSS mockups of the main screens, rendered to PNG. |

## Building (once the work packages land)

```sh
swift build -c release          # Command Line Tools only; no Xcode
swift run SuperPDFSelfTest      # headless checks
scripts/build-app.sh            # Super PDF.app
```

Requires macOS 14 or later, on Apple silicon or Intel.

## Licence

MIT. Third-party code keeps its own licences: QPDF (Apache-2.0) and libjpeg-turbo (IJG, BSD-3-Clause, zlib), listed
in `THIRD_PARTY_NOTICES.md`; swift-certificates and swift-asn1 (Apache-2.0). LibreOffice (MPL-2.0) is never
bundled; it is detected on the Mac or installed by the user on request.
