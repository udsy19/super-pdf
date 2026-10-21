import Foundation

// Simple-font encodings (ISO 32000-2 Annex D) and the glyph names they use: StandardEncoding, WinAnsiEncoding,
// MacRomanEncoding, and the Adobe Glyph List entries needed to turn a /Differences glyph name into text (and back).

/// A code → character table of a predefined encoding.
enum PDFEncoding {
    /// The character a code shows in `name`'s encoding, nil for unassigned codes.
    static func character(_ code: Int, in name: String) -> Unicode.Scalar? {
        switch name {
        case "WinAnsiEncoding": winAnsi[code]
        case "MacRomanEncoding": macRoman[code]
        case "StandardEncoding", "PDFDocEncoding": standard[code]
        case "MacExpertEncoding": nil
        default: nil
        }
    }

    /// The code of a character in `name`'s encoding.
    static func code(for scalar: Unicode.Scalar, in name: String) -> Int? {
        switch name {
        case "WinAnsiEncoding": winAnsiInverse[scalar]
        case "MacRomanEncoding": macRomanInverse[scalar]
        case "StandardEncoding", "PDFDocEncoding": standardInverse[scalar]
        default: nil
        }
    }

    static let winAnsi: [Int: Unicode.Scalar] = {
        var table: [Int: Unicode.Scalar] = [:]
        for code in 32...255 {
            // WinAnsi is Windows-1252; the codes 1252 leaves undefined show a bullet, 0xA0 is a space, 0xAD a hyphen.
            if let text = String(bytes: [UInt8(code)], encoding: .windowsCP1252), let scalar = text.unicodeScalars.first {
                table[code] = scalar
            } else {
                table[code] = "\u{2022}"
            }
        }
        table[0xA0] = " "
        table[0xAD] = "-"
        return table
    }()

    static let macRoman: [Int: Unicode.Scalar] = {
        var table: [Int: Unicode.Scalar] = [:]
        for code in 32...255 {
            if let text = String(bytes: [UInt8(code)], encoding: .macOSRoman), let scalar = text.unicodeScalars.first { table[code] = scalar }
        }
        // PDF's MacRomanEncoding has no currency/apple glyphs at 0xDB/0xF0; everything else is Mac OS Roman.
        table[0xCA] = " "
        return table
    }()

    static let standard: [Int: Unicode.Scalar] = {
        var table: [Int: Unicode.Scalar] = [:]
        for code in 32...126 { table[code] = Unicode.Scalar(UInt8(code)) }
        table[0x27] = "\u{2019}"   // quoteright
        table[0x60] = "\u{2018}"   // quoteleft
        let high: [Int: UInt32] = [
            0xA1: 0x00A1, 0xA2: 0x00A2, 0xA3: 0x00A3, 0xA4: 0x2044, 0xA5: 0x00A5, 0xA6: 0x0192, 0xA7: 0x00A7, 0xA8: 0x00A4,
            0xA9: 0x0027, 0xAA: 0x201C, 0xAB: 0x00AB, 0xAC: 0x2039, 0xAD: 0x203A, 0xAE: 0xFB01, 0xAF: 0xFB02, 0xB1: 0x2013,
            0xB2: 0x2020, 0xB3: 0x2021, 0xB4: 0x00B7, 0xB6: 0x00B6, 0xB7: 0x2022, 0xB8: 0x201A, 0xB9: 0x201E, 0xBA: 0x201D,
            0xBB: 0x00BB, 0xBC: 0x2026, 0xBD: 0x2030, 0xBF: 0x00BF, 0xC1: 0x0060, 0xC2: 0x00B4, 0xC3: 0x02C6, 0xC4: 0x02DC,
            0xC5: 0x00AF, 0xC6: 0x02D8, 0xC7: 0x02D9, 0xC8: 0x00A8, 0xCA: 0x02DA, 0xCB: 0x00B8, 0xCD: 0x02DD, 0xCE: 0x02DB,
            0xCF: 0x02C7, 0xD0: 0x2014, 0xE1: 0x00C6, 0xE3: 0x00AA, 0xE8: 0x0141, 0xE9: 0x00D8, 0xEA: 0x0152, 0xEB: 0x00BA,
            0xF1: 0x00E6, 0xF5: 0x0131, 0xF8: 0x0142, 0xF9: 0x00F8, 0xFA: 0x0153, 0xFB: 0x00DF,
        ]
        for (code, value) in high { table[code] = Unicode.Scalar(value) }
        return table
    }()

    private static func invert(_ table: [Int: Unicode.Scalar]) -> [Unicode.Scalar: Int] {
        var inverse: [Unicode.Scalar: Int] = [:]
        for (code, scalar) in table.sorted(by: { $0.key < $1.key }) where inverse[scalar] == nil { inverse[scalar] = code }
        return inverse
    }

