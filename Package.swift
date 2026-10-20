// swift-tools-version:5.10
import PackageDescription

// Super PDF — every Acrobat tool with the window of Preview, all on the Mac. Feature modules depend only on
// SuperPDFCore (the contracts) plus the engines listed for them below; the app target wires them together through the
// `Services` registry. See docs/ARCHITECTURE.md for who owns what and docs/specs/ for behaviour, look and wording. The
// package is self-contained: no dependency on the sister apps' repositories.
let modules = [
    "DocumentKit",      // NSDocument, open/repair/password, save policy, output naming, versions, undo, recents, view state
    "ViewerKit",        // main window, toolbar, sidebar modes, PDFView host, reader, find, page organiser, banner, welcome
    "ToolsKit",         // the Tools sheet, panel host and archetypes A–G, scope, live preview, progress, frecency, search
    "PagesKit",         // page tools: combine, rearrange, rotate, delete, extract, split, insert, crop, number, booklet…
    "ConvertKit",       // conversion registry runtime, native importers, LibreOffice helper, app automation, exporters
    "EditKit",          // edit text & images, headers/footers, Bates, watermark, background, stamps, links, scripts
    "MarkupKit",        // Preview's markup bar, appearance streams, comments review, attachments, measure, snapshot
    "FormsKit",         // fill (AF* emulation, AutoFill), make a form (detection, palette), form data, templates
    "SignKit",          // signature library, certificate signing and verification, certificates, request signatures
    "ProtectKit",       // passwords and permissions, redaction, hidden information, certificate encryption, flatten
    "FixKit",           // make smaller, OCR, repair, fast web view, fonts, PDF/A check, print checks, accessibility
    "ScanKit",          // Continuity Camera, Image Capture scanners, document detection, scan clean-up
    "BatchKit",         // "Do this to many files": pipelines, routines, Quick Actions and App Intents plumbing
    "SettingsKit",      // the settings window and its panes
]

// Shared analysis modules (docs/ARCHITECTURE.md "Rules"): like engines they carry no app policy and every feature
// module may import them; each also registers its service (`Services.layout`, `Services.render`) in `install()`.
let sharedModules = [
    "LayoutKit",  // text and layout analysis: words → lines → paragraphs/columns/headings/lists/tables/figures, order
    "RenderKit",  // Quartz rendering and writing: rasterize, PDF/A and PDF/X contexts, imposition, colour, separations
]

// Engines (docs/ARCHITECTURE.md "Engines"): no app policy (no `Services`, no `Defaults`, no UI strings), configured
// through initialisers. UpdateKit is adapted from Super Flow (WP0a); PDFModelKit wraps QPDF (WP0c).
let engines = [
    "UpdateKit",    // GitHub Releases updater: check, verify, stage, swap on quit or idle
    "PDFModelKit",  // QPDF wrapper: object model, page tree, content streams, encryption, linearize, signatures
]

// QPDF 12 (Apache-2.0) as a static universal xcframework, built by `scripts/build-qpdf.sh build` and published on this
// repository's Releases, pinned by release tag and SHA-256 (`swift package compute-checksum`). The repository is
// private and SwiftPM cannot download a private release asset (GitHub answers 404 even with a token), so the target
// is a local path: run `scripts/build-qpdf.sh fetch` once per checkout/worktree (and in CI) to download the pinned
// asset with `gh`, check it against `qpdfChecksum` and unpack it into Vendor/ (git-ignored). When the repository is
// public the line can become `.binaryTarget(name: "QPDF", url: "https://github.com/udsy19/super-pdf/releases/download/
// \(qpdfRelease)/QPDF.xcframework.zip", checksum: qpdfChecksum)`. Module `QPDF` is QPDF's C API (qpdf-c.h,
// qpdfjob-c.h, qpdflogger-c.h) and autolinks libc++ and libz.
let qpdfRelease = "qpdf-12.4.2"
let qpdfChecksum = "4b3718eb8368ad6bf6453bff866563c582e7231a1a12895cba5276ae8d7b2b9d"

// What each engine links.
let engineDependencies: [String: [Target.Dependency]] = [
    "PDFModelKit": ["QPDF"],
]

// The engines every feature module may use (ARCHITECTURE "Rules"), and the extra ones a module needs.
let sharedEngines: [Target.Dependency] = ["PDFModelKit", "LayoutKit", "RenderKit"]
let moduleDependencies: [String: [Target.Dependency]] = [
    "SignKit": [.product(name: "X509", package: "swift-certificates"), .product(name: "SwiftASN1", package: "swift-asn1")],
]

let package = Package(
    name: "SuperPDF",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SuperPDF", targets: ["SuperPDF"]),
    ],
    dependencies: [
        // CMS SignedData, X.509 certificates for signing and verification (features §3.6). Apache-2.0, Apple.
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.21.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.3"),
    ],
    targets: [
        .target(name: "SuperPDFCore", path: "Sources/SuperPDFCore"),

        .binaryTarget(name: "QPDF", path: "Vendor/QPDF.xcframework"),

        .executableTarget(
            name: "SuperPDF",
            dependencies: ["SuperPDFCore", "UpdateKit"] + (sharedModules + modules).map { .target(name: $0) },
            path: "Sources/SuperPDF"),
        // Finder Quick Actions (Combine, Make smaller, Convert to PDF, Recognise text); packaged as an app extension by
        // scripts/build-app.sh (WP16).
        .executableTarget(name: "SuperPDFQuickActions", dependencies: ["SuperPDFCore"], path: "Sources/SuperPDFQuickActions"),
        // Headless checks (Command Line Tools have no XCTest): `swift run SuperPDFSelfTest`.
        .executableTarget(
            name: "SuperPDFSelfTest",
            dependencies: ["SuperPDFCore"] + (sharedModules + modules + engines).map { .target(name: $0) },
            path: "Sources/SuperPDFSelfTest"),
    ]
    + engines.map { name in
        .target(name: name, dependencies: ["SuperPDFCore"] + (engineDependencies[name] ?? []), path: "Sources/\(name)")
    }
    + sharedModules.map { name in
        .target(name: name, dependencies: ["SuperPDFCore", "PDFModelKit"], path: "Sources/\(name)")
    }
    + modules.map { name in
        .target(name: name, dependencies: ["SuperPDFCore"] + sharedEngines + (moduleDependencies[name] ?? []), path: "Sources/\(name)")
    }
)
