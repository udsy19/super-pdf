#!/bin/bash
# Builds, verifies, publishes and fetches the QPDF xcframework used by the `QPDF` binaryTarget in Package.swift.
#
#   scripts/build-qpdf.sh build     download pinned sources (SHA-256 checked), build static QPDF + libjpeg-turbo for
#                                   arm64 and x86_64, assemble Vendor/QPDF.xcframework and dist/QPDF.xcframework.zip
#   scripts/build-qpdf.sh verify    build and run scripts/qpdf-smoke.swift against Vendor/QPDF.xcframework on both
#                                   slices (x86_64 runs under Rosetta)
#   scripts/build-qpdf.sh release   upload dist/QPDF.xcframework.zip to the GitHub release named by `qpdfRelease`
#                                   in Package.swift and print the checksum to pin
#   scripts/build-qpdf.sh fetch     download the pinned release asset (gh, authenticated), check it against
#                                   `qpdfChecksum` in Package.swift and unpack it into Vendor/
#
# Recipe (docs/ARCHITECTURE.md, Engines + WP0b):
#   - QPDF 12, static, Release, crypto = QPDF's native provider only (no OpenSSL/GnuTLS), C++20, hidden visibility
#   - libjpeg-turbo, static, libjpeg API only (no TurboJPEG, tools or tests); Neon SIMD on arm64, plain C on x86_64
#     (x86 SIMD needs nasm, which the Command Line Tools do not ship)
#   - zlib from the macOS SDK (libz.tbd), linked by the consumer through the module map
#   - both libraries merged into one libqpdf.a per arch, lipo'd universal, macOS 14 deployment target
#   - the module map exposes QPDF's C API (qpdf-c.h, qpdfjob-c.h, qpdflogger-c.h) as module `QPDF` and autolinks
#     libc++ and libz; every public C++ header (and jpeglib.h, which Pl_DCT.hh includes) ships too, so a C++ shim
#     target can include <qpdf/...hh> if the C API is ever not enough
# Needs: Command Line Tools (clang, libtool, lipo, swift), cmake >= 3.16 (Homebrew), curl, shasum, ditto; gh for
# release/fetch. Intermediates live in a temp dir that is removed on exit.
set -euo pipefail

QPDF_VERSION="12.4.2"
QPDF_SHA256="8a58af5b6141319287c1883bec8bd1bd545b7567b7fc5e6ce5d25a1c85f36397"
JPEG_VERSION="3.2.0"
JPEG_SHA256="6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e"
DEPLOYMENT_TARGET="14.0"
ARCHS=(arm64 x86_64)
REPO="udsy19/super-pdf"
ASSET="QPDF.xcframework.zip"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
XCFRAMEWORK="$VENDOR/QPDF.xcframework"
DIST="$ROOT/dist"
ZIP="$DIST/$ASSET"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