    static let winAnsiInverse = invert(winAnsi)
    static let macRomanInverse = invert(macRoman)
    static let standardInverse = invert(standard)
}

/// Glyph names (the Adobe Glyph List, the part fonts and /Differences arrays use for Latin text) ↔ characters.
enum GlyphNames {
    /// The character a glyph name stands for: the list, then `uniXXXX`, `uXXXX[XX]`, and names like `a123` are unknown.
    static func scalar(for name: String) -> Unicode.Scalar? {
        if let hit = table[name] { return hit }
        // Some producers suffix names ("a.sc", "one.oldstyle"): the part before the dot is the base glyph.
        if let dot = name.firstIndex(of: "."), dot != name.startIndex, let base = table[String(name[..<dot])] { return base }
        if name.hasPrefix("uni"), name.count >= 7, let value = UInt32(name.dropFirst(3).prefix(4), radix: 16) { return Unicode.Scalar(value) }
        if name.hasPrefix("u"), (5...7).contains(name.count), let value = UInt32(name.dropFirst(1), radix: 16) { return Unicode.Scalar(value) }
        if name.count == 1, let scalar = name.unicodeScalars.first { return scalar }
        return nil
    }

    /// The glyph name of a character, when the list has one.
    static func name(for scalar: Unicode.Scalar) -> String? { inverse[scalar] }

    private static let inverse: [Unicode.Scalar: String] = {
        var inverse: [Unicode.Scalar: String] = [:]
        for (name, scalar) in table.sorted(by: { $0.key < $1.key }) where inverse[scalar] == nil { inverse[scalar] = name }
        return inverse
    }()

