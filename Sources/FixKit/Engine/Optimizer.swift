import Foundation
import PDFModelKit
import SuperPDFCore

// Make smaller (features #91): pictures downsampled and re-encoded per XObject, the standard 14 fonts unembedded on
// request, the user data the options name discarded, then QPDF writes the file again with object streams, every stream
// recompressed (LZW and uncompressed become Flate) and unreferenced objects dropped, linearized on request. The
// estimate runs the same work on a five-page sample and scales the result to the whole file (ux §5.3: within 1 s).

extension OptimizeOptions {
    /// A preset's defaults (ux §5.3): Email 72 dpi pictures at JPEG quality 50%, Good 150 dpi at 70%, Best quality 300 dpi
    /// at 85% (and no lossless picture becomes JPEG).
    static func defaults(for preset: SizePreset) -> OptimizeOptions {
        switch preset {
        case .email: OptimizeOptions(preset: .email, imageDPI: 72, imageQuality: 0.5)
        case .good: OptimizeOptions(preset: .good, imageDPI: 150, imageQuality: 0.7)
        case .best: OptimizeOptions(preset: .best, imageDPI: 300, imageQuality: 0.85)
        }
    }

    var imageTarget: ImageTarget { ImageTarget(dpi: imageDPI, quality: imageQuality, reencodeLossy: preset != .best) }

    var writeOptions: PDFWriteOptions {
        PDFWriteOptions(objectStreams: compressObjectStreams ? .generate : .preserve, compressStreams: true, decodeLevel: .generalized,
                        linearize: linearize)
    }
}

enum Optimizer {
    /// The optimised file's bytes. `progress` gets (pages done, page count).
    static func optimize(_ source: PDFSource, options: OptimizeOptions, progress: ((Int, Int) -> Void)? = nil) throws -> Data {
        let model = try PDFModel(source)
        try apply(options, to: model, progress: progress)
        return try model.data(options: options.writeOptions)
    }

    /// Applies everything but the write to `model`.
    static func apply(_ options: OptimizeOptions, to model: PDFModel, progress: ((Int, Int) -> Void)? = nil) throws {
        let pages = model.pages
        // Each picture's densest use decides its resolution, so pages are read once before any picture changes.
        var uses: [[ImageUse]] = []
        var resolution: [Int: Double] = [:]
        for page in pages {
            let found = ImageUses.on(page)
            for use in found { if let id = use.objectID { resolution[id] = max(resolution[id] ?? 0, use.resolution) } }
            uses.append(found)
        }
        let target = options.imageTarget
        var done: Set<Int> = []
        for (index, page) in pages.enumerated() {
            try Task.checkCancellation()
            // Drawn pictures, then the ones a page only lists (no known size: re-encoded, never downsampled).
            for image in uses[index].map(\.object) + page.imageXObjects().map(\.object) {
                guard let id = image.objectID, done.insert(id).inserted else { continue }
                ImageRecompressor.recompress(image, in: model, resolution: resolution[id], target: target)
            }
            progress?(index + 1, pages.count)
        }
        discard(options, in: model)
        if options.removeExtraFonts { Fonts.unembedStandardFonts(in: model) }
    }

    // MARK: Discarding

    static func discard(_ options: OptimizeOptions, in model: PDFModel) {
        let root = model.root
        let pages = model.pages
        if options.removeThumbnails { for page in pages { page.object.remove("Thumb") } }
        if options.removeMetadata {
            root.remove("Metadata"); root.remove("PieceInfo")
            for page in pages { page.object.remove("Metadata"); page.object.remove("PieceInfo") }
        }
        if options.removeScripts { removeScripts(in: model) }
        if options.removeCommentsAndForms {
            for page in pages { keepAnnotations(on: page) { $0["Subtype"]?.name == "Link" } }
            root.remove("AcroForm")
        }
        if options.removeBookmarksAndAttachments {
            root.remove("Outlines"); root.remove("AF")
            if ["UseOutlines", "UseAttachments"].contains(root["PageMode"]?.name ?? "") { root.set("PageMode", .name("UseNone")) }
            root["Names"]?.remove("EmbeddedFiles")
            for page in pages { keepAnnotations(on: page) { $0["Subtype"]?.name != "FileAttachment" } }
        }
        if options.flattenLayers { flattenLayers(in: model) }
    }

