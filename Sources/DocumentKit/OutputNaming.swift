import Darwin
import Foundation
import SuperPDFCore

/// Output names and placement (ux §7.2): "<name> (<what>).<ext>" next to the original, " 2", " 3"… on collisions, and
/// moves that never replace an existing file.
public enum OutputNaming {
    /// The folder outputs go to: the original's folder when it can be written, else `fallback` (the Desktop).
    public static func folder(for original: URL?, fallback: URL) -> URL {
        guard let folder = original?.deletingLastPathComponent(), FileManager.default.isWritableFile(atPath: folder.path) else {
            return fallback
        }
        return folder
    }

    /// The file or folder name a policy gives a document called `base`; nil for policies that write no file.
    public static func name(for policy: OutputPolicy, base: String) -> String? {
        switch policy {
        case .inPlace, .newDocument: nil
        case .sibling(let suffix, let ext): suffix.fileName(base: base, ext: ext)
        case .sameName(let ext): "\(base).\(ext)"
        case .folder(let kind): kind.folderName(base: base)
        }
    }

    /// `name` in `folder`, or the first of "name 2.ext", "name 3.ext"… that doesn't exist yet. Folders (no extension)
    /// get "Report parts 2".
    public static func unique(_ name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent(numbered(name, n))
            n += 1
        }
        return candidate
    }

    /// "Report (smaller) 2.pdf", "Report parts 2".
    public static func numbered(_ name: String, _ n: Int) -> String {
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
    }

    /// Something (a file, folder or dangling symlink) already has this name.
    public static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Moves `source` to `destination`, or to the next free numbered name when something is already there (a file
    /// that appeared since the name was chosen is never replaced). Atomic on the same volume; across volumes the copy
    /// is finished under a hidden name first, so a crash never leaves a half-written file under the real name.
    public static func place(_ source: URL, at destination: URL) throws -> URL {
        let folder = destination.deletingLastPathComponent(), name = destination.lastPathComponent
        var staged = source
        var partial: URL?
        defer { if let partial { try? FileManager.default.removeItem(at: partial) } }
        var n = 1
        while true {
            let target = n == 1 ? destination : folder.appendingPathComponent(numbered(name, n))
            if renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                if partial != nil {
                    partial = nil   // it is the output now
                    try? FileManager.default.removeItem(at: source)
                }
                return target
            }
            switch errno {
            case EEXIST:
                n += 1
            case EXDEV where partial == nil:
                // Another volume: copy next to the destination under a hidden name, then rename it into place.
                let copy = folder.appendingPathComponent(".\(name).\(UUID().uuidString).partial")
                try FileManager.default.copyItem(at: source, to: copy)
                partial = copy
                staged = copy
            default:
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path,
                                                              NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
            }
        }
    }

    /// Creates the folder `destination` (or the next free numbered name).
    public static func makeFolder(at destination: URL) throws -> URL {
        let parent = destination.deletingLastPathComponent(), name = destination.lastPathComponent
        var n = 1
        while true {
            let target = n == 1 ? destination : parent.appendingPathComponent(numbered(name, n))
            if mkdir(target.path, 0o755) == 0 { return target }
            guard errno == EEXIST else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path,
                                                              NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
            }
            n += 1
        }
    }
}