WORK=""
cleanup() { [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT
make_work() { WORK="$(mktemp -d "${TMPDIR:-/tmp}/qpdf-build.XXXXXX")"; }

# The pin lives in Package.swift (`let qpdfRelease = "..."`, `let qpdfChecksum = "..."`).
pin() { sed -n "s/^let $1 = \"\(.*\)\"$/\1/p" "$ROOT/Package.swift" | head -1; }

download() { # url sha256 dest
    curl -fsSL --retry 3 -o "$3" "$1"
    local got; got="$(shasum -a 256 "$3" | cut -d' ' -f1)"
    [[ "$got" == "$2" ]] || die "SHA-256 mismatch for $1: expected $2, got $got"
}

build_arch() { # arch
    local arch="$1" sdk jobs simd=ON
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
    jobs="$(sysctl -n hw.ncpu)"
    [[ "$arch" == x86_64 ]] && simd=OFF
    local common=(
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_OSX_ARCHITECTURES="$arch"
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
        -DCMAKE_OSX_SYSROOT="$sdk"
        -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local"
    )
    local jpeg_prefix="$WORK/$arch/jpeg"

    log "libjpeg-turbo $JPEG_VERSION ($arch, SIMD $simd)"
    cmake -S "$WORK/src/libjpeg-turbo-$JPEG_VERSION" -B "$WORK/$arch/jpeg-build" "${common[@]}" \
        -DCMAKE_INSTALL_PREFIX="$jpeg_prefix" -DCMAKE_INSTALL_LIBDIR=lib \
        -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF \
        -DWITH_SIMD="$simd" >/dev/null
    cmake --build "$WORK/$arch/jpeg-build" -j "$jobs" >/dev/null
    cmake --install "$WORK/$arch/jpeg-build" >/dev/null

    log "QPDF $QPDF_VERSION ($arch)"
    # pkg-config (if installed) may only see our libjpeg; zlib then comes from the SDK via the explicit paths.
    PKG_CONFIG_LIBDIR="$jpeg_prefix/lib/pkgconfig" PKG_CONFIG_PATH="" \
    cmake -S "$WORK/src/qpdf-$QPDF_VERSION" -B "$WORK/$arch/qpdf-build" "${common[@]}" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_DOC=OFF \
        -DUSE_IMPLICIT_CRYPTO=OFF -DREQUIRE_CRYPTO_NATIVE=ON \
        -DSTATIC_JPEG=ON -DLIBJPEG_H_PATH="$jpeg_prefix/include" -DLIBJPEG_LIB_PATH="$jpeg_prefix/lib/libjpeg.a" \
        -DZLIB_H_PATH="$sdk/usr/include" -DZLIB_LIB_PATH="$sdk/usr/lib/libz.tbd" \
        -DINSTALL_EXAMPLES=OFF -DINSTALL_PKGCONFIG=OFF -DINSTALL_CMAKE_PACKAGE=OFF >/dev/null
    cmake --build "$WORK/$arch/qpdf-build" --target libqpdf -j "$jobs" >/dev/null

    libtool -static -no_warning_for_no_symbols -o "$WORK/$arch/libqpdf.a" \
        "$WORK/$arch/qpdf-build/libqpdf/libqpdf.a" "$jpeg_prefix/lib/libjpeg.a"
}

cmd_build() {
    command -v cmake >/dev/null || die "cmake not found (brew install cmake)"
    make_work
    mkdir -p "$WORK/src"
    log "Sources"
    download "https://github.com/qpdf/qpdf/releases/download/v$QPDF_VERSION/qpdf-$QPDF_VERSION.tar.gz" \
        "$QPDF_SHA256" "$WORK/qpdf.tar.gz"
    download "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$JPEG_VERSION/libjpeg-turbo-$JPEG_VERSION.tar.gz" \
        "$JPEG_SHA256" "$WORK/jpeg.tar.gz"
    tar -xzf "$WORK/qpdf.tar.gz" -C "$WORK/src"
    tar -xzf "$WORK/jpeg.tar.gz" -C "$WORK/src"

    local start=$SECONDS slices=()
    for arch in "${ARCHS[@]}"; do
        build_arch "$arch"
        slices+=("$WORK/$arch/libqpdf.a")
    done

    log "Assembling $XCFRAMEWORK"
    local lib_id="macos-arm64_x86_64" slice
    rm -rf "$XCFRAMEWORK"
    slice="$XCFRAMEWORK/$lib_id"
    mkdir -p "$slice/Headers/qpdf"
    lipo -create "${slices[@]}" -output "$slice/libqpdf.a"
    strip -S -x "$slice/libqpdf.a" 2>/dev/null || true
    cp "$WORK/src/qpdf-$QPDF_VERSION"/include/qpdf/*.h "$WORK/src/qpdf-$QPDF_VERSION"/include/qpdf/*.hh "$slice/Headers/qpdf/"
    # jpeglib.h + its config headers are identical across arches apart from SIMD flags not used by the API.
    cp "$WORK/arm64/jpeg/include"/*.h "$slice/Headers/"
    cat > "$slice/Headers/module.modulemap" <<'EOF'
module QPDF {
    header "qpdf/qpdf-c.h"
    header "qpdf/qpdfjob-c.h"
    header "qpdf/qpdflogger-c.h"
    link "c++"
    link "z"
    export *
}
EOF
    cat > "$XCFRAMEWORK/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>libqpdf.a</string>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>$lib_id</string>
			<key>LibraryPath</key>
			<string>libqpdf.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF
    mkdir -p "$XCFRAMEWORK/Licenses"
    cp "$WORK/src/qpdf-$QPDF_VERSION/LICENSE.txt" "$XCFRAMEWORK/Licenses/qpdf-LICENSE.txt"
    cp "$WORK/src/qpdf-$QPDF_VERSION/NOTICE.md" "$XCFRAMEWORK/Licenses/qpdf-NOTICE.md"
    cp "$WORK/src/libjpeg-turbo-$JPEG_VERSION/LICENSE.md" "$XCFRAMEWORK/Licenses/libjpeg-turbo-LICENSE.md"
    cp "$WORK/src/libjpeg-turbo-$JPEG_VERSION/README.ijg" "$XCFRAMEWORK/Licenses/libjpeg-turbo-README.ijg"

    mkdir -p "$DIST"
    rm -f "$ZIP"
    (cd "$VENDOR" && ditto -c -k --keepParent QPDF.xcframework "$ZIP")
    log "Built in $((SECONDS - start)) s: $(lipo -archs "$slice/libqpdf.a"), $(du -h "$slice/libqpdf.a" | cut -f1) library, $(du -h "$ZIP" | cut -f1) zip"
    log "SHA-256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
}

cmd_verify() {
    [[ -d "$XCFRAMEWORK" ]] || die "$XCFRAMEWORK missing (run build or fetch first)"
    make_work
    local pkg="$WORK/qpdf-smoke"
    mkdir -p "$pkg/Sources/qpdf-smoke"
    cp "$ROOT/scripts/qpdf-smoke.swift" "$pkg/Sources/qpdf-smoke/main.swift"
    cp -R "$XCFRAMEWORK" "$pkg/QPDF.xcframework"
    cat > "$pkg/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "qpdf-smoke",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "QPDF", path: "QPDF.xcframework"),
        .executableTarget(name: "qpdf-smoke", dependencies: ["QPDF"], path: "Sources/qpdf-smoke"),
    ]
)
EOF
    for arch in "${ARCHS[@]}"; do
        log "Smoke test ($arch)"
        swift build --package-path "$pkg" -c release --triple "$arch-apple-macosx$DEPLOYMENT_TARGET" -q
        local bin="$pkg/.build/$arch-apple-macosx/release/qpdf-smoke"
        [[ "$(lipo -archs "$bin")" == "$arch" ]] || die "smoke binary is not $arch"
        arch "-$arch" "$bin" "$WORK/out-$arch"
    done
}

cmd_release() {
    local tag; tag="$(pin qpdfRelease)"
    [[ -n "$tag" ]] || die "qpdfRelease not found in Package.swift"
    [[ -f "$ZIP" ]] || die "$ZIP missing (run build first)"
    local sum; sum="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
    if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
        gh release upload "$tag" "$ZIP" --repo "$REPO" --clobber
    else
        gh release create "$tag" "$ZIP" --repo "$REPO" --title "QPDF $QPDF_VERSION xcframework" --notes \
"Static universal (arm64 + x86_64) xcframework of QPDF $QPDF_VERSION with libjpeg-turbo $JPEG_VERSION, built by \`scripts/build-qpdf.sh\` for macOS $DEPLOYMENT_TARGET+. Native crypto, system zlib. SHA-256: \`$sum\`. Licences: Licenses/ inside the zip and THIRD_PARTY_NOTICES.md."
    fi
    log "Published $tag/$ASSET"
    log "Pin in Package.swift: let qpdfChecksum = \"$sum\""
}

cmd_fetch() {
    local tag sum
    tag="$(pin qpdfRelease)"; sum="$(pin qpdfChecksum)"
    [[ -n "$tag" && -n "$sum" ]] || die "qpdfRelease/qpdfChecksum not found in Package.swift"
    make_work
    log "Fetching $REPO $tag/$ASSET"
    gh release download "$tag" --repo "$REPO" --pattern "$ASSET" --dir "$WORK"
    local got; got="$(shasum -a 256 "$WORK/$ASSET" | cut -d' ' -f1)"
    [[ "$got" == "$sum" ]] || die "SHA-256 mismatch: Package.swift pins $sum, release has $got"
    rm -rf "$XCFRAMEWORK"
    mkdir -p "$VENDOR"
    ditto -x -k "$WORK/$ASSET" "$VENDOR"
    log "Installed $XCFRAMEWORK"
}

case "${1:-}" in
    build) cmd_build ;;
    verify) cmd_verify ;;
    release) cmd_release ;;
    fetch) cmd_fetch ;;
    *) die "usage: $0 build|verify|release|fetch" ;;
esac
