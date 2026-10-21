// The files scripts/e2e.sh drives the app with, and the checks of what the app made from them.
//   swift scripts/e2e-check.swift fixtures <folder>   writes Lease.pdf (2 pages, with a "CONFIDENTIAL" line to black out)
//                                                     and Schedule.pdf (1 page) into <folder>
//   swift scripts/e2e-check.swift verify <folder>     checks the outputs the run should have left next to them; prints
//                                                     one line per check and exits non-zero when any fails
// Nothing here launches or talks to the app.
import AppKit
import PDFKit

let arguments = CommandLine.arguments
guard arguments.count == 3, ["fixtures", "verify"].contains(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: swift scripts/e2e-check.swift fixtures|verify <folder>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[2], isDirectory: true)

/// Letter pages, each with its lines of text, written with Quartz (fonts embedded, text extractable).
func pdf(_ pages: [[String]]) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
    for lines in pages {
        context.beginPDFPage(nil)
        for (index, text) in lines.enumerated() {
            let size: CGFloat = index == 0 ? 22 : 13
            let font = NSFont(name: index == 0 ? "Helvetica-Bold" : "Helvetica", size: size)!
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            context.textPosition = CGPoint(x: 72, y: 720 - CGFloat(index) * 28)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

if arguments[1] == "fixtures" {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try pdf([
        ["Lease agreement", "This lease is made between Orchard Lettings and the tenant.", "The rent is due on the first day of each month.",
         "CONFIDENTIAL account reference 4111 1111 1111 1111", "Either party may end it with two months' notice."],
        ["Signatures", "Signed for Orchard Lettings:", "Signed by the tenant:", "Date:"],
    ]).write(to: folder.appendingPathComponent("Lease.pdf"))
    try pdf([["Schedule of condition", "Kitchen: good.", "Bathroom: good.", "Bedroom: fair."]])
        .write(to: folder.appendingPathComponent("Schedule.pdf"))
    print("Wrote Lease.pdf and Schedule.pdf in \(folder.path)")
    exit(0)
}

// MARK: - verify

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { failures += 1 }
}
func document(_ name: String) -> PDFDocument? { PDFDocument(url: folder.appendingPathComponent(name)) }
func size(_ name: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.size] as? Int) ?? 0 }

let lease = document("Lease.pdf")
check(lease?.pageCount == 2 && lease?.string?.contains("CONFIDENTIAL") == true, "the original Lease.pdf is untouched")

// Make smaller: a new file next to the original that opens with every page.
let smaller = document("Lease (smaller).pdf")
check(smaller?.pageCount == 2, "Make smaller wrote “Lease (smaller).pdf” with both pages")
check(size("Lease (smaller).pdf") > 0 && size("Lease (smaller).pdf") <= size("Lease.pdf"), "and it is no bigger than the original")

// Combine: Lease then Schedule, saved as Combined.pdf.
let combined = document("Combined.pdf")
check(combined?.pageCount == 3, "Combine made a 3-page “Combined.pdf”")
check(combined?.page(at: 2)?.string?.contains("Schedule of condition") == true, "with Schedule's page last")

// Black out: the word is gone from the text, not just covered.
let blackedOut = document("Lease (blacked out).pdf")
check(blackedOut?.pageCount == 2, "Black out wrote “Lease (blacked out).pdf”")
check(blackedOut.map { !($0.string ?? "").contains("CONFIDENTIAL") } ?? false, "and “CONFIDENTIAL” can't be found in it any more")
check(blackedOut?.string?.contains("The rent is due") == true, "while the rest of the text is still there")

// Sign: "Sign and save…" wrote a copy with the placed signature on its page.
let signed = document("Lease (signed).pdf")
let annotations = signed.map { document in (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] } } ?? []
check(signed?.pageCount == 2, "Sign wrote “Lease (signed).pdf”")
check(annotations.contains { $0.type == "Stamp" || $0.type == "Widget" || $0.type == "Ink" }, "with the signature placed on a page: \(annotations.map { $0.type ?? "?" })")

// Convert to Word: a .docx whose document part has the lease's words.
let docx = folder.appendingPathComponent("Lease.docx")
check(FileManager.default.fileExists(atPath: docx.path), "To Word saved “Lease.docx”")
let unzip = Process()
unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
unzip.arguments = ["-p", docx.path, "word/document.xml"]
let pipe = Pipe()
unzip.standardOutput = pipe
unzip.standardError = Pipe()
if (try? unzip.run()) != nil {
    let xml = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    unzip.waitUntilExit()
    // The words, whatever runs the writer split them into.
    let words = xml.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    check(words.contains("rent is due"), "and its text is the lease's")
} else {
    check(false, "and it unzips")
}

print(failures == 0 ? "All outputs check out." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