    /// Keeps the annotations `keep` accepts (removes /Annots when none is left).
    static func keepAnnotations(on page: PDFPage, _ keep: (PDFObject) -> Bool) {
        let annotations = page.annotations
        let kept = annotations.filter(keep)
        guard kept.count != annotations.count else { return }
        if kept.isEmpty { page.object.remove("Annots"); return }
        let array = page.model.make(.array([]))
        for annotation in kept { array.append(annotation) }
        page.object.set("Annots", array)
    }

    /// Document JavaScript, the open action when it is a script, and every additional-actions dictionary.
    static func removeScripts(in model: PDFModel) {
        let root = model.root
        root["Names"]?.remove("JavaScript")
        if root["OpenAction"]?["S"]?.name == "JavaScript" { root.remove("OpenAction") }
        root.remove("AA")
        for page in model.pages {
            page.object.remove("AA")
            for annotation in page.annotations {
                annotation.remove("AA")
                if annotation["A"]?["S"]?.name == "JavaScript" { annotation.remove("A") }
            }
        }
        for field in model.formFields() { field.object.remove("AA") }
    }

    /// Removes the content of layers that are hidden by default and the layer definitions, so what shows is what stays.
    static func flattenLayers(in model: PDFModel) {
        let root = model.root
        guard let properties = root["OCProperties"] else { return }
        let hidden = Set((properties["D"]?["OFF"]?.items ?? []).compactMap(\.objectID))
        for page in model.pages {
            let resources = page.resources
            func isHidden(_ group: PDFObject?) -> Bool {
                guard let group else { return false }
                if let id = group.objectID, hidden.contains(id) { return true }
                // An optional-content membership dictionary hides when all its groups do (the default /AnyOn policy).
                let members = group["OCGs"].map { $0.type == .array ? $0.items : [$0] } ?? []
                return !members.isEmpty && members.allSatisfy { $0.objectID.map(hidden.contains) ?? false }
            }
            guard !hidden.isEmpty, var stream = try? page.contentStream() else { continue }
            var changed = stream.removeMarkedContent { span in
                guard span.tag == "OC", let name = span.properties?.nameValue else { return false }
                return isHidden(resources?["Properties"]?[name])
            } > 0
            let before = stream.operations.count
            stream.operations.removeAll { op in
                guard op.operator == "Do", let name = op.operands.first?.nameValue else { return false }
                return isHidden(resources?["XObject"]?[name]?["OC"])
            }
            changed = changed || stream.operations.count != before
            if changed { page.setContentStream(stream) }
        }
        root.remove("OCProperties")
    }

    // MARK: Estimate

    /// Estimated output sizes for each of `options`, from a sample of at most `sampleSize` pages (the whole file when it
    /// is that short), run side by side.
    static func estimate(_ source: PDFSource, options list: [OptimizeOptions], sampleSize: Int = 5) throws -> [Int64] {
        let data = try source.bytes()
        let model = try PDFModel(data: data, password: source.password)
        let count = model.pageCount
        guard count > 0, !list.isEmpty else { return list.map { _ in Int64(data.count) } }
        let picked = sample(count, size: sampleSize)
        let baseline: Data
        if picked.count == count {
            baseline = data
        } else {
            let sample = PDFModel()
            try sample.insertPages(from: model, pages: picked, at: 0)
            baseline = try sample.data()
        }
        let password = picked.count == count ? source.password : nil
        let results = UnsafeMutableBufferPointer<Int64>.allocate(capacity: list.count)
        defer { results.deallocate() }
        results.initialize(repeating: -1)
        DispatchQueue.concurrentPerform(iterations: list.count) { index in
            guard let copy = try? PDFModel(data: baseline, password: password),
                  (try? apply(list[index], to: copy)) != nil,
                  let out = try? copy.data(options: list[index].writeOptions) else { return }
            results[index] = Int64(out.count)
        }
        return (0..<list.count).map { index in
            let sampled = results[index] >= 0 ? results[index] : Int64(baseline.count)
            if picked.count == count { return sampled }
            return Int64((Double(data.count) * Double(sampled) / Double(max(baseline.count, 1))).rounded())
        }
    }

