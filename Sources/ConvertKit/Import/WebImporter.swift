import AppKit
import SuperPDFCore
import WebKit

/// HTML, web archives and SVG → PDF (features #41) with WebKit, offline: only local files load (everything else is
/// blocked), page scripts are off, and the page is laid out at the paper's width ("fit width") and cut into pages
/// between lines, rows and pictures.
enum WebImporter {
    @MainActor
    static func convert(_ input: URL, to output: URL, options: ImportOptions) async throws -> ImportReport {
        let ext = input.pathExtension.lowercased()
        if ext == "webarchive" {
            let folder = output.deletingLastPathComponent().appendingPathComponent("webarchive-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let page = try WebArchive.unpack(input, into: folder)
            try await WebRenderer.render(file: page, paper: options.textPaper, margins: CGFloat(options.margins), to: output)
        } else {
            try await WebRenderer.render(file: input, paper: options.textPaper, margins: CGFloat(options.margins), to: output)
        }
        return ImportReport()
    }
}

/// Lays a local web page out with WebKit and writes it as paged PDF (vector text, selectable).
@MainActor
enum WebRenderer {
    enum Failure: Error { case loadFailed(String), timedOut, noContent }

    /// Renders `file` (which may reference files next to it) on pages of `paper`. Returns the page count.
    @discardableResult
    static func render(file: URL, paper: CGSize, margins: CGFloat, to output: URL, title: String? = nil, loadTimeout: TimeInterval = 30) async throws -> Int {
        let width = max(paper.width - 2 * margins, 72)
        let loader = try await PageLoader.make(width: width)
        defer { loader.close() }
        try await loader.load(file, timeout: loadTimeout)
        let metrics = try await loader.measure()
        // Wider than the paper ("fit width"): the page is scaled down to the paper's width.
        let contentWidth = max(CGFloat(metrics.width), width)
        let scale = width / contentWidth
        let height = max(CGFloat(metrics.height), 1)
        loader.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let breaks = Paginator.pageBreaks(total: height, pageHeight: (paper.height - 2 * margins) / scale, boxes: metrics.boxes)
        // One PDF per page, cut by WebKit, so each page holds only its own text.
        var slices: [Data] = []
        for (top, bottom) in zip(breaks, breaks.dropFirst()) {
            try Task.checkCancellation()
            slices.append(try await loader.pdf(CGRect(x: 0, y: top, width: contentWidth, height: bottom - top)))
        }
        return try Paginator.write(slices: slices, scale: scale, paper: paper, margins: margins, to: output, title: title ?? metrics.title)
    }

    /// What the page reports about itself after layout (CSS pixels = points).
    struct Metrics: Decodable {
        var width: Double
        var height: Double
        var title: String?
        /// Vertical extents [top, bottom] of lines, pictures and table rows: a page break never cuts through one.
        var boxes: [[Double]]
    }

    /// One WKWebView for one render.
    private final class PageLoader: NSObject, WKNavigationDelegate {
        let view: WKWebView
        private var finished: CheckedContinuation<Void, Error>?

        private init(view: WKWebView) {
            self.view = view
        }

        static func make(width: CGFloat) async throws -> PageLoader {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.preferences.isFraudulentWebsiteWarningEnabled = false
            configuration.suppressesIncrementalRendering = true
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            configuration.userContentController.add(try await offlineRules())
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1000), configuration: configuration)
            let loader = PageLoader(view: view)
            view.navigationDelegate = loader
            return loader
        }

