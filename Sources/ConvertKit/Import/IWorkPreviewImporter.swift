import CoreGraphics
import Foundation
import SuperPDFCore

/// Pages, Numbers and Keynote files without their app (features #39): the preview the app saved inside the file — the
/// whole document as `QuickLook/Preview.pdf` in older files, else `preview.jpg` (usually the first page) — with a notice.
/// iWork files are folders (packages) or single ZIP files.
enum IWorkPreviewImporter {
    /// Inside the file, best first.
    static let pdfPreviews = ["QuickLook/Preview.pdf", "preview.pdf"]
    static let picturePreviews = ["preview.jpg", "QuickLook/Thumbnail.jpg", "preview-web.jpg", "QuickLook/Thumbnail.png", "preview-micro.jpg"]

    static func convert(_ input: URL, to output: URL, options: ImportOptions) throws -> ImportReport {
        let notice = ImportReport(notices: [ConvertStrings.iWorkPreviewNotice(input.lastPathComponent)])
        if let pdf = try previewData(in: input, names: pdfPreviews) {
            try pdf.write(to: output)
            return ImportReport()
        }
        guard let picture = try previewData(in: input, names: picturePreviews) else { throw ConvertError.unsupported("no preview inside") }
        let file = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".jpg")
        try picture.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let pictures = try PicturePages.pictures(from: file)
        // The preview is a screen-sized picture of a page: give the page the paper's height.
        let scaled = pictures.map { picture -> PagePicture in
            let scale = ImportOptions.localePaper.height / max(picture.naturalSize.height, 1)
            return PagePicture(image: picture.image, naturalSize: CGSize(width: picture.naturalSize.width * scale, height: picture.naturalSize.height * scale))
        }
        try PicturePages.write(scaled, paper: options.paper, margins: CGFloat(options.margins), to: output, title: String.baseName(input))
        return notice
    }

    /// The first of `names` found in the package folder or the ZIP.
    private static func previewData(in url: URL, names: [String]) throws -> Data? {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        if isFolder.boolValue {
            for name in names {
                let file = url.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { return try Data(contentsOf: file) }
            }
            return nil
        }
        guard ZipArchive.looksLikeZip(url) else { throw ConvertError.unsupported("not an iWork file") }
        let archive = try ZipArchive(url: url)
        for name in names { if let data = try archive.data(name) { return data } }
        return nil
    }
}