    static let table: [String: Unicode.Scalar] = {
        var t: [String: Unicode.Scalar] = [:]
        func add(_ name: String, _ value: UInt32) { t[name] = Unicode.Scalar(value) }
        // ASCII
        let ascii: [(String, UInt32)] = [
            ("space", 0x20), ("exclam", 0x21), ("quotedbl", 0x22), ("numbersign", 0x23), ("dollar", 0x24), ("percent", 0x25),
            ("ampersand", 0x26), ("quotesingle", 0x27), ("parenleft", 0x28), ("parenright", 0x29), ("asterisk", 0x2A), ("plus", 0x2B),
            ("comma", 0x2C), ("hyphen", 0x2D), ("period", 0x2E), ("slash", 0x2F), ("zero", 0x30), ("one", 0x31), ("two", 0x32),
            ("three", 0x33), ("four", 0x34), ("five", 0x35), ("six", 0x36), ("seven", 0x37), ("eight", 0x38), ("nine", 0x39),
            ("colon", 0x3A), ("semicolon", 0x3B), ("less", 0x3C), ("equal", 0x3D), ("greater", 0x3E), ("question", 0x3F), ("at", 0x40),
            ("bracketleft", 0x5B), ("backslash", 0x5C), ("bracketright", 0x5D), ("asciicircum", 0x5E), ("underscore", 0x5F),
            ("grave", 0x60), ("braceleft", 0x7B), ("bar", 0x7C), ("braceright", 0x7D), ("asciitilde", 0x7E),
        ]
        for (name, value) in ascii { add(name, value) }
        for value in UInt32(0x41)...0x5A { add(String(Unicode.Scalar(value)!), value) }
        for value in UInt32(0x61)...0x7A { add(String(Unicode.Scalar(value)!), value) }
        // Latin-1 and the usual typographic set
        let latin: [(String, UInt32)] = [
            ("exclamdown", 0xA1), ("cent", 0xA2), ("sterling", 0xA3), ("currency", 0xA4), ("yen", 0xA5), ("brokenbar", 0xA6),
            ("section", 0xA7), ("dieresis", 0xA8), ("copyright", 0xA9), ("ordfeminine", 0xAA), ("guillemotleft", 0xAB),
            ("logicalnot", 0xAC), ("registered", 0xAE), ("macron", 0xAF), ("degree", 0xB0), ("plusminus", 0xB1), ("twosuperior", 0xB2),
            ("threesuperior", 0xB3), ("acute", 0xB4), ("mu", 0xB5), ("paragraph", 0xB6), ("periodcentered", 0xB7), ("cedilla", 0xB8),
            ("onesuperior", 0xB9), ("ordmasculine", 0xBA), ("guillemotright", 0xBB), ("onequarter", 0xBC), ("onehalf", 0xBD),
            ("threequarters", 0xBE), ("questiondown", 0xBF), ("Agrave", 0xC0), ("Aacute", 0xC1), ("Acircumflex", 0xC2), ("Atilde", 0xC3),
            ("Adieresis", 0xC4), ("Aring", 0xC5), ("AE", 0xC6), ("Ccedilla", 0xC7), ("Egrave", 0xC8), ("Eacute", 0xC9), ("Ecircumflex", 0xCA),
            ("Edieresis", 0xCB), ("Igrave", 0xCC), ("Iacute", 0xCD), ("Icircumflex", 0xCE), ("Idieresis", 0xCF), ("Eth", 0xD0),
            ("Ntilde", 0xD1), ("Ograve", 0xD2), ("Oacute", 0xD3), ("Ocircumflex", 0xD4), ("Otilde", 0xD5), ("Odieresis", 0xD6),
            ("multiply", 0xD7), ("Oslash", 0xD8), ("Ugrave", 0xD9), ("Uacute", 0xDA), ("Ucircumflex", 0xDB), ("Udieresis", 0xDC),
            ("Yacute", 0xDD), ("Thorn", 0xDE), ("germandbls", 0xDF), ("agrave", 0xE0), ("aacute", 0xE1), ("acircumflex", 0xE2),
            ("atilde", 0xE3), ("adieresis", 0xE4), ("aring", 0xE5), ("ae", 0xE6), ("ccedilla", 0xE7), ("egrave", 0xE8), ("eacute", 0xE9),
            ("ecircumflex", 0xEA), ("edieresis", 0xEB), ("igrave", 0xEC), ("iacute", 0xED), ("icircumflex", 0xEE), ("idieresis", 0xEF),
            ("eth", 0xF0), ("ntilde", 0xF1), ("ograve", 0xF2), ("oacute", 0xF3), ("ocircumflex", 0xF4), ("otilde", 0xF5), ("odieresis", 0xF6),
            ("divide", 0xF7), ("oslash", 0xF8), ("ugrave", 0xF9), ("uacute", 0xFA), ("ucircumflex", 0xFB), ("udieresis", 0xFC),
            ("yacute", 0xFD), ("thorn", 0xFE), ("ydieresis", 0xFF),
            ("quoteright", 0x2019), ("quoteleft", 0x2018), ("quotedblleft", 0x201C), ("quotedblright", 0x201D), ("quotesinglbase", 0x201A),
            ("quotedblbase", 0x201E), ("endash", 0x2013), ("emdash", 0x2014), ("bullet", 0x2022), ("ellipsis", 0x2026), ("dagger", 0x2020),
            ("daggerdbl", 0x2021), ("perthousand", 0x2030), ("guilsinglleft", 0x2039), ("guilsinglright", 0x203A), ("fraction", 0x2044),
            ("florin", 0x0192), ("fi", 0xFB01), ("fl", 0xFB02), ("ff", 0xFB00), ("ffi", 0xFB03), ("ffl", 0xFB04), ("Lslash", 0x0141),
            ("lslash", 0x0142), ("OE", 0x0152), ("oe", 0x0153), ("Scaron", 0x0160), ("scaron", 0x0161), ("Ydieresis", 0x0178),
            ("Zcaron", 0x017D), ("zcaron", 0x017E), ("dotlessi", 0x0131), ("circumflex", 0x02C6), ("tilde", 0x02DC), ("caron", 0x02C7),
            ("breve", 0x02D8), ("dotaccent", 0x02D9), ("ring", 0x02DA), ("ogonek", 0x02DB), ("hungarumlaut", 0x02DD), ("Euro", 0x20AC),
            ("trademark", 0x2122), ("minus", 0x2212), ("nbspace", 0x00A0), ("sfthyphen", 0x00AD), ("softhyphen", 0x00AD),
            ("hyphenminus", 0x2D), ("apostrophe", 0x27), ("quotedblbase", 0x201E), ("notequal", 0x2260), ("infinity", 0x221E),
            ("lessequal", 0x2264), ("greaterequal", 0x2265), ("partialdiff", 0x2202), ("summation", 0x2211), ("product", 0x220F),
            ("pi", 0x03C0), ("integral", 0x222B), ("Omega", 0x03A9), ("radical", 0x221A), ("approxequal", 0x2248), ("Delta", 0x2206),
            ("lozenge", 0x25CA), ("apple", 0xF8FF), ("checkmark", 0x2713), ("arrowright", 0x2192), ("arrowleft", 0x2190),
            ("arrowup", 0x2191), ("arrowdown", 0x2193), ("Gbreve", 0x011E), ("gbreve", 0x011F), ("Idotaccent", 0x0130),
            ("Scedilla", 0x015E), ("scedilla", 0x015F), ("Cacute", 0x0106), ("cacute", 0x0107), ("Ccaron", 0x010C), ("ccaron", 0x010D),
            ("dcroat", 0x0111), ("Dcroat", 0x0110),
        ]
        for (name, value) in latin { add(name, value) }
        return t
    }()
}
