import AppKit
import Darwin
import Foundation
import SuperPDFCore

/// Per-document view state in the file's extended attribute (ARCHITECTURE "Data"; features §2.1): never inside the PDF,
/// so the bytes stay exactly as they were. Files that can't take attributes simply don't remember their view.
enum ViewStateStore {
    static func read(_ url: URL) -> DocumentViewState? {
        let name = SuperPDFPaths.viewStateAttribute
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0, size < 64 * 1024 else { return nil }
        var buffer = Data(count: size)
        let read = buffer.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        guard read == size else { return nil }
        return try? JSONDecoder().decode(DocumentViewState.self, from: buffer)
    }

    static func write(_ state: DocumentViewState, to url: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let result = data.withUnsafeBytes { setxattr(url.path, SuperPDFPaths.viewStateAttribute, $0.baseAddress, data.count, 0, 0) }
        if result != 0 { Log.documents.debug("View state not kept for a file (errno \(errno))") }
    }
}

/// The welcome window's Recent list (ux §6.1), newest first, with the page count and size it shows. Files that are
/// gone drop out when read.
@MainActor
final class RecentsStore {
    static let key = Defaults.Key<[RecentDocument]>("documentKit.recents", default: [])
    static let limit = 20

    /// Also feeds File › Open Recent (off in the self-test, which must not touch the system's list).
    let notesSystemRecents: Bool

    init(notesSystemRecents: Bool) { self.notesSystemRecents = notesSystemRecents }

    var documents: [RecentDocument] {
        Defaults[Self.key].filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    func note(_ url: URL, pageCount: Int, at date: Date = Date()) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        var list = Defaults[Self.key].filter { $0.url.standardizedFileURL != url.standardizedFileURL }
        list.insert(RecentDocument(url: url, lastOpened: date, pageCount: pageCount, fileSize: size), at: 0)
        Defaults[Self.key] = Array(list.prefix(Self.limit))
        if notesSystemRecents { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }

    func remove(_ url: URL) {
        Defaults[Self.key] = Defaults[Self.key].filter { $0.url.standardizedFileURL != url.standardizedFileURL }
    }
}
