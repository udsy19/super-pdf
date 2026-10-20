import CoreGraphics
import Foundation

/// What colour a page's content uses, read from its content stream and resources: feeds the PDF/X-1a decision (RGB
/// pages are converted) and the output preview's plate list (features #94, #95). Off the main actor.
public struct ColorUsage: Hashable, Sendable {
    public var usesRGB = false
    public var usesCMYK = false
    public var usesGray = false
    /// Separation and DeviceN colourant names, in order of appearance ("PANTONE 300 C"), process colourants excluded.
    public var spotColors: [String] = []
    /// Soft masks, blend modes or constant alpha below 1.
    public var usesTransparency = false

    public init() {}

    public static func scan(_ page: CGPDFPage) -> ColorUsage {
        let state = State()
        guard let table = CGPDFOperatorTableCreate() else { return ColorUsage() }
        for op in ["rg", "RG"] { CGPDFOperatorTableSetCallback(table, op) { _, info in ColorUsage.state(info).usage.usesRGB = true } }
        for op in ["k", "K"] { CGPDFOperatorTableSetCallback(table, op) { _, info in ColorUsage.state(info).usage.usesCMYK = true } }
        for op in ["g", "G"] { CGPDFOperatorTableSetCallback(table, op) { _, info in ColorUsage.state(info).usage.usesGray = true } }
        for op in ["cs", "CS"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(scanner, &name), let name else { return }
                let s = ColorUsage.state(info)
                let content = CGPDFScannerGetContentStream(scanner)
                switch String(cString: name) {
                case "DeviceRGB", "CalRGB": s.usage.usesRGB = true
                case "DeviceCMYK": s.usage.usesCMYK = true
                case "DeviceGray", "CalGray": s.usage.usesGray = true
                case "Pattern": break
                default:
                    if let object = CGPDFContentStreamGetResource(content, "ColorSpace", name) { s.note(colorSpace: object) }
                }
            }
        }
        CGPDFOperatorTableSetCallback(table, "gs") { scanner, info in
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let s = ColorUsage.state(info)
            let content = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(content, "ExtGState", name) else { return }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return }
            var alpha: CGPDFReal = 1
            if CGPDFDictionaryGetNumber(dictionary, "ca", &alpha), alpha < 1 { s.usage.usesTransparency = true }
            if CGPDFDictionaryGetNumber(dictionary, "CA", &alpha), alpha < 1 { s.usage.usesTransparency = true }
            var mask: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dictionary, "SMask", &mask), let mask, CGPDFObjectGetType(mask) == .dictionary { s.usage.usesTransparency = true }
            var blend: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(dictionary, "BM", &blend), let blend, !["Normal", "Compatible"].contains(String(cString: blend)) { s.usage.usesTransparency = true }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let s = ColorUsage.state(info)
            guard s.draws < 4000 else { return }
            s.draws += 1
            let content = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(dictionary, "Subtype", &subtype)
            switch subtype.map({ String(cString: $0) }) {
            case "Image":
                var space: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(dictionary, "ColorSpace", &space), let space { s.note(colorSpace: space) }
                var mask: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(dictionary, "SMask", &mask) { s.usage.usesTransparency = true }
            case "Form":
                guard s.depth < 6 else { return }
                var group: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Group", &group) { s.usage.usesTransparency = true }
                var resources: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                guard let formResources = resources ?? s.pageResources else { return }
                guard let table = s.table else { return }
                s.depth += 1
                let formContent = CGPDFContentStreamCreateWithStream(stream, formResources, content)
                ColorUsage.run(formContent, table: table, state: s)
                s.depth -= 1
            default: break
            }
        }
        if let pageDictionary = page.dictionary {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources) { state.pageResources = resources }
        }
        state.table = table
        run(CGPDFContentStreamCreateWithPage(page), table: table, state: state)
        CGPDFOperatorTableRelease(table)
        return state.usage
    }

    // MARK: Scanner plumbing

    final class State {
        var usage = ColorUsage()
        var depth = 0
        var draws = 0
        var pageResources: CGPDFDictionaryRef?
        var table: CGPDFOperatorTableRef?

        /// Records what a colour-space object (name or array) means.
        func note(colorSpace object: CGPDFObjectRef) {
            var name: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(object, .name, &name), let name {
                switch String(cString: name) {
                case "DeviceRGB", "CalRGB": usage.usesRGB = true
                case "DeviceCMYK": usage.usesCMYK = true
                case "DeviceGray", "CalGray": usage.usesGray = true
                default: break
                }
                return
            }
            var array: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &array), let array, CGPDFArrayGetCount(array) >= 1 else { return }
            var family: UnsafePointer<CChar>?
            guard CGPDFArrayGetName(array, 0, &family), let family else { return }
            switch String(cString: family) {
            case "ICCBased":
                var stream: CGPDFStreamRef?
                guard CGPDFArrayGetCount(array) >= 2, CGPDFArrayGetStream(array, 1, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                var n: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(dictionary, "N", &n)
                switch n { case 1: usage.usesGray = true; case 4: usage.usesCMYK = true; default: usage.usesRGB = true }
            case "Separation":
                var colorant: UnsafePointer<CChar>?
                if CGPDFArrayGetCount(array) >= 2, CGPDFArrayGetName(array, 1, &colorant), let colorant { add(spot: String(cString: colorant)) }
            case "DeviceN":
                var names: CGPDFArrayRef?
                if CGPDFArrayGetCount(array) >= 2, CGPDFArrayGetArray(array, 1, &names), let names {
                    for index in 0..<CGPDFArrayGetCount(names) {
                        var colorant: UnsafePointer<CChar>?
                        if CGPDFArrayGetName(names, index, &colorant), let colorant { add(spot: String(cString: colorant)) }
                    }
                }
            case "Indexed", "Pattern":
                var base: CGPDFObjectRef?
                if CGPDFArrayGetCount(array) >= 2, CGPDFArrayGetObject(array, 1, &base), let base { note(colorSpace: base) }
            case "CalRGB", "Lab": usage.usesRGB = true
            case "CalGray": usage.usesGray = true
            default: break
            }
        }

        private func add(spot name: String) {
            let process: Set<String> = ["Cyan", "Magenta", "Yellow", "Black", "All", "None"]
            if process.contains(name) { usage.usesCMYK = true } else if !usage.spotColors.contains(name) { usage.spotColors.append(name) }
        }
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> State { Unmanaged<State>.fromOpaque(info!).takeUnretainedValue() }

    private static func run(_ content: CGPDFContentStreamRef, table: CGPDFOperatorTableRef, state: State) {
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
    }
}
