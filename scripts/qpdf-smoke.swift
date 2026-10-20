// Smoke test for Vendor/QPDF.xcframework (WP0b acceptance), run per slice by `scripts/build-qpdf.sh verify`:
// open a Quartz-made PDF through QPDF's C API, re-save it, linearize it, encrypt it (AES-256, R6, native crypto),
// decode a DCT stream (libjpeg-turbo), and re-open every output with QPDF and PDFKit.
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import QPDF
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
    .appendingPathComponent("qpdf-smoke", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let arch: String = {
    #if arch(arm64)
    return "arm64"
    #else
    return "x86_64"
    #endif
}()

func check(_ condition: Bool, _ message: String) {
    guard condition else { FileHandle.standardError.write("FAIL [\(arch)]: \(message)\n".data(using: .utf8)!); exit(1) }
    print("ok   \(message)")
}

func errorText(_ q: qpdf_data) -> String {
    guard qpdf_has_error(q) != QPDF_FALSE, let e = qpdf_get_error(q) else { return "" }
    return String(cString: qpdf_get_error_full_text(q, e))
}

/// Opens `path` with QPDF, runs `body`, and cleans up.
func withQPDF<T>(_ path: String?, password: String? = nil, _ body: (qpdf_data) -> T) -> T {
    var q: qpdf_data? = qpdf_init()
    defer { qpdf_cleanup(&q) }
    if let path {
        let rc = qpdf_read(q, path, password)
        check(rc & QPDF_ERRORS == 0, "qpdf_read \(URL(fileURLWithPath: path).lastPathComponent) \(errorText(q!))")
    }
    return body(q!)
}

func write(_ q: qpdf_data, to url: URL, configure: (qpdf_data) -> Void = { _ in }) {
    check(qpdf_init_write(q, url.path) & QPDF_ERRORS == 0, "qpdf_init_write \(url.lastPathComponent)")
    configure(q)
    check(qpdf_write(q) & QPDF_ERRORS == 0, "qpdf_write \(url.lastPathComponent) \(errorText(q))")
}

func pdfKitPageCount(_ url: URL, password: String? = nil) -> Int {
    guard let doc = PDFDocument(url: url) else { return -1 }
    if let password, doc.isLocked { _ = doc.unlock(withPassword: password) }
    return doc.isLocked ? -1 : doc.pageCount
}

print("QPDF \(String(cString: qpdf_get_qpdf_version())) on \(arch)")

// 1. A three-page PDF made by Quartz.
let input = outDir.appendingPathComponent("input.pdf")
var box = CGRect(x: 0, y: 0, width: 612, height: 792)
let ctx = CGContext(input as CFURL, mediaBox: &box, nil)!
for page in 1...3 {
    ctx.beginPDFPage(nil)
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 72, y: 72, width: 100 * CGFloat(page), height: 100))
    ctx.endPDFPage()
}
ctx.closePDF()

// 2. Open, re-save, linearize.
let resaved = outDir.appendingPathComponent("resaved.pdf")
let linearized = outDir.appendingPathComponent("linearized.pdf")
withQPDF(input.path) { q in
    check(qpdf_get_num_pages(q) == 3, "input has 3 pages")
    write(q, to: resaved)
}
withQPDF(resaved.path) { q in
    check(qpdf_get_num_pages(q) == 3, "re-saved file has 3 pages")
    write(q, to: linearized) { qpdf_set_linearization($0, QPDF_TRUE) }
}
withQPDF(linearized.path) { q in
    check(qpdf_is_linearized(q) != QPDF_FALSE, "output is linearized")
    check(qpdf_get_num_pages(q) == 3, "linearized file has 3 pages")
}
check(pdfKitPageCount(resaved) == 3 && pdfKitPageCount(linearized) == 3, "PDFKit opens both outputs")

// 3. AES-256 (R6) through the native crypto provider.
let encrypted = outDir.appendingPathComponent("encrypted.pdf")
withQPDF(input.path) { q in
    write(q, to: encrypted) {
        qpdf_set_r6_encryption_parameters2($0, "user", "owner", QPDF_TRUE, QPDF_TRUE, QPDF_TRUE, QPDF_TRUE,
                                           QPDF_TRUE, QPDF_TRUE, qpdf_r3p_full, QPDF_TRUE)
    }
}
withQPDF(encrypted.path, password: "user") { q in
    check(qpdf_is_encrypted(q) != QPDF_FALSE && qpdf_get_num_pages(q) == 3, "R6 file re-opens with its password")
}
check(pdfKitPageCount(encrypted, password: "user") == 3, "PDFKit unlocks the R6 file")

// 4. DCT decode through the bundled libjpeg-turbo.
let jpeg = NSMutableData()
let rgb = CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
rgb.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
rgb.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, rgb.makeImage()!, nil)
check(CGImageDestinationFinalize(dest), "ImageIO made a JPEG")
withQPDF(nil) { q in
    check(qpdf_empty_pdf(q) & QPDF_ERRORS == 0, "qpdf_empty_pdf")
    let stream = qpdf_oh_new_stream(q)
    (jpeg as Data).withUnsafeBytes { raw in
        qpdf_oh_replace_stream_data(q, stream, raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                                    qpdf_oh_new_name(q, "/DCTDecode"), qpdf_oh_new_null(q))
    }
    var filtered: QPDF_BOOL = QPDF_FALSE
    var buffer: UnsafeMutablePointer<UInt8>?
    var length = 0
    let rc = qpdf_oh_get_stream_data(q, stream, qpdf_dl_all, &filtered, &buffer, &length)
    defer { qpdf_oh_free_buffer(&buffer) }
    check(rc & QPDF_ERRORS == 0 && filtered != QPDF_FALSE && length == 16 * 8 * 3,
          "DCT stream decodes to 16×8 RGB (\(length) bytes)")
}

print("PASS [\(arch)]")
