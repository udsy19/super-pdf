import Foundation
import PDFModelKit

// Document properties and the initial view (features #124, #10): the Info dictionary (title, author, subject, keywords,
// custom fields), how the file opens (page, zoom, layout, sidebar) and the XMP packet kept in step.

/// How the file opens (ISO 32000-2 §12.2, §12.3.2).
public struct InitialView: Codable, Hashable, Sendable {
    public enum Zoom: Codable, Hashable, Sendable {
        case `default`
        case fitPage, fitWidth
        case percent(Double)
    }

    public enum Layout: String, Codable, CaseIterable, Sendable {
        case `default`, singlePage = "SinglePage", continuous = "OneColumn", twoPages = "TwoColumnLeft", twoPagesContinuous = "TwoPageLeft"
    }

    public enum Sidebar: String, Codable, CaseIterable, Sendable {
        case `default`, none = "UseNone", thumbnails = "UseThumbs", outline = "UseOutlines", attachments = "UseAttachments", fullScreen = "FullScreen"
    }

    /// 0-based.
    public var page: Int
    public var zoom: Zoom
    public var layout: Layout
    public var sidebar: Sidebar

    public init(page: Int = 0, zoom: Zoom = .default, layout: Layout = .default, sidebar: Sidebar = .default) {
        self.page = page; self.zoom = zoom; self.layout = layout; self.sidebar = sidebar
    }
}

public struct DocumentProperties: Codable, Hashable, Sendable {
    public var title: String
    public var author: String
    public var subject: String
    public var keywords: String
    /// Info entries other than the standard ones (and the dates, producer and creator, which are read-only here).
    public var custom: [String: String]
    public var initialView: InitialView

    public init(title: String = "", author: String = "", subject: String = "", keywords: String = "", custom: [String: String] = [:],
                initialView: InitialView = InitialView()) {
        self.title = title; self.author = author; self.subject = subject; self.keywords = keywords; self.custom = custom; self.initialView = initialView
    }

    static let standardKeys: Set<String> = ["Title", "Author", "Subject", "Keywords", "Creator", "Producer", "CreationDate", "ModDate", "Trapped"]

    /// Reads the model's properties.
    public static func read(from model: PDFModel) -> DocumentProperties {
        var properties = DocumentProperties(title: model.info("Title") ?? "", author: model.info("Author") ?? "", subject: model.info("Subject") ?? "",
                                            keywords: model.info("Keywords") ?? "")
        if let info = model.trailer["Info"] {
            for key in info.keys where !standardKeys.contains(key) { if let text = info[key]?.text { properties.custom[key] = text } }
        }
        var view = InitialView()
        if let open = model.root["OpenAction"] {
            let destination = open.type == .array ? open : open["D"]
            if let destination, destination.type == .array, let target = destination[0] {
                if let index = target.int { view.page = index } else if target.type == .dictionary, let index = PDFPage(target).index { view.page = index }
                switch destination[1]?.name {
                case "Fit", "FitB": view.zoom = .fitPage
                case "FitH", "FitBH": view.zoom = .fitWidth
                case "XYZ": if let zoom = destination[4]?.number, zoom > 0 { view.zoom = .percent(zoom * 100) }
                default: break
                }
            }
        }
        if let layout = model.root["PageLayout"]?.name, let value = InitialView.Layout(rawValue: layout) { view.layout = value }
        if let mode = model.root["PageMode"]?.name, let value = InitialView.Sidebar(rawValue: mode) { view.sidebar = value }
        properties.initialView = view
        return properties
    }

    /// Writes the properties into the model (and into the XMP packet when it has one).
    public func write(to model: PDFModel) {
        model.setInfo("Title", title.isEmpty ? nil : title)
        model.setInfo("Author", author.isEmpty ? nil : author)
        model.setInfo("Subject", subject.isEmpty ? nil : subject)
        model.setInfo("Keywords", keywords.isEmpty ? nil : keywords)
        if let info = model.trailer["Info"] {
            for key in info.keys where !Self.standardKeys.contains(key) && custom[key] == nil { info.remove(key) }
        }
        for (key, value) in custom { model.setInfo(key, value) }
        let view = initialView
        if view.page == 0, view.zoom == .default {
            model.root.remove("OpenAction")
        } else if let page = model.page(at: min(max(view.page, 0), max(model.pageCount - 1, 0))), let reference = page.object.reference {
            var destination: [PDFValue] = [reference]
            switch view.zoom {
            case .default: destination += [.name("XYZ"), .null, .null, .null]
            case .fitPage: destination.append(.name("Fit"))
            case .fitWidth: destination += [.name("FitH"), .null]
            case .percent(let percent): destination += [.name("XYZ"), .null, .null, .number(percent / 100)]
            }
            model.root.set("OpenAction", .array(destination))
        }
        if view.layout == .default { model.root.remove("PageLayout") } else { model.root.set("PageLayout", .name(view.layout.rawValue)) }
        if view.sidebar == .default { model.root.remove("PageMode") } else { model.root.set("PageMode", .name(view.sidebar.rawValue)) }
        model.updateXMP(forInfo: ["Title", "Author", "Subject", "Keywords"], modified: Date())
    }
}