    /// `size` page indices spread evenly over `count` pages (all of them when there are no more).
    static func sample(_ count: Int, size: Int) -> [Int] {
        guard count > size else { return Array(0..<count) }
        return (0..<size).map { Int((Double($0) + 0.5) * Double(count) / Double(size)) }
    }

    // MARK: Audit

    /// Where the bytes go ("Audit space usage"): stored stream sizes by kind, the rest is structure.
    static func audit(_ source: PDFSource) throws -> SpaceAudit {
        let data = try source.bytes()
        let model = try PDFModel(data: data, password: source.password)
        var seen: Set<Int> = []
        var images: Int64 = 0, fonts: Int64 = 0, content: Int64 = 0, attachments: Int64 = 0
        func size(_ object: PDFObject?) -> Int64 {
            guard let object, object.type == .stream else { return 0 }
            if let id = object.objectID { guard seen.insert(id).inserted else { return 0 } }
            return Int64((try? object.streamData(decode: .none).count) ?? 0)
        }
        func font(_ font: PDFObject) {
            if let id = font.objectID { guard !seen.contains(id) else { return } }
            let descriptors = [font["FontDescriptor"]] + (font["DescendantFonts"]?.items ?? []).map { $0["FontDescriptor"] }
            for descriptor in descriptors.compactMap({ $0 }) {
                for key in ["FontFile", "FontFile2", "FontFile3"] { fonts += size(descriptor[key]) }
            }
            if let procs = font["CharProcs"] { for key in procs.keys { fonts += size(procs[key]) } }
        }
        func resources(_ dictionary: PDFObject?, depth: Int) {
            guard let dictionary, depth < 12 else { return }
            if let xobjects = dictionary["XObject"] {
                for name in xobjects.keys {
                    guard let x = xobjects[name] else { continue }
                    if x["Subtype"]?.name == "Image" {
                        images += size(x) + size(x["SMask"]) + (x["Mask"]?.type == .stream ? size(x["Mask"]) : 0)
                    } else {
                        let isNew = x.objectID.map { !seen.contains($0) } ?? true
                        content += size(x)
                        if isNew { resources(x["Resources"], depth: depth + 1) }
                    }
                }
            }
            if let fontDictionary = dictionary["Font"] { for name in fontDictionary.keys { if let f = fontDictionary[name] { font(f) } } }
            for category in ["Pattern", "Shading"] {
                if let entries = dictionary[category] { for name in entries.keys { content += size(entries[name]) } }
            }
        }
        for page in model.pages {
            for stream in page.contentStreams { content += size(stream) }
            resources(page.resources, depth: 0)
            for annotation in page.annotations {
                if let appearance = annotation["AP"] {
                    for key in appearance.keys {
                        guard let entry = appearance[key] else { continue }
                        if entry.type == .stream { content += size(entry) } else { for state in entry.keys { content += size(entry[state]) } }
                    }
                }
                attachments += size(annotation["FS"]?["EF"]?["F"])
            }
        }
        if let tree = model.root["Names"]?["EmbeddedFiles"] {
            for entry in PDFNameTree.entries(of: tree) { attachments += size(entry.value["EF"]?["F"]) }
        }
        let total = Int64(data.count)
        let structure = max(0, total - images - fonts - content - attachments)
        return SpaceAudit(images: images, fonts: fonts, content: content, structure: structure, attachments: attachments)
    }
}
