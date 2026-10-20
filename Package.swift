// swift-tools-version:5.9
import PackageDescription

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

let package = Package(
    name: "SuperPDF",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "QPDF", path: "Vendor/QPDF.xcframework"),
    ]
)