        func load(_ file: URL, timeout: TimeInterval) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                finished = continuation
                view.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    self?.finish(.failure(Failure.timedOut))
                }
            }
        }

        func measure() async throws -> Metrics {
            let value = try await view.evaluateJavaScript(Self.measureScript, in: nil, contentWorld: .defaultClient)
            guard let json = value as? String, let metrics = try? JSONDecoder().decode(Metrics.self, from: Data(json.utf8)) else {
                throw Failure.noContent
            }
            return metrics
        }

        /// A PDF of `rect` (CSS pixels from the document's top-left).
        func pdf(_ rect: CGRect) async throws -> Data {
            let configuration = WKPDFConfiguration()
            configuration.rect = rect
            return try await withCheckedThrowingContinuation { continuation in
                view.createPDF(configuration: configuration) { continuation.resume(with: $0) }
            }
        }

        func close() {
            view.stopLoading()
            view.navigationDelegate = nil
        }

        private func finish(_ result: Result<Void, Error>) {
            guard let continuation = finished else { return }
            finished = nil
            continuation.resume(with: result)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(.failure(Failure.loadFailed(error.localizedDescription)))
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(.failure(Failure.loadFailed(error.localizedDescription)))
        }

        /// Only local documents open; links and redirects elsewhere are refused.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            return ["file", "about", "data", "blob"].contains(scheme) ? .allow : .cancel
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(Failure.loadFailed("web content process ended"))) }

        /// Line boxes, pictures and table rows with their vertical extent, the document's size and title, as JSON.
        static let measureScript = """
        (() => {
          const boxes = [];
          const root = document.body || document.documentElement;
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          const range = document.createRange();
          while (walker.nextNode() && boxes.length < 60000) {
            const node = walker.currentNode;
            if (!node.textContent.trim()) continue;
            range.selectNodeContents(node);
            for (const r of range.getClientRects()) if (r.height > 0) boxes.push([r.top + scrollY, r.bottom + scrollY]);
          }
          for (const el of document.querySelectorAll('img,svg,video,canvas,picture,tr,hr,math,figure img')) {
            const r = el.getBoundingClientRect();
            if (r.height > 0) boxes.push([r.top + scrollY, r.bottom + scrollY]);
          }
          const d = document.documentElement;
          // The content's own height (the viewport's height doesn't count): the body's bottom and margin, the lowest box.
          const bottom = root.getBoundingClientRect().bottom + scrollY + (parseFloat(getComputedStyle(root).marginBottom) || 0);
          const lowest = boxes.reduce((m, b) => Math.max(m, b[1]), 0);
          return JSON.stringify({
            width: Math.max(d.scrollWidth, root.scrollWidth || 0, d.clientWidth),
            height: Math.max(bottom, lowest, 1),
            title: document.title || null,
            boxes: boxes
          });
        })()
        """
    }

    /// Blocks every load that isn't a local file or inline data, so a page can't reach the network (features §3.5).
    private static func offlineRules() async throws -> WKContentRuleList {
        if let cached = cachedRules { return cached }
        let rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
        """
        let folder = SuperPDFPaths.ensure(SuperPDFPaths.support.appendingPathComponent("WebKit Rules", isDirectory: true))
        guard let store = WKContentRuleListStore(url: folder) else { throw Failure.loadFailed("content rules") }
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: "offline", encodedContentRuleList: rules) { list, error in
                if let list { continuation.resume(returning: list) } else { continuation.resume(throwing: error ?? Failure.loadFailed("content rules")) }
            }
        }
        cachedRules = list
        return list
    }

    private static var cachedRules: WKContentRuleList?

    /// Places WebKit's page slices on paper, under the top margin, scaled to the paper's width.
    enum Paginator {
        static func write(slices: [Data], scale: CGFloat, paper: CGSize, margins: CGFloat, to output: URL, title: String?) throws -> Int {
            guard !slices.isEmpty else { throw Failure.noContent }
            var media = CGRect(origin: .zero, size: paper)
            var info: [CFString: Any] = [kCGPDFContextCreator: Strings.appName]
            if let title, !title.isEmpty { info[kCGPDFContextTitle] = title }
            guard let context = CGContext(output as CFURL, mediaBox: &media, info as CFDictionary) else { throw ComposeError.cannotCreatePDF }
            for slice in slices {
                guard let provider = CGDataProvider(data: slice as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) else {
                    throw Failure.noContent
                }
                let box = page.getBoxRect(.mediaBox)
                context.beginPDFPage(nil)
                context.saveGState()
                // The slice's top-left lands at the top margin.
                context.translateBy(x: margins, y: paper.height - margins - box.height * scale)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -box.minX, y: -box.minY)
                context.clip(to: box)
                context.drawPDFPage(page)
                context.restoreGState()
                context.endPDFPage()
            }
            context.closePDF()
            return slices.count
        }

        /// Page boundaries from 0 to `total`: each as low as possible but never through a line, row or picture, unless
        /// one is taller than a third of a page.
        static func pageBreaks(total: CGFloat, pageHeight: CGFloat, boxes: [[Double]]) -> [CGFloat] {
            // Merge the boxes into intervals a break must not fall inside.
            let spans = boxes.compactMap { b -> (CGFloat, CGFloat)? in
                guard b.count == 2, b[1] - b[0] > 1 else { return nil }
                return (CGFloat(b[0]) + 0.5, CGFloat(b[1]) - 0.5)
            }.sorted { $0.0 < $1.0 }
            var merged: [(CGFloat, CGFloat)] = []
            for span in spans {
                if let last = merged.last, span.0 < last.1 { merged[merged.count - 1].1 = max(last.1, span.1) } else { merged.append(span) }
            }
            var breaks: [CGFloat] = [0]
            var position: CGFloat = 0
            var searchFrom = 0
            while total - position > 1 {
                var limit = position + pageHeight
                if limit >= total { breaks.append(total); break }
                while searchFrom < merged.count, merged[searchFrom].1 <= position { searchFrom += 1 }
                var i = searchFrom
                while i < merged.count, merged[i].0 < limit {
                    if merged[i].1 > limit {
                        // `limit` falls inside this interval: break before it, if that leaves a reasonable page.
                        if merged[i].0 - position > pageHeight / 3 { limit = merged[i].0 - 0.5 }
                        break
                    }
                    i += 1
                }
                breaks.append(limit)
                position = limit
                if breaks.count > 20_000 { break }
            }
            return breaks
        }
    }
}

/// Safari's web archives: the page and its pictures and styles, unpacked into a folder with the page pointing at the
/// local copies (nothing is fetched).
enum WebArchive {
    static func unpack(_ url: URL, into folder: URL) throws -> URL {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let main = plist["WebMainResource"] as? [String: Any], let html = main["WebResourceData"] as? Data else {
            throw ConvertError.unsupported("web archive")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resources = (plist["WebSubresources"] as? [[String: Any]] ?? []).compactMap { resource -> (url: String, data: Data, name: String)? in
            guard let address = resource["WebResourceURL"] as? String, let bytes = resource["WebResourceData"] as? Data else { return nil }
            let ext = URL(string: address)?.pathExtension ?? ""
            let name = "r\(CRC32.checksum(Data(address.utf8)))" + (ext.isEmpty ? "" : ".\(ext)")
            return (address, bytes, name)
        }
        let encoding = (main["WebResourceTextEncodingName"] as? String).map { CFStringConvertIANACharSetNameToEncoding($0 as CFString) }
            .map { String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding($0)) } ?? .utf8
        func localized(_ text: String) -> String {
            // Longest addresses first, so "a.png?x" is replaced before "a.png".
            resources.sorted { $0.url.count > $1.url.count }.reduce(text) { $0.replacingOccurrences(of: $1.url, with: $1.name) }
        }
        for resource in resources {
            var bytes = resource.data
            if ["css", "svg", "html", "htm"].contains((resource.name as NSString).pathExtension.lowercased()), let text = String(data: bytes, encoding: .utf8) {
                bytes = Data(localized(text).utf8)
            }
            try bytes.write(to: folder.appendingPathComponent(resource.name))
        }
        let page = folder.appendingPathComponent("index.html")
        let text = String(data: html, encoding: encoding) ?? String(decoding: html, as: UTF8.self)
        try localized(text).write(to: page, atomically: true, encoding: .utf8)
        return page
    }
}
